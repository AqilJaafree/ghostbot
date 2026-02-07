// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {OpenClawOracle} from "../src/OpenClawOracle.sol";
import {IOpenClawOracle} from "../src/interfaces/IOpenClawOracle.sol";
import {RebalanceSignal, FeeRecommendation} from "../src/types/DataTypes.sol";

contract OpenClawOracleTest is Test {
    OpenClawOracle oracle;

    address owner = address(this);
    address bot = makeAddr("bot");
    address hook = makeAddr("hook");
    address attacker = makeAddr("attacker");

    bytes32 poolId = keccak256("test-pool");

    function setUp() public {
        oracle = new OpenClawOracle(owner);
        oracle.setBot(bot);
        oracle.setHook(hook);
    }

    // ── Access Control ─────────────────────────────────────────────────
    function test_setBot_onlyOwner() public {
        vm.prank(attacker);
        vm.expectRevert();
        oracle.setBot(attacker);
    }

    function test_setHook_onlyOwner() public {
        vm.prank(attacker);
        vm.expectRevert();
        oracle.setHook(attacker);
    }

    function test_postRebalanceSignal_onlyBot() public {
        RebalanceSignal memory signal = _makeSignal(1, -100, 100, 80);

        vm.prank(attacker);
        vm.expectRevert(OpenClawOracle.OnlyBot.selector);
        oracle.postRebalanceSignal(poolId, signal);
    }

    function test_postFeeRecommendation_onlyBot() public {
        FeeRecommendation memory rec = FeeRecommendation({
            fee: 3000,
            confidence: 85,
            timestamp: block.timestamp
        });

        vm.prank(attacker);
        vm.expectRevert(OpenClawOracle.OnlyBot.selector);
        oracle.postFeeRecommendation(poolId, rec);
    }

    // ── Signal Storage & Retrieval ─────────────────────────────────────
    function test_postAndRetrieveSignal() public {
        RebalanceSignal memory signal = _makeSignal(1, -100, 100, 80);

        vm.prank(bot);
        oracle.postRebalanceSignal(poolId, signal);

        RebalanceSignal[] memory signals = oracle.getPositionsNeedingRebalance(poolId);
        assertEq(signals.length, 1);
        assertEq(signals[0].positionId, 1);
        assertEq(signals[0].newTickLower, -100);
        assertEq(signals[0].newTickUpper, 100);
        assertEq(signals[0].confidence, 80);
    }

    function test_postMultipleSignals() public {
        vm.startPrank(bot);
        oracle.postRebalanceSignal(poolId, _makeSignal(1, -100, 100, 80));
        oracle.postRebalanceSignal(poolId, _makeSignal(2, -200, 200, 90));
        vm.stopPrank();

        RebalanceSignal[] memory signals = oracle.getPositionsNeedingRebalance(poolId);
        assertEq(signals.length, 2);
    }

    function test_circularBufferOverwrite() public {
        vm.startPrank(bot);
        // Fill the buffer beyond MAX_SIGNALS_PER_POOL (32)
        for (uint256 i = 0; i < 35; i++) {
            oracle.postRebalanceSignal(
                poolId,
                _makeSignal(i, int24(-100 - int256(i)), int24(100 + int256(i)), 80)
            );
        }
        vm.stopPrank();

        // Should still have max 32 signals
        RebalanceSignal[] memory signals = oracle.getPositionsNeedingRebalance(poolId);
        assertLe(signals.length, 32);
    }

    // ── Staleness ──────────────────────────────────────────────────────
    function test_rejectStaleSignal() public {
        vm.warp(1000); // Ensure block.timestamp is large enough

        RebalanceSignal memory signal = RebalanceSignal({
            positionId: 1,
            newTickLower: -100,
            newTickUpper: 100,
            confidence: 80,
            timestamp: block.timestamp - 6 minutes // older than TTL
        });

        vm.prank(bot);
        vm.expectRevert(OpenClawOracle.StaleSignal.selector);
        oracle.postRebalanceSignal(poolId, signal);
    }

    function test_staleSignalsFilteredFromRetrieval() public {
        vm.prank(bot);
        oracle.postRebalanceSignal(poolId, _makeSignal(1, -100, 100, 80));

        // Fast forward past TTL
        vm.warp(block.timestamp + 6 minutes);

        RebalanceSignal[] memory signals = oracle.getPositionsNeedingRebalance(poolId);
        assertEq(signals.length, 0);
    }

    // ── Fee Recommendation ─────────────────────────────────────────────
    function test_postAndRetrieveFee() public {
        FeeRecommendation memory rec = FeeRecommendation({
            fee: 5000,
            confidence: 90,
            timestamp: block.timestamp
        });

        vm.prank(bot);
        oracle.postFeeRecommendation(poolId, rec);

        (uint24 fee, uint8 confidence) = oracle.getDynamicFee(poolId);
        assertEq(fee, 5000);
        assertEq(confidence, 90);
    }

    function test_staleFeeReturnsZero() public {
        FeeRecommendation memory rec = FeeRecommendation({
            fee: 5000,
            confidence: 90,
            timestamp: block.timestamp
        });

        vm.prank(bot);
        oracle.postFeeRecommendation(poolId, rec);

        vm.warp(block.timestamp + 6 minutes);

        (uint24 fee, uint8 confidence) = oracle.getDynamicFee(poolId);
        assertEq(fee, 0);
        assertEq(confidence, 0);
    }

    // ── Invalid Confidence ─────────────────────────────────────────────
    function test_rejectInvalidConfidence() public {
        RebalanceSignal memory signal = _makeSignal(1, -100, 100, 101);

        vm.prank(bot);
        vm.expectRevert(OpenClawOracle.InvalidConfidence.selector);
        oracle.postRebalanceSignal(poolId, signal);
    }

    // ── Optimal Range ──────────────────────────────────────────────────
    function test_getOptimalRange() public {
        vm.prank(bot);
        oracle.postRebalanceSignal(poolId, _makeSignal(42, -500, 500, 95));

        (int24 lower, int24 upper, uint8 confidence) = oracle.getOptimalRange(poolId, 42);
        assertEq(lower, -500);
        assertEq(upper, 500);
        assertEq(confidence, 95);
    }

    function test_getOptimalRange_notFound() public {
        (int24 lower, int24 upper, uint8 confidence) = oracle.getOptimalRange(poolId, 999);
        assertEq(lower, 0);
        assertEq(upper, 0);
        assertEq(confidence, 0);
    }

    // ── Clear Old Signals ──────────────────────────────────────────────
    function test_clearOldSignals() public {
        vm.prank(bot);
        oracle.postRebalanceSignal(poolId, _makeSignal(1, -100, 100, 80));

        vm.warp(block.timestamp + 6 minutes);
        oracle.clearOldSignals(poolId);

        RebalanceSignal[] memory signals = oracle.getPositionsNeedingRebalance(poolId);
        assertEq(signals.length, 0);
    }

    // ── Helpers ────────────────────────────────────────────────────────
    function _makeSignal(uint256 posId, int24 lower, int24 upper, uint8 conf)
        internal
        view
        returns (RebalanceSignal memory)
    {
        return RebalanceSignal({
            positionId: posId,
            newTickLower: lower,
            newTickUpper: upper,
            confidence: conf,
            timestamp: block.timestamp
        });
    }
}
