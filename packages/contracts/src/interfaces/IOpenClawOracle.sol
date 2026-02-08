// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {RebalanceSignal, FeeRecommendation} from "../types/DataTypes.sol";

interface IOpenClawOracle {
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
    function reportOrderExecution(bytes32 poolId, uint256 orderId) external;
}
