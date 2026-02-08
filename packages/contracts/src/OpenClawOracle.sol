// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IOpenClawOracle} from "./interfaces/IOpenClawOracle.sol";
import {RebalanceSignal, FeeRecommendation} from "./types/DataTypes.sol";
contract OpenClawOracle is IOpenClawOracle, Ownable {
    uint256 public constant MAX_SIGNALS_PER_POOL = 32;

    address public bot;
    address public hook;
    uint256 public signalTTL = 5 minutes;

    // poolId => circular buffer of rebalance signals
    mapping(bytes32 => RebalanceSignal[]) internal _signals;
    mapping(bytes32 => uint256) internal _signalWriteIndex;

    // poolId => fee recommendation
    mapping(bytes32 => FeeRecommendation) internal _feeRecommendations;

    error OnlyBot();
    error OnlyHook();
    error StaleSignal();
    error FutureTimestamp();
    error InvalidConfidence();

    event RebalanceSignalPosted(bytes32 indexed poolId, uint256 positionId, uint8 confidence);
    event FeeRecommendationPosted(bytes32 indexed poolId, uint24 fee, uint8 confidence);
    event SignalsCleared(bytes32 indexed poolId, uint256 count);
    event OrderExecutionReported(bytes32 indexed poolId, uint256 indexed orderId);

    modifier onlyBot() {
        if (msg.sender != bot) revert OnlyBot();
        _;
    }

    modifier onlyHook() {
        if (msg.sender != hook) revert OnlyHook();
        _;
    }

    constructor(address initialOwner) Ownable(initialOwner) {}

    function setBot(address _bot) external onlyOwner {
        bot = _bot;
    }

    function setHook(address _hook) external onlyOwner {
        hook = _hook;
    }

    /// @notice Allows the hook to report that a limit order was executed, for off-chain indexing.
    /// @param poolId The pool identifier.
    /// @param orderId The limit order that was executed.
    function reportOrderExecution(bytes32 poolId, uint256 orderId) external onlyHook {
        emit OrderExecutionReported(poolId, orderId);
    }

    function setSignalTTL(uint256 _ttl) external onlyOwner {
        signalTTL = _ttl;
    }

    function postRebalanceSignal(bytes32 poolId, RebalanceSignal calldata signal) external onlyBot {
        if (signal.confidence > 100) revert InvalidConfidence();
        if (signal.timestamp > block.timestamp) revert FutureTimestamp();
        if (block.timestamp - signal.timestamp > signalTTL) revert StaleSignal();

        RebalanceSignal[] storage signals = _signals[poolId];
        uint256 writeIdx = _signalWriteIndex[poolId];

        if (signals.length < MAX_SIGNALS_PER_POOL) {
            signals.push(signal);
        } else {
            signals[writeIdx % MAX_SIGNALS_PER_POOL] = signal;
        }
        _signalWriteIndex[poolId] = writeIdx + 1;

        emit RebalanceSignalPosted(poolId, signal.positionId, signal.confidence);
    }

    function postFeeRecommendation(bytes32 poolId, FeeRecommendation calldata recommendation)
        external
        onlyBot
    {
        if (recommendation.confidence > 100) revert InvalidConfidence();
        if (recommendation.timestamp > block.timestamp) revert FutureTimestamp();
        if (block.timestamp - recommendation.timestamp > signalTTL) revert StaleSignal();

        _feeRecommendations[poolId] = recommendation;
        emit FeeRecommendationPosted(poolId, recommendation.fee, recommendation.confidence);
    }

    function getPositionsNeedingRebalance(bytes32 poolId)
        external
        view
        returns (RebalanceSignal[] memory signals)
    {
        RebalanceSignal[] storage stored = _signals[poolId];
        uint256 count;

        // First pass: count valid (non-stale) signals
        for (uint256 i; i < stored.length; i++) {
            if (block.timestamp - stored[i].timestamp <= signalTTL) {
                count++;
            }
        }

        // Second pass: collect them
        signals = new RebalanceSignal[](count);
        uint256 idx;
        for (uint256 i; i < stored.length; i++) {
            if (block.timestamp - stored[i].timestamp <= signalTTL) {
                signals[idx++] = stored[i];
            }
        }
    }

    function getDynamicFee(bytes32 poolId) external view returns (uint24 fee, uint8 confidence) {
        FeeRecommendation storage rec = _feeRecommendations[poolId];
        if (rec.timestamp == 0 || block.timestamp - rec.timestamp > signalTTL) {
            return (0, 0);
        }
        return (rec.fee, rec.confidence);
    }

    function getOptimalRange(bytes32 poolId, uint256 positionId)
        external
        view
        returns (int24 newTickLower, int24 newTickUpper, uint8 confidence)
    {
        RebalanceSignal[] storage stored = _signals[poolId];
        for (uint256 i; i < stored.length; i++) {
            if (
                stored[i].positionId == positionId
                    && block.timestamp - stored[i].timestamp <= signalTTL
            ) {
                return (stored[i].newTickLower, stored[i].newTickUpper, stored[i].confidence);
            }
        }
        return (0, 0, 0);
    }

    function clearOldSignals(bytes32 poolId) external {
        RebalanceSignal[] storage stored = _signals[poolId];
        uint256 cleared;
        uint256 i;

        while (i < stored.length) {
            if (block.timestamp - stored[i].timestamp > signalTTL) {
                // Swap-and-pop to actually shrink the array
                stored[i] = stored[stored.length - 1];
                stored.pop();
                cleared++;
                // Do not increment i; re-check the swapped element
            } else {
                i++;
            }
        }

        // Reset write index to match new array length
        _signalWriteIndex[poolId] = stored.length;

        emit SignalsCleared(poolId, cleared);
    }
}
