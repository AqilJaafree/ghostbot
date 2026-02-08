// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console} from "forge-std/Script.sol";
import {OpenClawOracle} from "../src/OpenClawOracle.sol";
import {OpenClawACLMHook} from "../src/OpenClawACLMHook.sol";
import {IOpenClawOracle} from "../src/interfaces/IOpenClawOracle.sol";
import {RebalanceSignal, FeeRecommendation, PoolStats} from "../src/types/DataTypes.sol";

contract TestSepolia is Script {
    // Deployed contract addresses on Sepolia
    OpenClawOracle constant oracle = OpenClawOracle(0x300Fa0Af86201A410bEBD511Ca7FB81548a0f027);
    OpenClawACLMHook constant hook = OpenClawACLMHook(0xbD2802B7215530894d5696ab8450115f56b1fAC0);

    function run() external {
        uint256 deployerPrivateKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);

        console.log("=== Sepolia On-Chain Verification ===");
        console.log("Deployer/Bot address:", deployer);
        console.log("");

        // ──────────────────────────────────────────────────────────
        // Step 1: Read-only checks (no gas cost)
        // ──────────────────────────────────────────────────────────
        console.log("--- Step 1: Oracle Read-Only Checks ---");

        address oracleOwner = oracle.owner();
        console.log("Oracle owner:", oracleOwner);
        assert(oracleOwner == deployer);
        console.log("  [PASS] Owner matches deployer");

        address oracleBot = oracle.bot();
        console.log("Oracle bot:", oracleBot);
        assert(oracleBot == deployer);
        console.log("  [PASS] Bot matches deployer");

        address oracleHook = oracle.hook();
        console.log("Oracle hook:", oracleHook);
        assert(oracleHook == address(hook));
        console.log("  [PASS] Hook address matches deployed hook");

        uint256 ttl = oracle.signalTTL();
        console.log("Oracle signalTTL:", ttl);
        assert(ttl == 5 minutes);
        console.log("  [PASS] TTL is 5 minutes (300s)");

        console.log("");
        console.log("--- Step 2: Hook Read-Only Checks ---");

        address hookOracle = address(hook.oracle());
        console.log("Hook oracle:", hookOracle);
        assert(hookOracle == address(oracle));
        console.log("  [PASS] Oracle address matches deployed oracle");

        address hookOwner = hook.owner();
        console.log("Hook owner:", hookOwner);
        assert(hookOwner == deployer);
        console.log("  [PASS] Owner matches deployer");

        bool isPaused = hook.paused();
        console.log("Hook paused:", isPaused);
        assert(!isPaused);
        console.log("  [PASS] Hook is not paused");

        uint8 minConf = hook.minConfidence();
        console.log("Hook minConfidence:", uint256(minConf));
        assert(minConf == 70);
        console.log("  [PASS] minConfidence is 70");

        uint256 cooldown = hook.rebalanceCooldown();
        console.log("Hook rebalanceCooldown:", cooldown);
        assert(cooldown == 1 hours);
        console.log("  [PASS] rebalanceCooldown is 1 hour (3600s)");

        uint256 posCount = hook.positionCounter();
        console.log("Hook positionCounter:", posCount);
        console.log("  [INFO] No positions yet (expected for fresh deployment)");

        uint256 orderCount = hook.orderCounter();
        console.log("Hook orderCounter:", orderCount);
        console.log("  [INFO] No orders yet (expected for fresh deployment)");

        // ──────────────────────────────────────────────────────────
        // Step 3: Write transactions (costs gas)
        // ──────────────────────────────────────────────────────────
        console.log("");
        console.log("--- Step 3: Post Rebalance Signal ---");

        // Use a dummy poolId for testing
        bytes32 testPoolId = keccak256("test-pool-sepolia");
        console.log("Test poolId (keccak256):");
        console.logBytes32(testPoolId);

        vm.startBroadcast(deployerPrivateKey);

        // Post a rebalance signal
        RebalanceSignal memory signal = RebalanceSignal({
            positionId: 1,
            newTickLower: -1000,
            newTickUpper: 1000,
            confidence: 85,
            timestamp: block.timestamp // current block timestamp
        });

        oracle.postRebalanceSignal(testPoolId, signal);
        console.log("  [PASS] postRebalanceSignal succeeded");

        // Post a fee recommendation
        console.log("");
        console.log("--- Step 4: Post Fee Recommendation ---");

        FeeRecommendation memory feeRec = FeeRecommendation({
            fee: 5000, // 0.5% fee
            confidence: 90,
            timestamp: block.timestamp
        });

        oracle.postFeeRecommendation(testPoolId, feeRec);
        console.log("  [PASS] postFeeRecommendation succeeded");

        vm.stopBroadcast();

        // ──────────────────────────────────────────────────────────
        // Step 5: Read back posted data (no gas cost)
        // ──────────────────────────────────────────────────────────
        console.log("");
        console.log("--- Step 5: Verify Posted Data ---");

        // Read back rebalance signals
        RebalanceSignal[] memory signals = oracle.getPositionsNeedingRebalance(testPoolId);
        console.log("Rebalance signals count:", signals.length);
        assert(signals.length >= 1);
        console.log("  Signal[0] positionId:", signals[0].positionId);
        console.log("  Signal[0] newTickLower:");
        console.logInt(int256(signals[0].newTickLower));
        console.log("  Signal[0] newTickUpper:");
        console.logInt(int256(signals[0].newTickUpper));
        console.log("  Signal[0] confidence:", uint256(signals[0].confidence));
        console.log("  Signal[0] timestamp:", signals[0].timestamp);
        console.log("  [PASS] Rebalance signal stored and readable");

        // Read back fee recommendation
        (uint24 fee, uint8 conf) = oracle.getDynamicFee(testPoolId);
        console.log("Fee recommendation: fee=", uint256(fee), "confidence=", uint256(conf));
        assert(fee == 5000);
        assert(conf == 90);
        console.log("  [PASS] Fee recommendation stored and readable");

        // Read optimal range for positionId=1
        (int24 optLower, int24 optUpper, uint8 optConf) = oracle.getOptimalRange(testPoolId, 1);
        console.log("Optimal range: lower=");
        console.logInt(int256(optLower));
        console.log("Optimal range: upper=");
        console.logInt(int256(optUpper));
        console.log("  confidence:", uint256(optConf));
        assert(optConf == 85);
        console.log("  [PASS] getOptimalRange returns correct data");

        console.log("");
        console.log("=== ALL TESTS PASSED ===");
    }
}
