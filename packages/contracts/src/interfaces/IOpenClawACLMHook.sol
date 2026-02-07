// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Position, LimitOrder, PoolStats, OrderType} from "../types/DataTypes.sol";

interface IOpenClawACLMHook {
    // Events
    event PositionCreated(
        uint256 indexed positionId, address indexed owner, int24 tickLower, int24 tickUpper, uint128 liquidity
    );
    event PositionClosed(uint256 indexed positionId, address indexed owner);
    event AutoRebalanced(
        uint256 indexed positionId, int24 oldTickLower, int24 oldTickUpper, int24 newTickLower, int24 newTickUpper
    );
    event DynamicFeeUpdated(bytes32 indexed poolId, uint24 oldFee, uint24 newFee);
    event LimitOrderPlaced(uint256 indexed orderId, address indexed owner, int24 triggerTick, bool zeroForOne);
    event LimitOrderCancelled(uint256 indexed orderId);
    event LimitOrderExecuted(uint256 indexed orderId, uint128 amountOut);

    // Position management
    function getUserPositions(address user) external view returns (uint256[] memory);
    function getPosition(uint256 positionId) external view returns (Position memory);
    function getPoolStats(bytes32 poolId) external view returns (PoolStats memory);

    // Limit orders
    function placeLimitOrder(
        PoolKey calldata key,
        bool zeroForOne,
        int24 triggerTick,
        uint128 amountIn,
        uint128 amountOutMin,
        OrderType orderType,
        uint256 linkedPositionId
    ) external returns (uint256 orderId);
    function cancelLimitOrder(uint256 orderId) external;
    function getUserLimitOrders(address user) external view returns (uint256[] memory);
    function getLimitOrder(uint256 orderId) external view returns (LimitOrder memory);
}
