// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";

enum OrderType {
    STOP_LOSS,
    TAKE_PROFIT,
    TRAILING_STOP
}

enum CallbackType {
    REBALANCE,
    CLAIM_ORDER,
    CANCEL_ORDER,
    REMOVE_POSITION,
    PLACE_ORDER,
    BULK_CANCEL_ORDERS,
    CLAIM_SURPLUS
}

struct RemovePositionCallbackData {
    uint256 positionId;
    int24 tickLower;
    int24 tickUpper;
    uint128 liquidity;
    bytes32 positionSalt;
    address owner;
}

struct RebalanceCallbackData {
    uint256 positionId;
    int24 oldTickLower;
    int24 oldTickUpper;
    int24 newTickLower;
    int24 newTickUpper;
    uint128 liquidity;
    bytes32 positionSalt;
}

struct ClaimCallbackData {
    Currency currency;
    uint256 amount;
    address to;
}

struct CancelOrderCallbackData {
    Currency currency;
    uint256 amount;
    address to;
}

struct PlaceOrderCallbackData {
    Currency currency;
    uint256 amount;
    address payer;
}

struct BulkCancelOrdersCallbackData {
    Currency[] currencies;
    uint256[] amounts;
    address to;
}

struct ClaimSurplusCallbackData {
    Currency currency;
    uint256 amount;
    address to;
}

struct Position {
    address owner;
    int24 tickLower;
    int24 tickUpper;
    uint128 liquidity;
    bool autoRebalance;
    uint256 lastRebalanceTime;
    bytes32 salt;
}

struct LimitOrder {
    address owner;
    bool zeroForOne;
    int24 triggerTick;
    uint128 amountIn;
    uint128 amountOutMin;
    OrderType orderType;
    uint256 linkedPositionId;
    bool executed;
    bool cancelled;
    Currency claimCurrency;
    uint128 claimAmount;
}

struct PoolStats {
    uint256 cumulativeVolume;
    uint256 lastVolumeUpdate;
    uint128 volatility; // EMA volatility scaled by 1e18
    uint24 currentFee;
    int24 lastTick;
}

struct RebalanceSignal {
    uint256 positionId;
    int24 newTickLower;
    int24 newTickUpper;
    uint8 confidence; // 0-100
    uint256 timestamp;
}

struct FeeRecommendation {
    uint24 fee;
    uint8 confidence; // 0-100
    uint256 timestamp;
}
