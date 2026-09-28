// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {AutoAnnihilateTest} from "../AutoAnnihilate.t.sol";
import {MockYieldStrategy} from "../mocks/MockYieldStrategy.sol";

/// @notice Independent audit re-verification of open ledger finding (stable-staker run 17, M-01) at
///         cf8de27: with `claimEnabled == false`, a strategy below par and no idle buffer, the only
///         path that returns principal is {emergencyWithdraw}, and it destroys the accrued reward.
contract UnderwaterForfeitureTest is AutoAnnihilateTest {
    function test_audit_underwater_onlyExitForfeitsReward() public {
        MockYieldStrategy ys = new MockYieldStrategy();
        ys.setClient(address(staker), true);
        staker.setYieldStrategy(address(dai), ys);
        _stake(alice, address(dai), 100 ether);
        vm.warp(block.timestamp + 1 days);
        uint256 owed = staker.claimableReward(address(dai), alice);
        assertGt(owed, 0);

        ys.setValueFactorBps(9_900); // 1% below par, no buffer on the staker

        vm.startPrank(alice);
        vm.expectRevert("StableStaker: strategy underwater");
        staker.withdraw(address(dai), 1 ether);
        vm.expectRevert("StableStaker: strategy underwater");
        staker.autoAnnihilate(address(dai));
        vm.expectRevert("StableStaker: claim disabled");
        staker.claim(address(dai));

        staker.emergencyWithdraw(address(dai));
        vm.stopPrank();

        assertEq(staker.claimableReward(address(dai), alice), 0, "reward destroyed");
        assertEq(antimatter.balanceOf(alice), 0, "nothing paid");
    }
}
