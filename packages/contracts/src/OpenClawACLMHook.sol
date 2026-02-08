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
import {
    Position,
    LimitOrder,
    PoolStats,
    RebalanceSignal,
    OrderType,
    CallbackType,
    RebalanceCallbackData,
    ClaimCallbackData,
    CancelOrderCallbackData,
    RemovePositionCallbackData,
    PlaceOrderCallbackData,
    BulkCancelOrdersCallbackData,
    ClaimSurplusCallbackData
} from "./types/DataTypes.sol";
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

    // H-4 fix: Track rebalance surplus claimable per position per currency
    mapping(uint256 => mapping(Currency => uint256)) public rebalanceSurplus;

    // H-2 fix: Reentrancy guard for limit order execution during nested swaps
    bool private _executingOrders;

    uint256 public positionCounter;
    uint256 public orderCounter;

    uint256 public rebalanceCooldown = 1 hours;
    uint8 public minConfidence = 70;
    uint8 public constant MAX_REBALANCES_PER_SWAP = 5;
    uint8 public constant MAX_ORDERS_PER_SWAP = 10;
    uint24 public constant MAX_FEE = 1_000_000;

    // ─── Errors ──────────────────────────────────────────────────────────
    error InvalidPoolKey();
    error InvalidTickRange();
    error PositionNotFound();
    error PositionNotFoundOnBurn();
    error NotAutoRebalance();
    error NotPositionOwner();
    error OrderNotExecuted();
    error AlreadyClaimed();
    error NotOrderOwner();
    error OrderAlreadyExecuted();
    error OrderAlreadyCancelled();
    error FeeTooHigh();
    error MinConfidenceTooLow();
    error CooldownTooLow();
    error RebalanceCooldownNotElapsed();
    error InsufficientAmountOut();
    error OracleNotSet();
    error NoSurplusToClaim();

    // ─── Events ──────────────────────────────────────────────────────────
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
    event LimitOrderExecutionFailed(uint256 indexed orderId, bytes reason);
    event LimitOrderClaimed(uint256 indexed orderId, address indexed owner, uint128 amount);
    event RebalanceRequested(uint256 indexed positionId, int24 newTickLower, int24 newTickUpper);
    event SurplusClaimed(uint256 indexed positionId, address indexed owner, Currency currency, uint256 amount);

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
        if (_cooldown < 1 minutes && _cooldown != 0) revert CooldownTooLow();
        rebalanceCooldown = _cooldown;
    }

    function setMinConfidence(uint8 _confidence) external onlyOwner {
        if (_confidence < 10) revert MinConfidenceTooLow();
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
                // H-4: Fee upper bound
                if (recommendedFee > MAX_FEE) revert FeeTooHigh();

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
        SwapParams calldata,
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

        // Emit rebalance signals (detection only — execution via rebalancePosition)
        if (address(oracle) != address(0)) {
            _checkRebalancing(key, id, currentTick);
        }

        return (this.afterSwap.selector, 0);
    }

    // ─── Unlock Callback Override ───────────────────────────────────────
    // BaseCustomAccounting encodes `CallbackData(address sender, ModifyLiquidityParams)`.
    // The first 32 bytes are always a valid non-zero address. We use address(0) as a
    // sentinel to distinguish our custom callbacks: (address(0), CallbackType, bytes).
    function unlockCallback(bytes calldata rawData)
        public
        virtual
        override
        onlyPoolManager
        returns (bytes memory)
    {
        // Check if first 32 bytes are address(0) — our custom callback sentinel
        address sentinel = abi.decode(rawData[:32], (address));
        if (sentinel == address(0)) {
            (, CallbackType cbType, bytes memory cbData) = abi.decode(rawData, (address, CallbackType, bytes));
            if (cbType == CallbackType.REBALANCE) {
                return _handleRebalanceCallback(cbData);
            } else if (cbType == CallbackType.CLAIM_ORDER) {
                return _handleClaimCallback(cbData);
            } else if (cbType == CallbackType.CANCEL_ORDER) {
                return _handleCancelCallback(cbData);
            } else if (cbType == CallbackType.REMOVE_POSITION) {
                return _handleRemovePositionCallback(cbData);
            } else if (cbType == CallbackType.PLACE_ORDER) {
                return _handlePlaceOrderCallback(cbData);
            } else if (cbType == CallbackType.BULK_CANCEL_ORDERS) {
                return _handleBulkCancelCallback(cbData);
            } else if (cbType == CallbackType.CLAIM_SURPLUS) {
                return _handleClaimSurplusCallback(cbData);
            }
        }

        // Fallback to BaseCustomAccounting's default handling
        return super.unlockCallback(rawData);
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

                // Cancel any linked limit orders (H-1 fix: returns escrowed tokens)
                _cancelLinkedOrders(positionId);

                // Remove from array (swap with last)
                userPos[i] = userPos[userPos.length - 1];
                userPos.pop();

                delete positions[positionId];
                emit PositionClosed(positionId, msg.sender);
                return;
            }
        }
        // M-5 fix: Revert if no matching position was found
        revert PositionNotFoundOnBurn();
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

    // ─── Rebalance (C-2 fix) ───────────────────────────────────────────
    function rebalancePosition(uint256 positionId, int24 newTickLower, int24 newTickUpper) external onlyOwner {
        Position storage pos = positions[positionId];
        if (pos.owner == address(0)) revert PositionNotFound();
        if (!pos.autoRebalance) revert NotAutoRebalance();
        if (block.timestamp - pos.lastRebalanceTime < rebalanceCooldown) revert RebalanceCooldownNotElapsed();

        // H-1: Bounds checking
        PoolKey memory key_ = poolKey();
        int24 snappedLower = _snapToTickSpacing(newTickLower, key_.tickSpacing);
        int24 snappedUpper = _snapToTickSpacing(newTickUpper, key_.tickSpacing);
        if (snappedLower >= snappedUpper) revert InvalidTickRange();
        if (snappedLower < TickMath.MIN_TICK || snappedUpper > TickMath.MAX_TICK) revert InvalidTickRange();

        bytes32 positionSalt = keccak256(abi.encode(pos.owner, pos.salt));

        poolManager.unlock(abi.encode(
            address(0), // sentinel for custom callback
            CallbackType.REBALANCE,
            abi.encode(RebalanceCallbackData({
                positionId: positionId,
                oldTickLower: pos.tickLower,
                oldTickUpper: pos.tickUpper,
                newTickLower: snappedLower,
                newTickUpper: snappedUpper,
                liquidity: pos.liquidity,
                positionSalt: positionSalt
            }))
        ));

        // Update storage after successful unlock
        int24 oldLower = pos.tickLower;
        int24 oldUpper = pos.tickUpper;
        pos.tickLower = snappedLower;
        pos.tickUpper = snappedUpper;
        pos.lastRebalanceTime = block.timestamp;

        emit AutoRebalanced(positionId, oldLower, oldUpper, snappedLower, snappedUpper);
    }

    // ─── Remove Position by ID (H-3 fix) ──────────────────────────────
    function removePosition(uint256 positionId, uint256 amount0Min, uint256 amount1Min, uint256 deadline)
        external
        returns (BalanceDelta)
    {
        if (block.timestamp > deadline) revert ExpiredPastDeadline();

        Position storage pos = positions[positionId];
        if (pos.owner != msg.sender) revert NotPositionOwner();

        bytes32 positionSalt = keccak256(abi.encode(pos.owner, pos.salt));

        bytes memory result = poolManager.unlock(abi.encode(
            address(0), // sentinel for custom callback
            CallbackType.REMOVE_POSITION,
            abi.encode(RemovePositionCallbackData({
                positionId: positionId,
                tickLower: pos.tickLower,
                tickUpper: pos.tickUpper,
                liquidity: pos.liquidity,
                positionSalt: positionSalt,
                owner: pos.owner
            }))
        ));

        BalanceDelta delta = abi.decode(result, (BalanceDelta));

        // Slippage check
        if (uint128(delta.amount0()) < amount0Min || uint128(delta.amount1()) < amount1Min) {
            revert TooMuchSlippage();
        }

        // Clean up position storage
        _cancelLinkedOrders(positionId);
        uint256[] storage userPos = _userPositions[pos.owner];
        for (uint256 i; i < userPos.length; i++) {
            if (userPos[i] == positionId) {
                userPos[i] = userPos[userPos.length - 1];
                userPos.pop();
                break;
            }
        }
        delete positions[positionId];
        emit PositionClosed(positionId, msg.sender);

        return delta;
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
        // M-4: Pool key validation
        PoolKey memory stored = poolKey();
        if (
            Currency.unwrap(key.currency0) != Currency.unwrap(stored.currency0)
                || Currency.unwrap(key.currency1) != Currency.unwrap(stored.currency1)
                || key.fee != stored.fee || key.tickSpacing != stored.tickSpacing
                || address(key.hooks) != address(stored.hooks)
        ) revert InvalidPoolKey();

        // Validate linkedPositionId references an existing position (if non-zero)
        if (linkedPositionId != 0 && positions[linkedPositionId].owner == address(0)) {
            revert PositionNotFound();
        }

        // Escrow the input tokens via unlock callback:
        // 1. settle: transfer ERC-20 from user to PoolManager (creates negative delta on hook)
        // 2. take as claims: mint ERC-6909 to hook (creates positive delta on hook, netting to zero)
        // This leaves the hook holding ERC-6909 claims that can later be burned on cancel/claim.
        Currency inputCurrency = zeroForOne ? key.currency0 : key.currency1;
        poolManager.unlock(abi.encode(
            address(0), // sentinel for custom callback
            CallbackType.PLACE_ORDER,
            abi.encode(PlaceOrderCallbackData({
                currency: inputCurrency,
                amount: uint256(amountIn),
                payer: msg.sender
            }))
        ));

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
            cancelled: false,
            claimCurrency: Currency.wrap(address(0)),
            claimAmount: 0
        });

        bytes32 id = PoolId.unwrap(key.toId());
        _poolLimitOrders[id].push(orderId);
        _userLimitOrders[msg.sender].push(orderId);

        emit LimitOrderPlaced(orderId, msg.sender, triggerTick, zeroForOne);
    }

    // C-3 fix: Proper token return via unlock
    function cancelLimitOrder(uint256 orderId) external {
        LimitOrder storage order = limitOrders[orderId];
        if (order.owner != msg.sender) revert NotOrderOwner();
        if (order.executed) revert OrderAlreadyExecuted();
        if (order.cancelled) revert OrderAlreadyCancelled();

        order.cancelled = true;

        Currency inputCurrency = order.zeroForOne ? poolKey().currency0 : poolKey().currency1;

        poolManager.unlock(abi.encode(
            address(0), // sentinel for custom callback
            CallbackType.CANCEL_ORDER,
            abi.encode(CancelOrderCallbackData({
                currency: inputCurrency,
                amount: uint256(order.amountIn),
                to: msg.sender
            }))
        ));

        // M-2 fix: Remove orderId from _userLimitOrders (swap-and-pop)
        _removeUserLimitOrder(msg.sender, orderId);

        emit LimitOrderCancelled(orderId);
    }

    // C-3 fix: Claim filled orders
    function claimFilledOrder(uint256 orderId) external {
        LimitOrder storage order = limitOrders[orderId];
        if (order.owner != msg.sender) revert NotOrderOwner();
        if (!order.executed) revert OrderNotExecuted();
        if (order.claimAmount == 0) revert AlreadyClaimed();

        uint128 amount = order.claimAmount;
        Currency currency = order.claimCurrency;
        order.claimAmount = 0;

        poolManager.unlock(abi.encode(
            address(0), // sentinel for custom callback
            CallbackType.CLAIM_ORDER,
            abi.encode(ClaimCallbackData({
                currency: currency,
                amount: uint256(amount),
                to: msg.sender
            }))
        ));

        // M-2 fix: Remove orderId from _userLimitOrders (swap-and-pop)
        _removeUserLimitOrder(msg.sender, orderId);

        emit LimitOrderClaimed(orderId, msg.sender, amount);
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
    // H-2 fix: Reentrancy guard prevents recursive execution during nested swaps
    // H-3 fix: try-catch prevents single malicious order from DOSing all swaps
    function _checkLimitOrders(PoolKey calldata key, bytes32 poolId, int24 currentTick) internal {
        // H-2: Skip if already executing orders (nested swap from limit order execution)
        if (_executingOrders) return;
        _executingOrders = true;

        uint256[] storage orderIds = _poolLimitOrders[poolId];
        uint256 executed;
        uint256 i;

        while (i < orderIds.length && executed < MAX_ORDERS_PER_SWAP) {
            LimitOrder storage order = limitOrders[orderIds[i]];

            // Remove completed/cancelled orders (swap-and-pop)
            if (order.executed || order.cancelled) {
                orderIds[i] = orderIds[orderIds.length - 1];
                orderIds.pop();
                continue;
            }

            if (_shouldExecuteOrder(order, currentTick)) {
                // H-3: Wrap execution in try-catch so one bad order cannot DOS all swaps
                try this.executeOrderExternal(key, orderIds[i]) {
                    // success
                } catch (bytes memory reason) {
                    // Mark the order as cancelled so it is cleaned up on next pass
                    order.cancelled = true;
                    emit LimitOrderExecutionFailed(orderIds[i], reason);
                }
                executed++;
            }
            i++;
        }

        _executingOrders = false;
    }

    /// @notice External entry point for try-catch on limit order execution.
    /// Only callable by this contract itself. Must be external for try-catch to work.
    function executeOrderExternal(PoolKey calldata key, uint256 orderId) external {
        if (msg.sender != address(this)) revert NotPositionOwner();
        LimitOrder storage order = limitOrders[orderId];
        _executeLimitOrder(key, orderId, order);
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

    // Execute limit order by performing an actual swap through the PoolManager.
    // Burns escrowed input ERC-6909 claims, swaps via the pool, and mints output
    // ERC-6909 claims for the order owner to later withdraw via claimFilledOrder.
    function _executeLimitOrder(PoolKey calldata key, uint256 orderId, LimitOrder storage order) internal {
        Currency inputCurrency = order.zeroForOne ? key.currency0 : key.currency1;
        Currency outputCurrency = order.zeroForOne ? key.currency1 : key.currency0;

        // 1. Burn the escrowed input ERC-6909 claims (creates a negative/debit delta on the hook)
        inputCurrency.settle(poolManager, address(this), uint256(order.amountIn), true);

        // 2. Perform a swap using the escrowed amount as exact-input
        BalanceDelta swapDelta = poolManager.swap(
            key,
            SwapParams({
                zeroForOne: order.zeroForOne,
                amountSpecified: -int256(uint256(order.amountIn)), // negative = exact-input
                sqrtPriceLimitX96: order.zeroForOne
                    ? TickMath.MIN_SQRT_PRICE + 1
                    : TickMath.MAX_SQRT_PRICE - 1
            }),
            ""
        );

        // 3. Calculate the output amount from the swap delta
        int128 rawOutput = order.zeroForOne ? swapDelta.amount1() : swapDelta.amount0();
        // For exact-input swaps, the output side is positive (tokens owed to the swapper)
        uint128 amountOut = rawOutput > 0 ? uint128(rawOutput) : uint128(-rawOutput);

        // 4. Enforce minimum output (slippage protection)
        if (amountOut < order.amountOutMin) revert InsufficientAmountOut();

        // 5. Mint output ERC-6909 claims to the hook for later withdrawal
        outputCurrency.take(poolManager, address(this), uint256(amountOut), true);

        // 6. Record the claimable output for the order owner
        order.executed = true;
        order.claimCurrency = outputCurrency;
        order.claimAmount = amountOut;

        // M-3 fix: Report order execution to oracle for off-chain indexing
        if (address(oracle) != address(0)) {
            bytes32 id = PoolId.unwrap(key.toId());
            oracle.reportOrderExecution(id, orderId);
        }

        emit LimitOrderExecuted(orderId, amountOut);
    }

    // ─── Internal: Rebalancing (detection only) ────────────────────────
    function _checkRebalancing(PoolKey calldata key, bytes32 poolId, int24 currentTick) internal {
        RebalanceSignal[] memory signals = oracle.getPositionsNeedingRebalance(poolId);

        for (uint256 i; i < signals.length && i < MAX_REBALANCES_PER_SWAP; i++) {
            if (signals[i].confidence >= minConfidence) {
                Position storage pos = positions[signals[i].positionId];
                if (pos.owner == address(0)) continue;
                if (!pos.autoRebalance) continue;

                if (_needsRebalancing(currentTick, pos.tickLower, pos.tickUpper)) {
                    // C-2: Emit event for bot to call rebalancePosition
                    int24 snappedLower = _snapToTickSpacing(signals[i].newTickLower, key.tickSpacing);
                    int24 snappedUpper = _snapToTickSpacing(signals[i].newTickUpper, key.tickSpacing);
                    emit RebalanceRequested(signals[i].positionId, snappedLower, snappedUpper);
                }
            }
        }
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

    // ─── Internal: Unlock Callback Handlers ────────────────────────────
    function _handleRebalanceCallback(bytes memory data) internal returns (bytes memory) {
        RebalanceCallbackData memory cb = abi.decode(data, (RebalanceCallbackData));
        PoolKey memory key_ = poolKey();

        // Remove all liquidity from old range
        (BalanceDelta removeDelta,) = poolManager.modifyLiquidity(
            key_,
            ModifyLiquidityParams({
                tickLower: cb.oldTickLower,
                tickUpper: cb.oldTickUpper,
                liquidityDelta: -int256(uint256(cb.liquidity)),
                salt: cb.positionSalt
            }),
            ""
        );

        // Compute new liquidity in scoped block to reduce stack depth
        uint128 newLiquidity;
        {
            uint256 amount0Available = removeDelta.amount0() > 0 ? uint256(int256(removeDelta.amount0())) : 0;
            uint256 amount1Available = removeDelta.amount1() > 0 ? uint256(int256(removeDelta.amount1())) : 0;

            (uint160 sqrtPriceX96,,,) = poolManager.getSlot0(key_.toId());

            newLiquidity = LiquidityAmounts.getLiquidityForAmounts(
                sqrtPriceX96,
                TickMath.getSqrtPriceAtTick(cb.newTickLower),
                TickMath.getSqrtPriceAtTick(cb.newTickUpper),
                amount0Available,
                amount1Available
            );
        }

        // Add liquidity to new range (may be less than original if range is wider)
        BalanceDelta addDelta;
        {
            (BalanceDelta addDelta_,) = poolManager.modifyLiquidity(
                key_,
                ModifyLiquidityParams({
                    tickLower: cb.newTickLower,
                    tickUpper: cb.newTickUpper,
                    liquidityDelta: int256(uint256(newLiquidity)),
                    salt: cb.positionSalt
                }),
                ""
            );
            addDelta = addDelta_;
        }

        // Settle net deltas and track surplus
        _settleRebalanceDeltas(key_, cb.positionId, removeDelta, addDelta);

        // Update the position's liquidity to the new amount
        positions[cb.positionId].liquidity = newLiquidity;

        return "";
    }

    /// @dev Extracted to reduce stack depth in _handleRebalanceCallback
    function _settleRebalanceDeltas(
        PoolKey memory key_,
        uint256 positionId,
        BalanceDelta removeDelta,
        BalanceDelta addDelta
    ) internal {
        int128 net0 = removeDelta.amount0() + addDelta.amount0();
        int128 net1 = removeDelta.amount1() + addDelta.amount1();

        // H-4 fix: Track surplus per position so the owner can claim it later
        if (net0 > 0) {
            uint256 surplus0 = uint256(uint128(net0));
            key_.currency0.take(poolManager, address(this), surplus0, true);
            rebalanceSurplus[positionId][key_.currency0] += surplus0;
        }
        if (net1 > 0) {
            uint256 surplus1 = uint256(uint128(net1));
            key_.currency1.take(poolManager, address(this), surplus1, true);
            rebalanceSurplus[positionId][key_.currency1] += surplus1;
        }
        // Deficit should not happen, but handle defensively
        if (net0 < 0) key_.currency0.settle(poolManager, address(this), uint256(uint128(-net0)), true);
        if (net1 < 0) key_.currency1.settle(poolManager, address(this), uint256(uint128(-net1)), true);
    }

    function _handleClaimCallback(bytes memory data) internal returns (bytes memory) {
        ClaimCallbackData memory cb = abi.decode(data, (ClaimCallbackData));
        // Burn hook's ERC-6909 claims and send actual tokens to user
        cb.currency.settle(poolManager, address(this), cb.amount, true);  // burn claims
        cb.currency.take(poolManager, cb.to, cb.amount, false);           // send ERC-20
        return "";
    }

    function _handleCancelCallback(bytes memory data) internal returns (bytes memory) {
        CancelOrderCallbackData memory cb = abi.decode(data, (CancelOrderCallbackData));
        // Burn hook's ERC-6909 claims and send actual tokens to user
        cb.currency.settle(poolManager, address(this), cb.amount, true);  // burn claims
        cb.currency.take(poolManager, cb.to, cb.amount, false);           // send ERC-20
        return "";
    }

    function _handlePlaceOrderCallback(bytes memory data) internal returns (bytes memory) {
        PlaceOrderCallbackData memory cb = abi.decode(data, (PlaceOrderCallbackData));
        // Transfer ERC-20 from user to PoolManager (creates a credit/positive delta on the hook)
        cb.currency.settle(poolManager, cb.payer, cb.amount, false);
        // Mint ERC-6909 claims to the hook (consumes the credit, netting delta to zero)
        cb.currency.take(poolManager, address(this), cb.amount, true);
        return "";
    }

    /// @dev H-1 fix: Bulk cancel callback returns multiple escrowed token types in a single unlock
    function _handleBulkCancelCallback(bytes memory data) internal returns (bytes memory) {
        BulkCancelOrdersCallbackData memory cb = abi.decode(data, (BulkCancelOrdersCallbackData));
        for (uint256 i; i < cb.currencies.length; i++) {
            // Burn hook's ERC-6909 claims and send actual tokens to user
            cb.currencies[i].settle(poolManager, address(this), cb.amounts[i], true);  // burn claims
            cb.currencies[i].take(poolManager, cb.to, cb.amounts[i], false);           // send ERC-20
        }
        return "";
    }

    /// @dev H-4 fix: Claim surplus callback burns ERC-6909 claims and sends tokens to user
    function _handleClaimSurplusCallback(bytes memory data) internal returns (bytes memory) {
        ClaimSurplusCallbackData memory cb = abi.decode(data, (ClaimSurplusCallbackData));
        cb.currency.settle(poolManager, address(this), cb.amount, true);  // burn claims
        cb.currency.take(poolManager, cb.to, cb.amount, false);           // send ERC-20
        return "";
    }

    function _handleRemovePositionCallback(bytes memory data) internal returns (bytes memory) {
        RemovePositionCallbackData memory cb = abi.decode(data, (RemovePositionCallbackData));
        PoolKey memory key_ = poolKey();

        // Remove liquidity from the pool.
        // callerDelta already includes both principal and accrued fees.
        (BalanceDelta callerDelta,) = poolManager.modifyLiquidity(
            key_,
            ModifyLiquidityParams({
                tickLower: cb.tickLower,
                tickUpper: cb.tickUpper,
                liquidityDelta: -int256(uint256(cb.liquidity)),
                salt: cb.positionSalt
            }),
            ""
        );

        // Send all tokens (principal + fees) to position owner in a single transfer per currency
        if (callerDelta.amount0() > 0) {
            key_.currency0.take(poolManager, cb.owner, uint256(int256(callerDelta.amount0())), false);
        }
        if (callerDelta.amount1() > 0) {
            key_.currency1.take(poolManager, cb.owner, uint256(int256(callerDelta.amount1())), false);
        }

        return abi.encode(callerDelta);
    }

    // ─── H-4 fix: Claim rebalance surplus ──────────────────────────────
    function claimRebalanceSurplus(uint256 positionId, Currency currency) external {
        Position storage pos = positions[positionId];
        if (pos.owner != msg.sender) revert NotPositionOwner();

        uint256 amount = rebalanceSurplus[positionId][currency];
        if (amount == 0) revert NoSurplusToClaim();

        rebalanceSurplus[positionId][currency] = 0;

        poolManager.unlock(abi.encode(
            address(0),
            CallbackType.CLAIM_SURPLUS,
            abi.encode(ClaimSurplusCallbackData({
                currency: currency,
                amount: amount,
                to: msg.sender
            }))
        ));

        emit SurplusClaimed(positionId, msg.sender, currency, amount);
    }

    // ─── Internal: Helpers ─────────────────────────────────────────────

    /// @dev H-1 fix: Cancel linked orders AND return escrowed tokens to the user
    function _cancelLinkedOrders(uint256 positionId) internal {
        address owner_ = positions[positionId].owner;
        if (owner_ == address(0)) return;

        uint256[] storage userOrders = _userLimitOrders[owner_];
        PoolKey memory key_ = poolKey();

        // Collect all amounts to return in a single unlock
        Currency[] memory currencies = new Currency[](userOrders.length);
        uint256[] memory amounts = new uint256[](userOrders.length);
        uint256 count;

        // Iterate backwards to safely remove via swap-and-pop
        uint256 i = userOrders.length;
        while (i > 0) {
            i--;
            LimitOrder storage order = limitOrders[userOrders[i]];
            if (order.linkedPositionId == positionId && !order.executed && !order.cancelled) {
                order.cancelled = true;

                Currency inputCurrency = order.zeroForOne ? key_.currency0 : key_.currency1;
                currencies[count] = inputCurrency;
                amounts[count] = uint256(order.amountIn);
                count++;

                emit LimitOrderCancelled(userOrders[i]);

                // M-2 fix: Remove from user array (swap-and-pop)
                userOrders[i] = userOrders[userOrders.length - 1];
                userOrders.pop();
            }
        }

        // Perform bulk token return via single unlock callback
        if (count > 0) {
            // Trim arrays to actual count
            Currency[] memory trimmedCurrencies = new Currency[](count);
            uint256[] memory trimmedAmounts = new uint256[](count);
            for (uint256 j; j < count; j++) {
                trimmedCurrencies[j] = currencies[j];
                trimmedAmounts[j] = amounts[j];
            }

            poolManager.unlock(abi.encode(
                address(0),
                CallbackType.BULK_CANCEL_ORDERS,
                abi.encode(BulkCancelOrdersCallbackData({
                    currencies: trimmedCurrencies,
                    amounts: trimmedAmounts,
                    to: owner_
                }))
            ));
        }
    }

    /// @dev M-2 fix: Remove an orderId from a user's limit order array using swap-and-pop
    function _removeUserLimitOrder(address user_, uint256 orderId) internal {
        uint256[] storage userOrders = _userLimitOrders[user_];
        for (uint256 i; i < userOrders.length; i++) {
            if (userOrders[i] == orderId) {
                userOrders[i] = userOrders[userOrders.length - 1];
                userOrders.pop();
                return;
            }
        }
    }
}
