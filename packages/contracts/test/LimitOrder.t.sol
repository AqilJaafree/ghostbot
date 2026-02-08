// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolManager} from "@uniswap/v4-core/src/PoolManager.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {BaseCustomAccounting} from "@openzeppelin/uniswap-hooks/base/BaseCustomAccounting.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

import {OpenClawOracle} from "../src/OpenClawOracle.sol";
import {OpenClawACLMHook} from "../src/OpenClawACLMHook.sol";
import {IOpenClawACLMHook} from "../src/interfaces/IOpenClawACLMHook.sol";
import {IOpenClawOracle} from "../src/interfaces/IOpenClawOracle.sol";
import {LimitOrder, OrderType} from "../src/types/DataTypes.sol";

contract LimitOrderTest is Test {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    uint160 constant SQRT_PRICE_1_1 = 79228162514264337593543950336;
    uint160 constant MIN_PRICE_LIMIT = TickMath.MIN_SQRT_PRICE + 1;
    uint160 constant MAX_PRICE_LIMIT = TickMath.MAX_SQRT_PRICE - 1;
    uint256 constant MAX_DEADLINE = 12329839823;
    int24 constant TICK_SPACING = 60;
    int24 constant MIN_TICK = -887220;
    int24 constant MAX_TICK = 887220;

    IPoolManager manager;
    PoolSwapTest swapRouter;
    OpenClawOracle oracle;
    OpenClawACLMHook hook;

    MockERC20 tokenA;
    MockERC20 tokenB;
    Currency currency0;
    Currency currency1;
    PoolKey key;
    PoolId poolId;

    address owner = address(this);
    address bot = makeAddr("bot");
    address user = makeAddr("user");

    function setUp() public {
        vm.warp(1000);

        manager = new PoolManager(address(this));
        swapRouter = new PoolSwapTest(manager);

        oracle = new OpenClawOracle(owner);
        oracle.setBot(bot);

        address hookAddr = address(
            uint160(
                Hooks.BEFORE_INITIALIZE_FLAG | Hooks.AFTER_INITIALIZE_FLAG
                    | Hooks.BEFORE_ADD_LIQUIDITY_FLAG | Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG
                    | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG
            )
        );

        deployCodeTo(
            "OpenClawACLMHook.sol:OpenClawACLMHook",
            abi.encode(address(manager), owner),
            hookAddr
        );
        hook = OpenClawACLMHook(hookAddr);
        hook.setOracle(IOpenClawOracle(address(oracle)));
        oracle.setHook(hookAddr);

        tokenA = new MockERC20("TokenA", "TKA", 18);
        tokenB = new MockERC20("TokenB", "TKB", 18);
        if (uint160(address(tokenA)) > uint160(address(tokenB))) {
            (tokenA, tokenB) = (tokenB, tokenA);
        }
        currency0 = Currency.wrap(address(tokenA));
        currency1 = Currency.wrap(address(tokenB));

        tokenA.mint(address(this), 1000 ether);
        tokenB.mint(address(this), 1000 ether);
        tokenA.mint(user, 1000 ether);
        tokenB.mint(user, 1000 ether);

        tokenA.approve(address(swapRouter), type(uint256).max);
        tokenB.approve(address(swapRouter), type(uint256).max);
        tokenA.approve(address(hook), type(uint256).max);
        tokenB.approve(address(hook), type(uint256).max);

        vm.startPrank(user);
        tokenA.approve(address(swapRouter), type(uint256).max);
        tokenB.approve(address(swapRouter), type(uint256).max);
        tokenA.approve(address(hook), type(uint256).max);
        tokenB.approve(address(hook), type(uint256).max);
        vm.stopPrank();

        key = PoolKey(currency0, currency1, LPFeeLibrary.DYNAMIC_FEE_FLAG, TICK_SPACING, IHooks(address(hook)));
        poolId = key.toId();
        manager.initialize(key, SQRT_PRICE_1_1);

        // Add liquidity for swap execution
        BaseCustomAccounting.AddLiquidityParams memory liqParams = BaseCustomAccounting.AddLiquidityParams(
            100 ether, 100 ether, 90 ether, 90 ether, MAX_DEADLINE, MIN_TICK, MAX_TICK, bytes32(0)
        );
        hook.addLiquidity(liqParams);
    }

    // ── M-4: Pool key validation ────────────────────────────────────────
    function test_placeLimitOrder_invalidPoolKey_reverts() public {
        // Create a wrong pool key (different fee)
        PoolKey memory wrongKey = PoolKey(
            currency0,
            currency1,
            500, // Wrong fee (not DYNAMIC_FEE_FLAG)
            TICK_SPACING,
            IHooks(address(hook))
        );

        vm.expectRevert(OpenClawACLMHook.InvalidPoolKey.selector);
        hook.placeLimitOrder(wrongKey, true, -60, 1 ether, 0, OrderType.STOP_LOSS, 0);
    }

    // ── Place limit order succeeds and escrows tokens as ERC-6909 claims ─
    function test_placeLimitOrder_escrowsTokens() public {
        uint256 balanceBefore = tokenA.balanceOf(address(this));

        uint256 orderId = hook.placeLimitOrder(key, true, -60, 1 ether, 0, OrderType.STOP_LOSS, 0);

        // Verify order was created
        assertEq(orderId, 1);

        LimitOrder memory order = hook.getLimitOrder(orderId);
        assertEq(order.owner, address(this));
        assertTrue(order.zeroForOne);
        assertEq(order.triggerTick, -60);
        assertEq(order.amountIn, 1 ether);
        assertFalse(order.executed);
        assertFalse(order.cancelled);

        // Verify tokens were transferred from user
        uint256 balanceAfter = tokenA.balanceOf(address(this));
        assertEq(balanceBefore - balanceAfter, 1 ether);

        // Verify ERC-6909 claims were minted to the hook
        uint256 claimBalance = manager.balanceOf(address(hook), currency0.toId());
        assertEq(claimBalance, 1 ether);

        // Verify user limit orders tracking
        uint256[] memory userOrders = hook.getUserLimitOrders(address(this));
        assertEq(userOrders.length, 1);
        assertEq(userOrders[0], orderId);
    }

    // ── Place order as different user ────────────────────────────────────
    function test_placeLimitOrder_asUser() public {
        uint256 balanceBefore = tokenB.balanceOf(user);

        vm.prank(user);
        uint256 orderId = hook.placeLimitOrder(key, false, 60, 2 ether, 0, OrderType.TAKE_PROFIT, 0);

        assertEq(orderId, 1);

        LimitOrder memory order = hook.getLimitOrder(orderId);
        assertEq(order.owner, user);
        assertFalse(order.zeroForOne);
        assertEq(order.amountIn, 2 ether);

        // Verify tokens were transferred from user
        uint256 balanceAfter = tokenB.balanceOf(user);
        assertEq(balanceBefore - balanceAfter, 2 ether);

        // Verify ERC-6909 claims minted to hook
        uint256 claimBalance = manager.balanceOf(address(hook), currency1.toId());
        assertEq(claimBalance, 2 ether);
    }

    // ── Cancel order returns tokens via ERC-6909 burn ───────────────────
    function test_cancelLimitOrder_returnsTokens() public {
        uint256 balanceBefore = tokenA.balanceOf(address(this));

        uint256 orderId = hook.placeLimitOrder(key, true, -60, 1 ether, 0, OrderType.STOP_LOSS, 0);

        // Verify tokens were escrowed
        assertEq(tokenA.balanceOf(address(this)), balanceBefore - 1 ether);
        assertEq(manager.balanceOf(address(hook), currency0.toId()), 1 ether);

        // Cancel the order
        hook.cancelLimitOrder(orderId);

        // Verify tokens returned to user
        assertEq(tokenA.balanceOf(address(this)), balanceBefore);

        // Verify ERC-6909 claims were burned
        assertEq(manager.balanceOf(address(hook), currency0.toId()), 0);

        // Verify order is marked cancelled
        LimitOrder memory order = hook.getLimitOrder(orderId);
        assertTrue(order.cancelled);
    }

    // ── Cancel order access control ─────────────────────────────────────
    function test_cancelLimitOrder_notOwner_reverts() public {
        uint256 orderId = hook.placeLimitOrder(key, true, -60, 1 ether, 0, OrderType.STOP_LOSS, 0);

        vm.prank(user);
        vm.expectRevert(OpenClawACLMHook.NotOrderOwner.selector);
        hook.cancelLimitOrder(orderId);
    }

    function test_cancelLimitOrder_nonExistent_reverts() public {
        vm.prank(user);
        vm.expectRevert(OpenClawACLMHook.NotOrderOwner.selector);
        hook.cancelLimitOrder(999);
    }

    function test_cancelLimitOrder_alreadyCancelled_reverts() public {
        uint256 orderId = hook.placeLimitOrder(key, true, -60, 1 ether, 0, OrderType.STOP_LOSS, 0);
        hook.cancelLimitOrder(orderId);

        vm.expectRevert(OpenClawACLMHook.OrderAlreadyCancelled.selector);
        hook.cancelLimitOrder(orderId);
    }

    // ── Claim order access control ──────────────────────────────────────
    function test_claimFilledOrder_notOwner_reverts() public {
        vm.prank(user);
        vm.expectRevert(OpenClawACLMHook.NotOrderOwner.selector);
        hook.claimFilledOrder(999);
    }

    function test_claimFilledOrder_notExecuted_reverts() public {
        uint256 orderId = hook.placeLimitOrder(key, true, -60, 1 ether, 0, OrderType.STOP_LOSS, 0);

        vm.expectRevert(OpenClawACLMHook.OrderNotExecuted.selector);
        hook.claimFilledOrder(orderId);
    }

    // ── Limit order execution via swap triggers claim flow ──────────────
    function test_limitOrder_executedBySwap_thenClaimed() public {
        // Place a stop-loss order: sell token0 when price drops (tick <= -60)
        uint256 orderId = hook.placeLimitOrder(key, true, -60, 1 ether, 0, OrderType.STOP_LOSS, 0);

        // Verify ERC-6909 claims exist for the escrowed amount
        assertEq(manager.balanceOf(address(hook), currency0.toId()), 1 ether);

        // Swap to push price down past the trigger tick
        _doSwap(true, -10 ether);

        // Check that the order was executed with actual swap output
        LimitOrder memory order = hook.getLimitOrder(orderId);
        assertTrue(order.executed);
        // claimAmount is the real swap output (less than input due to fees + price impact)
        assertGt(order.claimAmount, 0);
        // Output currency should be token1 (we sold token0)
        assertEq(Currency.unwrap(order.claimCurrency), Currency.unwrap(currency1));
        uint128 expectedClaim = order.claimAmount;

        // Record balance before claim
        uint256 balanceBefore = MockERC20(Currency.unwrap(order.claimCurrency)).balanceOf(address(this));

        // Claim the filled order (burns ERC-6909 claims, sends ERC-20 to user)
        hook.claimFilledOrder(orderId);

        // Verify claim amount zeroed out
        LimitOrder memory orderAfter = hook.getLimitOrder(orderId);
        assertEq(orderAfter.claimAmount, 0);

        // Verify user received the swap output tokens
        uint256 balanceAfter = MockERC20(Currency.unwrap(order.claimCurrency)).balanceOf(address(this));
        assertEq(balanceAfter - balanceBefore, expectedClaim);

        // Verify ERC-6909 claims were burned
        assertEq(manager.balanceOf(address(hook), order.claimCurrency.toId()), 0);
    }

    function test_claimFilledOrder_alreadyClaimed_reverts() public {
        // Place and trigger execution
        uint256 orderId = hook.placeLimitOrder(key, true, -60, 1 ether, 0, OrderType.STOP_LOSS, 0);
        _doSwap(true, -10 ether);

        // First claim succeeds
        hook.claimFilledOrder(orderId);

        // Second claim reverts
        vm.expectRevert(OpenClawACLMHook.AlreadyClaimed.selector);
        hook.claimFilledOrder(orderId);
    }

    // ── Cancel already executed order reverts ────────────────────────────
    function test_cancelLimitOrder_alreadyExecuted_reverts() public {
        uint256 orderId = hook.placeLimitOrder(key, true, -60, 1 ether, 0, OrderType.STOP_LOSS, 0);
        _doSwap(true, -10 ether);

        vm.expectRevert(OpenClawACLMHook.OrderAlreadyExecuted.selector);
        hook.cancelLimitOrder(orderId);
    }

    // ── H-2: Order array cleanup during swap ────────────────────────────
    function test_limitOrderArray_cleanup() public {
        // Place two orders, cancel one, then swap to trigger cleanup
        uint256 orderId1 = hook.placeLimitOrder(key, true, -60, 1 ether, 0, OrderType.STOP_LOSS, 0);
        hook.placeLimitOrder(key, true, -120, 1 ether, 0, OrderType.STOP_LOSS, 0);

        // Cancel first order
        hook.cancelLimitOrder(orderId1);

        // Swap triggers _checkLimitOrders which cleans up cancelled orders via swap-and-pop
        _doSwap(true, -1 ether);

        // Verify the cancelled order is still marked cancelled (not erroneously re-processed)
        LimitOrder memory order1 = hook.getLimitOrder(orderId1);
        assertTrue(order1.cancelled);
    }

    // ── Multiple orders for same user ───────────────────────────────────
    function test_multipleOrders_placedAndTracked() public {
        hook.placeLimitOrder(key, true, -60, 1 ether, 0, OrderType.STOP_LOSS, 0);
        hook.placeLimitOrder(key, false, 60, 2 ether, 0, OrderType.TAKE_PROFIT, 0);
        hook.placeLimitOrder(key, true, -120, 0.5 ether, 0, OrderType.TRAILING_STOP, 0);

        uint256[] memory userOrders = hook.getUserLimitOrders(address(this));
        assertEq(userOrders.length, 3);

        // Verify total ERC-6909 claims
        assertEq(manager.balanceOf(address(hook), currency0.toId()), 1.5 ether);
        assertEq(manager.balanceOf(address(hook), currency1.toId()), 2 ether);
    }

    // ── Paused state prevents placing orders ────────────────────────────
    function test_placeLimitOrder_whenPaused_reverts() public {
        hook.pause();

        vm.expectRevert();
        hook.placeLimitOrder(key, true, -60, 1 ether, 0, OrderType.STOP_LOSS, 0);
    }

    // ── H-3 fix: Order with unrealistic amountOutMin does NOT DOS all swaps ──
    function test_unrealisticAmountOutMin_doesNotDosSwaps() public {
        // Place an order with impossibly high amountOutMin
        hook.placeLimitOrder(key, true, -60, 1 ether, type(uint128).max, OrderType.STOP_LOSS, 0);

        // Swap to push price past the trigger tick -- should NOT revert
        // The order execution should fail gracefully and be marked cancelled
        _doSwap(true, -10 ether);

        // Verify the order was marked cancelled (not executed) due to InsufficientAmountOut
        LimitOrder memory order = hook.getLimitOrder(1);
        assertTrue(order.cancelled, "Order should be cancelled after failed execution");
        assertFalse(order.executed, "Order should not be marked as executed");
    }

    // ── H-3 fix: Good orders still execute when a bad order fails ──
    function test_badOrder_doesNotAffectGoodOrders() public {
        // Place a bad order first (will trigger first since same tick)
        hook.placeLimitOrder(key, true, -60, 0.5 ether, type(uint128).max, OrderType.STOP_LOSS, 0);
        // Place a good order at same trigger
        hook.placeLimitOrder(key, true, -60, 0.5 ether, 0, OrderType.STOP_LOSS, 0);

        // Swap to trigger both orders
        _doSwap(true, -10 ether);

        // Bad order should be cancelled
        LimitOrder memory badOrder = hook.getLimitOrder(1);
        assertTrue(badOrder.cancelled, "Bad order should be cancelled");
        assertFalse(badOrder.executed, "Bad order should not be executed");

        // Good order should be executed
        LimitOrder memory goodOrder = hook.getLimitOrder(2);
        assertTrue(goodOrder.executed, "Good order should be executed");
        assertGt(goodOrder.claimAmount, 0, "Good order should have claim amount");
    }

    // ── H-2 fix: Reentrancy guard prevents recursive limit order execution ──
    function test_limitOrderExecution_noRecursiveExecution() public {
        // Place two orders at different ticks; the first order's swap might
        // push the price past the second order's trigger. The reentrancy guard
        // should prevent the second order from being executed recursively.
        hook.placeLimitOrder(key, true, -60, 5 ether, 0, OrderType.STOP_LOSS, 0);
        hook.placeLimitOrder(key, true, -120, 5 ether, 0, OrderType.STOP_LOSS, 0);

        // Swap to push price past -60 (first order triggers, its swap may push past -120)
        _doSwap(true, -10 ether);

        // First order should be executed
        LimitOrder memory order1 = hook.getLimitOrder(1);
        assertTrue(order1.executed, "First order should be executed");

        // Second order may or may not have been executed depending on the swap result,
        // but critically: the swap should NOT have reverted (no recursive infinite loop).
        // The key assertion is that the transaction succeeded.
    }

    // ── M-2 fix: _userLimitOrders cleaned up on cancel ──
    function test_cancelLimitOrder_removesFromUserArray() public {
        hook.placeLimitOrder(key, true, -60, 1 ether, 0, OrderType.STOP_LOSS, 0);
        hook.placeLimitOrder(key, true, -120, 1 ether, 0, OrderType.STOP_LOSS, 0);
        hook.placeLimitOrder(key, true, -180, 1 ether, 0, OrderType.STOP_LOSS, 0);

        // Should have 3 orders
        uint256[] memory ordersBefore = hook.getUserLimitOrders(address(this));
        assertEq(ordersBefore.length, 3);

        // Cancel middle order
        hook.cancelLimitOrder(2);

        // Should have 2 orders now
        uint256[] memory ordersAfter = hook.getUserLimitOrders(address(this));
        assertEq(ordersAfter.length, 2);

        // Verify orderId 2 is no longer in the array
        for (uint256 i; i < ordersAfter.length; i++) {
            assertTrue(ordersAfter[i] != 2, "Cancelled order should not be in user array");
        }
    }

    // ── M-2 fix: _userLimitOrders cleaned up on claim ──
    function test_claimFilledOrder_removesFromUserArray() public {
        hook.placeLimitOrder(key, true, -60, 1 ether, 0, OrderType.STOP_LOSS, 0);
        hook.placeLimitOrder(key, false, 60, 1 ether, 0, OrderType.TAKE_PROFIT, 0);

        uint256[] memory ordersBefore = hook.getUserLimitOrders(address(this));
        assertEq(ordersBefore.length, 2);

        // Trigger execution of order 1 (zeroForOne, triggerTick=-60)
        _doSwap(true, -10 ether);

        LimitOrder memory order = hook.getLimitOrder(1);
        assertTrue(order.executed);

        // Claim the executed order
        hook.claimFilledOrder(1);

        // User array should shrink by 1
        uint256[] memory ordersAfter = hook.getUserLimitOrders(address(this));
        assertEq(ordersAfter.length, 1);
        assertEq(ordersAfter[0], 2, "Remaining order should be orderId 2");
    }

    // ── M-3 fix: oracle.reportOrderExecution is called on execution ──
    function test_limitOrderExecution_reportsToOracle() public {
        hook.placeLimitOrder(key, true, -60, 1 ether, 0, OrderType.STOP_LOSS, 0);

        bytes32 id = PoolId.unwrap(poolId);

        // Expect the oracle event to be emitted
        vm.expectEmit(true, true, false, false);
        emit OpenClawOracle.OrderExecutionReported(id, 1);

        // Swap to trigger execution
        _doSwap(true, -10 ether);
    }

    function _doSwap(bool zeroForOne, int256 amount) internal {
        SwapParams memory params = SwapParams({
            zeroForOne: zeroForOne,
            amountSpecified: amount,
            sqrtPriceLimitX96: zeroForOne ? MIN_PRICE_LIMIT : MAX_PRICE_LIMIT
        });
        PoolSwapTest.TestSettings memory settings = PoolSwapTest.TestSettings({
            takeClaims: false,
            settleUsingBurn: false
        });
        swapRouter.swap(key, params, settings, "");
    }
}
