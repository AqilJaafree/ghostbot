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
import {IOpenClawOracle} from "../src/interfaces/IOpenClawOracle.sol";
import {Position, PoolStats} from "../src/types/DataTypes.sol";

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

    function test_setMinConfidence() public {
        hook.setMinConfidence(80);
        assertEq(hook.minConfidence(), 80);
    }
}
