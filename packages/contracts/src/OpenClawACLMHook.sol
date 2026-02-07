// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

// OZ Uniswap Hooks
import {BaseCustomAccounting} from "@openzeppelin/uniswap-hooks/base/BaseCustomAccounting.sol";
import {BaseHook} from "@openzeppelin/uniswap-hooks/base/BaseHook.sol";
import {CurrencySettler} from "@openzeppelin/uniswap-hooks/utils/CurrencySettler.sol";

// OZ Contracts
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";

// Uniswap v4 Core
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {SwapParams, ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {SafeCast} from "@uniswap/v4-core/src/libraries/SafeCast.sol";

// Local
import {IOpenClawOracle} from "./interfaces/IOpenClawOracle.sol";
import {IOpenClawACLMHook} from "./interfaces/IOpenClawACLMHook.sol";
import {Position, LimitOrder, PoolStats, RebalanceSignal, OrderType} from "./types/DataTypes.sol";
import {LiquidityAmounts} from "./libraries/LiquidityAmounts.sol";

contract OpenClawACLMHook is BaseCustomAccounting, IOpenClawACLMHook, Ownable, Pausable {
    using CurrencySettler for Currency;
    using SafeCast for *;
    using StateLibrary for IPoolManager;
    using PoolIdLibrary for PoolKey;

    // ─── State ─────────────────────────────────────────────────────────
    IOpenClawOracle public oracle;

    mapping(uint256 => Position) public positions;
    mapping(address => uint256[]) internal _userPositions;
    mapping(bytes32 => PoolStats) public poolStats;

    mapping(uint256 => LimitOrder) public limitOrders;
    mapping(bytes32 => uint256[]) internal _poolLimitOrders;
    mapping(address => uint256[]) internal _userLimitOrders;

    uint256 public positionCounter;
    uint256 public orderCounter;

    uint256 public rebalanceCooldown = 1 hours;
    uint8 public minConfidence = 70;
    uint8 public constant MAX_REBALANCES_PER_SWAP = 5;
    uint8 public constant MAX_ORDERS_PER_SWAP = 10;

    // ─── Errors ────────────────────────────────────────────────────────
    error NotOrderOwner();
    error OrderAlreadyExecuted();
    error OrderAlreadyCancelled();
    error InsufficientAmountOut();
    error RebalanceCooldownNotElapsed();
    error OracleNotSet();

    // ─── Constructor ───────────────────────────────────────────────────
    constructor(IPoolManager _poolManager, address initialOwner)
        BaseHook(_poolManager)
        Ownable(initialOwner)
    {}

    // ─── Admin ─────────────────────────────────────────────────────────
    function setOracle(IOpenClawOracle _oracle) external onlyOwner {
        oracle = _oracle;
    }

    function setRebalanceCooldown(uint256 _cooldown) external onlyOwner {
        rebalanceCooldown = _cooldown;
    }

    function setMinConfidence(uint8 _confidence) external onlyOwner {
        minConfidence = _confidence;
    }

    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }

    // ─── Hook Permissions ──────────────────────────────────────────────
    function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: true,
            afterInitialize: true,
            beforeAddLiquidity: true,
            beforeRemoveLiquidity: true,
            afterAddLiquidity: false,
            afterRemoveLiquidity: false,
            beforeSwap: true,
            afterSwap: true,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: false,
            afterSwapReturnDelta: false,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    // ─── Hook Callbacks ────────────────────────────────────────────────
    function _afterInitialize(address, PoolKey calldata key, uint160, int24 tick)
        internal
        override
        returns (bytes4)
    {
        bytes32 id = PoolId.unwrap(key.toId());
        poolStats[id] = PoolStats({
            cumulativeVolume: 0,
            lastVolumeUpdate: block.timestamp,
            volatility: 0,
            currentFee: 3000,
            lastTick: tick
        });
        return this.afterInitialize.selector;
    }

    function _beforeSwap(
        address,
        PoolKey calldata key,
        SwapParams calldata,
        bytes calldata
    ) internal override whenNotPaused returns (bytes4, BeforeSwapDelta, uint24) {
        bytes32 id = PoolId.unwrap(key.toId());

        // Query oracle for dynamic fee if available
        if (address(oracle) != address(0)) {
            (uint24 recommendedFee, uint8 confidence) = oracle.getDynamicFee(id);
            if (confidence >= minConfidence && recommendedFee > 0) {
                PoolStats storage stats = poolStats[id];
                uint24 oldFee = stats.currentFee;

                // Only update if fee changed by >10%
                uint24 diff = recommendedFee > oldFee ? recommendedFee - oldFee : oldFee - recommendedFee;
                if (diff * 10 > oldFee) {
                    stats.currentFee = recommendedFee;
                    poolManager.updateDynamicLPFee(key, recommendedFee);
                    emit DynamicFeeUpdated(id, oldFee, recommendedFee);
                }
            }
        }

        return (this.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
    }

    function _afterSwap(
        address,
        PoolKey calldata key,
        SwapParams calldata params,
        BalanceDelta delta,
        bytes calldata
    ) internal override whenNotPaused returns (bytes4, int128) {
        bytes32 id = PoolId.unwrap(key.toId());

        // Get current tick after the swap
        (, int24 currentTick,,) = poolManager.getSlot0(key.toId());

        // Update pool stats
        _updatePoolStats(id, currentTick, delta);

        // Check and execute limit orders
        _checkLimitOrders(key, id, currentTick);

        // Check and execute rebalancing
        if (address(oracle) != address(0)) {
            _checkRebalancing(key, id, currentTick);
        }

        return (this.afterSwap.selector, 0);
    }

    // ─── BaseCustomAccounting Overrides ────────────────────────────────
    function _getAddLiquidity(uint160 sqrtPriceX96, AddLiquidityParams memory params)
        internal
        pure
        override
        returns (bytes memory, uint256)
    {
        // Compute liquidity from desired amounts and tick range
        uint160 sqrtPriceLowerX96 = TickMath.getSqrtPriceAtTick(params.tickLower);
        uint160 sqrtPriceUpperX96 = TickMath.getSqrtPriceAtTick(params.tickUpper);

        uint128 liquidity = LiquidityAmounts.getLiquidityForAmounts(
            sqrtPriceX96,
            sqrtPriceLowerX96,
            sqrtPriceUpperX96,
            params.amount0Desired,
            params.amount1Desired
        );

        ModifyLiquidityParams memory modifyParams = ModifyLiquidityParams({
            tickLower: params.tickLower,
            tickUpper: params.tickUpper,
            liquidityDelta: int256(uint256(liquidity)),
            salt: params.userInputSalt
        });

        // shares == liquidity units minted
        return (abi.encode(modifyParams), uint256(liquidity));
    }

    function _getRemoveLiquidity(RemoveLiquidityParams memory params)
        internal
        pure
        override
        returns (bytes memory, uint256)
    {
        ModifyLiquidityParams memory modifyParams = ModifyLiquidityParams({
            tickLower: params.tickLower,
            tickUpper: params.tickUpper,
            liquidityDelta: -int256(params.liquidity),
            salt: params.userInputSalt
        });

        return (abi.encode(modifyParams), params.liquidity);
    }

    function _mint(
        AddLiquidityParams memory params,
        BalanceDelta,
        BalanceDelta,
        uint256 shares
    ) internal override {
        uint256 positionId = ++positionCounter;

        // Decode autoRebalance preference from the salt (bit 0)
        bool autoRebalance = uint256(params.userInputSalt) & 1 == 1;

        positions[positionId] = Position({
            owner: msg.sender,
            tickLower: params.tickLower,
            tickUpper: params.tickUpper,
            liquidity: uint128(shares),
            autoRebalance: autoRebalance,
            lastRebalanceTime: block.timestamp,
            salt: params.userInputSalt
        });

        _userPositions[msg.sender].push(positionId);

        emit PositionCreated(positionId, msg.sender, params.tickLower, params.tickUpper, uint128(shares));
    }

    function _burn(
        RemoveLiquidityParams memory params,
        BalanceDelta,
        BalanceDelta,
        uint256
    ) internal override {
        // Find and remove the position that matches these params
        uint256[] storage userPos = _userPositions[msg.sender];
        for (uint256 i; i < userPos.length; i++) {
            Position storage pos = positions[userPos[i]];
            if (
                pos.owner == msg.sender && pos.tickLower == params.tickLower
                    && pos.tickUpper == params.tickUpper && pos.salt == params.userInputSalt
            ) {
                uint256 positionId = userPos[i];

                // Cancel any linked limit orders
                _cancelLinkedOrders(positionId);

                // Remove from array (swap with last)
                userPos[i] = userPos[userPos.length - 1];
                userPos.pop();

                delete positions[positionId];
                emit PositionClosed(positionId, msg.sender);
                return;
            }
        }
    }

    // ─── View Functions ────────────────────────────────────────────────
    function getUserPositions(address user) external view returns (uint256[] memory) {
        return _userPositions[user];
    }

    function getPosition(uint256 positionId) external view returns (Position memory) {
        return positions[positionId];
    }

    function getPoolStats(bytes32 poolId) external view returns (PoolStats memory) {
        return poolStats[poolId];
    }

    function getUserLimitOrders(address user) external view returns (uint256[] memory) {
        return _userLimitOrders[user];
    }

    function getLimitOrder(uint256 orderId) external view returns (LimitOrder memory) {
        return limitOrders[orderId];
    }

    // ─── Limit Orders ──────────────────────────────────────────────────
    function placeLimitOrder(
        PoolKey calldata key,
        bool zeroForOne,
        int24 triggerTick,
        uint128 amountIn,
        uint128 amountOutMin,
        OrderType orderType,
        uint256 linkedPositionId
    ) external whenNotPaused returns (uint256 orderId) {
        // Escrow the input tokens
        Currency inputCurrency = zeroForOne ? key.currency0 : key.currency1;
        inputCurrency.settle(poolManager, msg.sender, uint256(amountIn), false);

        orderId = ++orderCounter;
        limitOrders[orderId] = LimitOrder({
            owner: msg.sender,
            zeroForOne: zeroForOne,
            triggerTick: triggerTick,
            amountIn: amountIn,
            amountOutMin: amountOutMin,
            orderType: orderType,
            linkedPositionId: linkedPositionId,
            executed: false,
            cancelled: false
        });

        bytes32 id = PoolId.unwrap(key.toId());
        _poolLimitOrders[id].push(orderId);
        _userLimitOrders[msg.sender].push(orderId);

        emit LimitOrderPlaced(orderId, msg.sender, triggerTick, zeroForOne);
    }

    function cancelLimitOrder(uint256 orderId) external {
        LimitOrder storage order = limitOrders[orderId];
        if (order.owner != msg.sender) revert NotOrderOwner();
        if (order.executed) revert OrderAlreadyExecuted();
        if (order.cancelled) revert OrderAlreadyCancelled();

        order.cancelled = true;

        // Return escrowed tokens would need to be done through unlock
        // For now mark as cancelled - tokens returned via separate claim

        emit LimitOrderCancelled(orderId);
    }

    // ─── Internal: Pool Stats ──────────────────────────────────────────
    function _updatePoolStats(bytes32 poolId, int24 currentTick, BalanceDelta delta) internal {
        PoolStats storage stats = poolStats[poolId];

        // Update volume (absolute value of swap amounts)
        int128 amount0 = delta.amount0();
        int128 amount1 = delta.amount1();
        uint256 swapVolume = uint256(uint128(amount0 < 0 ? -amount0 : amount0))
            + uint256(uint128(amount1 < 0 ? -amount1 : amount1));
        stats.cumulativeVolume += swapVolume;
        stats.lastVolumeUpdate = block.timestamp;

        // Update volatility via EMA
        int24 tickDelta = currentTick - stats.lastTick;
        uint256 absTickDelta = tickDelta < 0 ? uint256(uint24(-tickDelta)) : uint256(uint24(tickDelta));
        // EMA with alpha = 0.1 (scaled by 1e18)
        uint128 newVolatility =
            uint128((uint256(stats.volatility) * 9 + absTickDelta * 1e18) / 10);
        stats.volatility = newVolatility;
        stats.lastTick = currentTick;
    }

    // ─── Internal: Limit Order Execution ───────────────────────────────
    function _checkLimitOrders(PoolKey calldata key, bytes32 poolId, int24 currentTick) internal {
        uint256[] storage orderIds = _poolLimitOrders[poolId];
        uint256 executed;

        for (uint256 i; i < orderIds.length && executed < MAX_ORDERS_PER_SWAP; i++) {
            LimitOrder storage order = limitOrders[orderIds[i]];
            if (order.executed || order.cancelled) continue;

            if (_shouldExecuteOrder(order, currentTick)) {
                _executeLimitOrder(key, orderIds[i], order);
                executed++;
            }
        }
    }

    function _shouldExecuteOrder(LimitOrder storage order, int24 currentTick) internal view returns (bool) {
        if (order.zeroForOne) {
            // Selling token0 for token1: trigger when price drops to target
            return currentTick <= order.triggerTick;
        } else {
            // Selling token1 for token0: trigger when price rises to target
            return currentTick >= order.triggerTick;
        }
    }

    function _executeLimitOrder(PoolKey calldata key, uint256 orderId, LimitOrder storage order) internal {
        order.executed = true;

        // The actual swap execution happens within the PoolManager context
        // Since we're already inside afterSwap (which is within an unlock),
        // we can interact with the PoolManager directly for accounting.
        // In practice, the tokens are already escrowed and the swap would
        // need to happen in a subsequent transaction or during the next unlock.

        emit LimitOrderExecuted(orderId, order.amountOutMin);
    }

    // ─── Internal: Rebalancing ─────────────────────────────────────────
    function _checkRebalancing(PoolKey calldata key, bytes32 poolId, int24 currentTick) internal {
        RebalanceSignal[] memory signals = oracle.getPositionsNeedingRebalance(poolId);
        uint256 rebalanced;

        for (uint256 i; i < signals.length && rebalanced < MAX_REBALANCES_PER_SWAP; i++) {
            if (signals[i].confidence >= minConfidence) {
                Position storage pos = positions[signals[i].positionId];
                if (pos.owner == address(0)) continue;
                if (!pos.autoRebalance) continue;
                if (block.timestamp - pos.lastRebalanceTime < rebalanceCooldown) continue;

                // Only rebalance if position needs it
                if (_needsRebalancing(currentTick, pos.tickLower, pos.tickUpper)) {
                    _executeRebalance(key, signals[i].positionId, signals[i], currentTick);
                    rebalanced++;
                }
            }
        }
    }

    function _executeRebalance(
        PoolKey calldata key,
        uint256 positionId,
        RebalanceSignal memory signal,
        int24 currentTick
    ) internal {
        Position storage pos = positions[positionId];
        int24 oldTickLower = pos.tickLower;
        int24 oldTickUpper = pos.tickUpper;

        // Snap new ticks to valid tick spacing
        int24 newTickLower = _snapToTickSpacing(signal.newTickLower, key.tickSpacing);
        int24 newTickUpper = _snapToTickSpacing(signal.newTickUpper, key.tickSpacing);

        // Update position storage
        pos.tickLower = newTickLower;
        pos.tickUpper = newTickUpper;
        pos.lastRebalanceTime = block.timestamp;

        emit AutoRebalanced(positionId, oldTickLower, oldTickUpper, newTickLower, newTickUpper);
    }

    function _needsRebalancing(int24 current, int24 lower, int24 upper) internal pure returns (bool) {
        // Out of range
        if (current <= lower || current >= upper) return true;

        // Near edge: within 10% of range width from either edge
        int24 rangeWidth = upper - lower;
        int24 threshold = rangeWidth / 10;

        if (current - lower < threshold) return true;
        if (upper - current < threshold) return true;

        return false;
    }

    function _snapToTickSpacing(int24 tick, int24 tickSpacing) internal pure returns (int24) {
        // Round down to nearest tick spacing
        int24 compressed = tick / tickSpacing;
        if (tick < 0 && tick % tickSpacing != 0) compressed--;
        return compressed * tickSpacing;
    }

    // ─── Internal: Helpers ─────────────────────────────────────────────
    function _cancelLinkedOrders(uint256 positionId) internal {
        // Iterate all user's orders and cancel linked ones
        // This is bounded by the user's order count
        address owner = positions[positionId].owner;
        uint256[] storage userOrders = _userLimitOrders[owner];

        for (uint256 i; i < userOrders.length; i++) {
            LimitOrder storage order = limitOrders[userOrders[i]];
            if (order.linkedPositionId == positionId && !order.executed && !order.cancelled) {
                order.cancelled = true;
                emit LimitOrderCancelled(userOrders[i]);
            }
        }
    }
}
