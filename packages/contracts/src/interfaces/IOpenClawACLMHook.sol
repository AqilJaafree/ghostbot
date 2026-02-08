// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {Position, LimitOrder, PoolStats, OrderType} from "../types/DataTypes.sol";

interface IOpenClawACLMHook {
    // Position management
    function getUserPositions(address user) external view returns (uint256[] memory);
    function getPosition(uint256 positionId) external view returns (Position memory);
    function getPoolStats(bytes32 poolId) external view returns (PoolStats memory);
    function rebalancePosition(uint256 positionId, int24 newTickLower, int24 newTickUpper) external;
    function removePosition(uint256 positionId, uint256 amount0Min, uint256 amount1Min, uint256 deadline)
        external
        returns (BalanceDelta);
    function claimRebalanceSurplus(uint256 positionId, Currency currency) external;

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
    function claimFilledOrder(uint256 orderId) external;
    function getUserLimitOrders(address user) external view returns (uint256[] memory);
    function getLimitOrder(uint256 orderId) external view returns (LimitOrder memory);
}
