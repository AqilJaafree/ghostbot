// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {RebalanceSignal, FeeRecommendation} from "../types/DataTypes.sol";

interface IOpenClawOracle {
    event RebalanceSignalPosted(bytes32 indexed poolId, uint256 positionId, uint8 confidence);
    event FeeRecommendationPosted(bytes32 indexed poolId, uint24 fee, uint8 confidence);
    event SignalsCleared(bytes32 indexed poolId, uint256 count);

    function postRebalanceSignal(bytes32 poolId, RebalanceSignal calldata signal) external;
    function postFeeRecommendation(bytes32 poolId, FeeRecommendation calldata recommendation) external;
    function getPositionsNeedingRebalance(bytes32 poolId)
        external
        view
        returns (RebalanceSignal[] memory signals);
    function getDynamicFee(bytes32 poolId) external view returns (uint24 fee, uint8 confidence);
    function getOptimalRange(bytes32 poolId, uint256 positionId)
        external
        view
        returns (int24 newTickLower, int24 newTickUpper, uint8 confidence);
    function clearOldSignals(bytes32 poolId) external;
}
