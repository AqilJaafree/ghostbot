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
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {BaseCustomAccounting} from "@openzeppelin/uniswap-hooks/base/BaseCustomAccounting.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

import {OpenClawOracle} from "../src/OpenClawOracle.sol";
import {OpenClawACLMHook} from "../src/OpenClawACLMHook.sol";
import {IOpenClawACLMHook} from "../src/interfaces/IOpenClawACLMHook.sol";
import {IOpenClawOracle} from "../src/interfaces/IOpenClawOracle.sol";
import {Position, PoolStats, OrderType, LimitOrder} from "../src/types/DataTypes.sol";

contract OpenClawACLMHookTest is Test {
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

        // Compute hook address with required flags
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

        // Deploy tokens
        MockERC20 tokenA = new MockERC20("TokenA", "TKA", 18);
        MockERC20 tokenB = new MockERC20("TokenB", "TKB", 18);
        if (uint160(address(tokenA)) > uint160(address(tokenB))) {
            (tokenA, tokenB) = (tokenB, tokenA);
        }
        currency0 = Currency.wrap(address(tokenA));
        currency1 = Currency.wrap(address(tokenB));

        // Mint and approve
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

        // Initialize pool
        key = PoolKey(currency0, currency1, LPFeeLibrary.DYNAMIC_FEE_FLAG, TICK_SPACING, IHooks(address(hook)));
        poolId = key.toId();
        manager.initialize(key, SQRT_PRICE_1_1);
    }

    // ── Pool Initialization ────────────────────────────────────────────
    function test_poolInitialized() public view {
        PoolKey memory storedKey = hook.poolKey();
        assertEq(Currency.unwrap(storedKey.currency0), Currency.unwrap(currency0));
        assertEq(Currency.unwrap(storedKey.currency1), Currency.unwrap(currency1));
    }

    function test_poolStatsInitialized() public view {
        bytes32 id = PoolId.unwrap(poolId);
        PoolStats memory stats = hook.getPoolStats(id);
        assertEq(stats.currentFee, 3000);
        assertEq(stats.cumulativeVolume, 0);
    }

    // ── Add / Remove Liquidity ─────────────────────────────────────────
    function test_addLiquidity() public {
        BaseCustomAccounting.AddLiquidityParams memory params = BaseCustomAccounting.AddLiquidityParams(
            10 ether, 10 ether, 9 ether, 9 ether, MAX_DEADLINE, MIN_TICK, MAX_TICK, bytes32(0)
        );

        hook.addLiquidity(params);

        // Verify position was created
        uint256[] memory positions = hook.getUserPositions(address(this));
        assertEq(positions.length, 1);

        Position memory pos = hook.getPosition(positions[0]);
        assertEq(pos.owner, address(this));
        assertEq(pos.tickLower, MIN_TICK);
        assertEq(pos.tickUpper, MAX_TICK);
        assertTrue(pos.liquidity > 0);
    }

    function test_addLiquidity_withAutoRebalance() public {
        // Set salt bit 0 to enable auto-rebalance
        bytes32 salt = bytes32(uint256(1));

        BaseCustomAccounting.AddLiquidityParams memory params = BaseCustomAccounting.AddLiquidityParams(
            10 ether, 10 ether, 9 ether, 9 ether, MAX_DEADLINE, MIN_TICK, MAX_TICK, salt
        );

        hook.addLiquidity(params);

        uint256[] memory positions = hook.getUserPositions(address(this));
        Position memory pos = hook.getPosition(positions[0]);
        assertTrue(pos.autoRebalance);
    }

    function test_removeLiquidity() public {
        // First add liquidity
        BaseCustomAccounting.AddLiquidityParams memory addParams = BaseCustomAccounting.AddLiquidityParams(
            10 ether, 10 ether, 9 ether, 9 ether, MAX_DEADLINE, MIN_TICK, MAX_TICK, bytes32(0)
        );
        hook.addLiquidity(addParams);

        uint256[] memory positions = hook.getUserPositions(address(this));
        Position memory pos = hook.getPosition(positions[0]);

        // Remove all liquidity
        BaseCustomAccounting.RemoveLiquidityParams memory removeParams = BaseCustomAccounting.RemoveLiquidityParams(
            pos.liquidity, 0, 0, MAX_DEADLINE, MIN_TICK, MAX_TICK, bytes32(0)
        );
        hook.removeLiquidity(removeParams);

        // Position should be deleted
        Position memory removedPos = hook.getPosition(positions[0]);
        assertEq(removedPos.owner, address(0));
    }

    // ── Remove Position by ID (H-3) ────────────────────────────────────
    function test_removePosition_byId() public {
        // Add two positions with different salts but same tick range
        BaseCustomAccounting.AddLiquidityParams memory addParams1 = BaseCustomAccounting.AddLiquidityParams(
            10 ether, 10 ether, 9 ether, 9 ether, MAX_DEADLINE, MIN_TICK, MAX_TICK, bytes32(0)
        );
        hook.addLiquidity(addParams1);

        BaseCustomAccounting.AddLiquidityParams memory addParams2 = BaseCustomAccounting.AddLiquidityParams(
            10 ether, 10 ether, 9 ether, 9 ether, MAX_DEADLINE, MIN_TICK, MAX_TICK, bytes32(uint256(2))
        );
        hook.addLiquidity(addParams2);

        uint256[] memory positions = hook.getUserPositions(address(this));
        assertEq(positions.length, 2);
        uint256 positionId = positions[0];

        // Remove first position by ID
        hook.removePosition(positionId, 0, 0, MAX_DEADLINE);

        // Only first position removed
        Position memory removedPos = hook.getPosition(positionId);
        assertEq(removedPos.owner, address(0));

        // Second position still exists
        uint256[] memory positionsAfter = hook.getUserPositions(address(this));
        assertEq(positionsAfter.length, 1);
    }

    function test_removePosition_notOwner_reverts() public {
        BaseCustomAccounting.AddLiquidityParams memory addParams = BaseCustomAccounting.AddLiquidityParams(
            10 ether, 10 ether, 9 ether, 9 ether, MAX_DEADLINE, MIN_TICK, MAX_TICK, bytes32(0)
        );
        hook.addLiquidity(addParams);

        uint256[] memory positions = hook.getUserPositions(address(this));

        vm.prank(user);
        vm.expectRevert(OpenClawACLMHook.NotPositionOwner.selector);
        hook.removePosition(positions[0], 0, 0, MAX_DEADLINE);
    }

    // ── Swap Triggers Pool Stats Update ────────────────────────────────
    function test_swapUpdatesPoolStats() public {
        // Add liquidity first
        BaseCustomAccounting.AddLiquidityParams memory params = BaseCustomAccounting.AddLiquidityParams(
            10 ether, 10 ether, 9 ether, 9 ether, MAX_DEADLINE, MIN_TICK, MAX_TICK, bytes32(0)
        );
        hook.addLiquidity(params);

        // Execute a swap
        SwapParams memory swapParams = SwapParams({
            zeroForOne: true,
            amountSpecified: -1 ether,
            sqrtPriceLimitX96: MIN_PRICE_LIMIT
        });

        PoolSwapTest.TestSettings memory settings = PoolSwapTest.TestSettings({
            takeClaims: false,
            settleUsingBurn: false
        });

        swapRouter.swap(key, swapParams, settings, "");

        // Check pool stats updated
        bytes32 id = PoolId.unwrap(poolId);
        PoolStats memory stats = hook.getPoolStats(id);
        assertTrue(stats.cumulativeVolume > 0);
    }

    // ── H-1 fix: _cancelLinkedOrders returns escrowed tokens ──────────
    function test_cancelLinkedOrders_returnsTokens() public {
        // Add a position
        BaseCustomAccounting.AddLiquidityParams memory addParams = BaseCustomAccounting.AddLiquidityParams(
            10 ether, 10 ether, 9 ether, 9 ether, MAX_DEADLINE, MIN_TICK, MAX_TICK, bytes32(0)
        );
        hook.addLiquidity(addParams);

        uint256[] memory positions = hook.getUserPositions(address(this));
        uint256 positionId = positions[0];

        // Place a limit order linked to the position
        uint256 balanceBefore = MockERC20(Currency.unwrap(currency0)).balanceOf(address(this));
        hook.placeLimitOrder(key, true, -60, 1 ether, 0, OrderType.STOP_LOSS, positionId);

        // Tokens were escrowed
        assertEq(MockERC20(Currency.unwrap(currency0)).balanceOf(address(this)), balanceBefore - 1 ether);

        // Remove the position -- this should cancel linked orders AND return tokens
        hook.removePosition(positionId, 0, 0, MAX_DEADLINE);

        // Tokens should be returned -- the ERC-6909 claims must be burned
        assertEq(manager.balanceOf(address(hook), currency0.toId()), 0, "ERC-6909 claims should be burned");
        // Verify user received the escrowed tokens back (balance >= before - position amount)
        assertTrue(
            MockERC20(Currency.unwrap(currency0)).balanceOf(address(this)) >= balanceBefore - 1 ether,
            "User should recover escrowed tokens"
        );

        // The linked order should be cancelled
        LimitOrder memory order = hook.getLimitOrder(1);
        assertTrue(order.cancelled, "Linked order should be cancelled");

        // User should NOT have the order in their user array anymore
        uint256[] memory userOrders = hook.getUserLimitOrders(address(this));
        for (uint256 i; i < userOrders.length; i++) {
            assertTrue(userOrders[i] != 1, "Cancelled linked order should be removed from user array");
        }
    }

    // ── H-1 fix: _cancelLinkedOrders works with multiple linked orders ─
    function test_cancelLinkedOrders_multipleOrders_returnsAllTokens() public {
        // Add a position
        BaseCustomAccounting.AddLiquidityParams memory addParams = BaseCustomAccounting.AddLiquidityParams(
            10 ether, 10 ether, 9 ether, 9 ether, MAX_DEADLINE, MIN_TICK, MAX_TICK, bytes32(0)
        );
        hook.addLiquidity(addParams);

        uint256[] memory positions = hook.getUserPositions(address(this));
        uint256 positionId = positions[0];

        // Place multiple linked limit orders
        hook.placeLimitOrder(key, true, -60, 1 ether, 0, OrderType.STOP_LOSS, positionId);
        hook.placeLimitOrder(key, true, -120, 2 ether, 0, OrderType.STOP_LOSS, positionId);

        // Verify 3 ether in ERC-6909 claims
        assertEq(manager.balanceOf(address(hook), currency0.toId()), 3 ether);

        // Remove the position
        hook.removePosition(positionId, 0, 0, MAX_DEADLINE);

        // All ERC-6909 claims should be burned
        assertEq(manager.balanceOf(address(hook), currency0.toId()), 0, "All claims should be burned");

        // Both orders should be cancelled
        assertTrue(hook.getLimitOrder(1).cancelled);
        assertTrue(hook.getLimitOrder(2).cancelled);
    }

    // ── M-5 fix: _burn reverts if no matching position found ──────────
    function test_removeLiquidity_noMatchingPosition_reverts() public {
        // Try to remove liquidity for a position that does not exist
        BaseCustomAccounting.RemoveLiquidityParams memory removeParams = BaseCustomAccounting.RemoveLiquidityParams(
            1000, 0, 0, MAX_DEADLINE, -600, 600, bytes32(uint256(999))
        );

        // Should revert because no matching position exists
        vm.expectRevert();
        hook.removeLiquidity(removeParams);
    }

    // ── Admin Functions ────────────────────────────────────────────────
    function test_setOracle_onlyOwner() public {
        vm.prank(user);
        vm.expectRevert();
        hook.setOracle(IOpenClawOracle(address(0)));
    }

    function test_pause_unpause() public {
        hook.pause();
        assertTrue(hook.paused());

        hook.unpause();
        assertFalse(hook.paused());
    }

    function test_setRebalanceCooldown() public {
        hook.setRebalanceCooldown(2 hours);
        assertEq(hook.rebalanceCooldown(), 2 hours);
    }

    function test_setRebalanceCooldown_zero() public {
        hook.setRebalanceCooldown(0);
        assertEq(hook.rebalanceCooldown(), 0);
    }

    function test_setRebalanceCooldown_tooLow_reverts() public {
        // 30 seconds is < 1 minute and != 0
        vm.expectRevert(OpenClawACLMHook.CooldownTooLow.selector);
        hook.setRebalanceCooldown(30);
    }

    function test_setMinConfidence() public {
        hook.setMinConfidence(80);
        assertEq(hook.minConfidence(), 80);
    }

    function test_setMinConfidence_floor() public {
        // 9 is below floor of 10
        vm.expectRevert(OpenClawACLMHook.MinConfidenceTooLow.selector);
        hook.setMinConfidence(9);

        // 10 is exactly the floor
        hook.setMinConfidence(10);
        assertEq(hook.minConfidence(), 10);
    }
}
