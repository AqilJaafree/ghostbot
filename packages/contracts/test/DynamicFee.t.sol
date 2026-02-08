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
import {IOpenClawOracle} from "../src/interfaces/IOpenClawOracle.sol";
import {IOpenClawACLMHook} from "../src/interfaces/IOpenClawACLMHook.sol";
import {FeeRecommendation, PoolStats} from "../src/types/DataTypes.sol";

contract DynamicFeeTest is Test {
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

        MockERC20 tokenA = new MockERC20("TokenA", "TKA", 18);
        MockERC20 tokenB = new MockERC20("TokenB", "TKB", 18);
        if (uint160(address(tokenA)) > uint160(address(tokenB))) {
            (tokenA, tokenB) = (tokenB, tokenA);
        }
        currency0 = Currency.wrap(address(tokenA));
        currency1 = Currency.wrap(address(tokenB));

        tokenA.mint(address(this), 1000 ether);
        tokenB.mint(address(this), 1000 ether);
        tokenA.approve(address(swapRouter), type(uint256).max);
        tokenB.approve(address(swapRouter), type(uint256).max);
        tokenA.approve(address(hook), type(uint256).max);
        tokenB.approve(address(hook), type(uint256).max);

        key = PoolKey(currency0, currency1, LPFeeLibrary.DYNAMIC_FEE_FLAG, TICK_SPACING, IHooks(address(hook)));
        poolId = key.toId();
        manager.initialize(key, SQRT_PRICE_1_1);

        // Add liquidity so we can swap
        BaseCustomAccounting.AddLiquidityParams memory params = BaseCustomAccounting.AddLiquidityParams(
            100 ether, 100 ether, 90 ether, 90 ether, MAX_DEADLINE, MIN_TICK, MAX_TICK, bytes32(0)
        );
        hook.addLiquidity(params);
    }

    function test_dynamicFee_noOracleRecommendation() public {
        // Swap without any fee recommendation
        _doSwap(true, -1 ether);

        bytes32 id = PoolId.unwrap(poolId);
        PoolStats memory stats = hook.getPoolStats(id);
        assertEq(stats.currentFee, 3000); // Unchanged from default
    }

    function test_dynamicFee_oracleRecommendation_applied() public {
        // Post a fee recommendation with >10% change (3000 -> 5000)
        FeeRecommendation memory rec = FeeRecommendation({
            fee: 5000,
            confidence: 90,
            timestamp: block.timestamp
        });
        vm.prank(bot);
        oracle.postFeeRecommendation(PoolId.unwrap(poolId), rec);

        // Swap triggers beforeSwap which reads the fee
        _doSwap(true, -1 ether);

        bytes32 id = PoolId.unwrap(poolId);
        PoolStats memory stats = hook.getPoolStats(id);
        assertEq(stats.currentFee, 5000);
    }

    function test_dynamicFee_smallChange_notApplied() public {
        // Post a fee recommendation with <10% change (3000 -> 3200)
        FeeRecommendation memory rec = FeeRecommendation({
            fee: 3200,
            confidence: 90,
            timestamp: block.timestamp
        });
        vm.prank(bot);
        oracle.postFeeRecommendation(PoolId.unwrap(poolId), rec);

        _doSwap(true, -1 ether);

        bytes32 id = PoolId.unwrap(poolId);
        PoolStats memory stats = hook.getPoolStats(id);
        assertEq(stats.currentFee, 3000); // Still default, change too small
    }

    function test_dynamicFee_lowConfidence_notApplied() public {
        // Post with low confidence
        FeeRecommendation memory rec = FeeRecommendation({
            fee: 5000,
            confidence: 50, // Below minConfidence (70)
            timestamp: block.timestamp
        });
        vm.prank(bot);
        oracle.postFeeRecommendation(PoolId.unwrap(poolId), rec);

        _doSwap(true, -1 ether);

        bytes32 id = PoolId.unwrap(poolId);
        PoolStats memory stats = hook.getPoolStats(id);
        assertEq(stats.currentFee, 3000); // Unchanged
    }

    function test_dynamicFee_tooHigh_reverts() public {
        // Post a fee recommendation above MAX_FEE (1_000_000)
        FeeRecommendation memory rec = FeeRecommendation({
            fee: 1_500_000,
            confidence: 90,
            timestamp: block.timestamp
        });
        vm.prank(bot);
        oracle.postFeeRecommendation(PoolId.unwrap(poolId), rec);

        // Swap should revert (FeeTooHigh wrapped by PoolManager)
        SwapParams memory params = SwapParams({
            zeroForOne: true,
            amountSpecified: -1 ether,
            sqrtPriceLimitX96: MIN_PRICE_LIMIT
        });
        PoolSwapTest.TestSettings memory settings = PoolSwapTest.TestSettings({
            takeClaims: false,
            settleUsingBurn: false
        });
        vm.expectRevert();
        swapRouter.swap(key, params, settings, "");
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
