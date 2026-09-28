// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {InPlaceMigratorTest} from "../InPlaceMigrator.t.sol";

/// @notice Independent audit PoC (not a story). {InPlaceMigrator-migrateIn} removes each re-injected
///         user from the EnumerableSet it is paging over. Removal is swap-and-pop, so after a page
///         `[0, k)` the untouched users have moved down into indices below `k`. Paging forward with
///         `[k, 2k)`, the natural reading of the `start` / `end` parameters, silently skips them.
contract MigrateInPagingTest is InPlaceMigratorTest {
    function test_audit_forwardPaging_skipsParkedUsers() public {
        address[4] memory who = [address(0x1001), address(0x1002), address(0x1003), address(0x1004)];
        address[] memory users = new address[](4);
        for (uint256 i = 0; i < 4; i++) {
            users[i] = who[i];
            usdc.mint(who[i], 10e6);
            vm.startPrank(who[i]);
            usdc.approve(address(staker), type(uint256).max);
            staker.stake(address(usdc), 10e6);
            vm.stopPrank();
        }

        migrator.initiateMigration(address(usdc));
        migrator.migrateOut(address(usdc), users);
        staker.finalizeAndReset(address(usdc));
        assertEq(migrator.parkedUserCount(address(usdc)), 4);

        // Two pages of two, as an operator paging through 4 parked users would write them.
        migrator.migrateIn(address(usdc), 0, 2);
        migrator.migrateIn(address(usdc), 2, 4);

        // Half the cohort was never re-staked and stays parked, earning nothing.
        assertEq(migrator.parkedUserCount(address(usdc)), 2, "two users skipped");
        assertEq(staker.stakerCount(address(usdc)), 2, "only two re-staked");
    }
}
