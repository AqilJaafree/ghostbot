// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

enum OrderType {
    STOP_LOSS,
    TAKE_PROFIT,
    TRAILING_STOP
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
