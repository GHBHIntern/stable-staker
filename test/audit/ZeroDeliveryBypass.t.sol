// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {AutoAnnihilateTest} from "../AutoAnnihilate.t.sol";
import {MockYieldStrategy} from "../mocks/MockYieldStrategy.sol";

/// @notice Independent audit PoC (not a story). When the yield-strategy exit delivers nothing,
///         {StableStakerV2-autoAnnihilate} never calls `Antimatter.annihilate`, so none of the
///         downstream circuit breakers run: Antimatter's pause, the stable minter's pause, its
///         per-stablecoin `enabled` flag and its `maxMintPerDay` cap. The whole frictionless target
///         is then minted by the staker as fresh phUSD. CLAUDE.md and the existing tests
///         (`test_autoAnnihilate_revertsWhileAntimatterIsPaused`,
///         `test_autoAnnihilate_dailyMintCap_revertsAtomically`) state that these breakers make the
///         call revert atomically; that holds only while delivery is non-zero.
contract ZeroDeliveryBypassTest is AutoAnnihilateTest {
    function _zeroDeliveryWithBreakers() internal {
        MockYieldStrategy ys = new MockYieldStrategy();
        ys.setClient(address(staker), true);
        ys.setExitSlippageBps(10_000); // exit delivers nothing
        staker.setYieldStrategy(address(dai), ys);

        _stake(alice, address(dai), 100 ether);
        vm.warp(block.timestamp + 50); // 50 antimatter owed

        // Every phUSD circuit breaker downstream of the staker is engaged.
        antimatter.setPauser(owner);
        antimatter.pause();
        minter.setPauser(owner);
        minter.pause();
        minter.setStablecoinEnabled(address(dai), false);
        minter.setMaxMintPerDay(address(dai), 1);
    }

    function test_audit_zeroDelivery_bypassesAntimatterAndMinterBreakers() public {
        _zeroDeliveryWithBreakers();
        uint256 supplyBefore = phUSD.totalSupply();

        (uint256 paid, uint256 minted) = _autoAnnihilateCapture(alice, address(dai));

        assertEq(paid, 100 ether, "full frictionless payout despite every breaker");
        assertEq(minted, 100 ether, "all of it freshly minted by the staker");
        assertEq(phUSD.totalSupply() - supplyBefore, 100 ether, "unbacked phUSD entered supply");
        assertEq(antimatter.totalSupply(), 0, "annihilate was never reached");
    }

    /// Control: the same breakers DO stop the call when the exit delivers even 1% of the request.
    function test_audit_partialDelivery_breakersHold() public {
        _zeroDeliveryWithBreakers();
        MockYieldStrategy(address(staker.yieldStrategy(address(dai)))).setExitSlippageBps(9_900);
        vm.expectRevert();
        _autoAnnihilate(alice, address(dai));
    }
}
