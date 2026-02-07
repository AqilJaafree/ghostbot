// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolManager} from "@uniswap/v4-core/src/PoolManager.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {PoolModifyLiquidityTest} from "@uniswap/v4-core/src/test/PoolModifyLiquidityTest.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {SwapParams, ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

import {OpenClawOracle} from "../../src/OpenClawOracle.sol";
import {OpenClawACLMHook} from "../../src/OpenClawACLMHook.sol";
import {IOpenClawOracle} from "../../src/interfaces/IOpenClawOracle.sol";

contract HookTestBase is Test {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    uint160 public constant SQRT_PRICE_1_1 = 79228162514264337593543950336;
    uint160 public constant MIN_PRICE_LIMIT = TickMath.MIN_SQRT_PRICE + 1;
    uint160 public constant MAX_PRICE_LIMIT = TickMath.MAX_SQRT_PRICE - 1;
    uint256 constant MAX_DEADLINE = 12329839823;

    int24 constant TICK_SPACING = 60;
    int24 constant MIN_TICK = -887220;
    int24 constant MAX_TICK = 887220;

    IPoolManager manager;
    PoolSwapTest swapRouter;
    PoolModifyLiquidityTest modifyLiquidityRouter;

    OpenClawOracle oracle;
    OpenClawACLMHook hook;

    Currency currency0;
    Currency currency1;
    PoolKey key;
    PoolId poolId;

    address owner = address(this);
    address bot = makeAddr("bot");
    address user = makeAddr("user");

    function deployManagerAndRouters() internal {
        manager = new PoolManager(address(this));
        swapRouter = new PoolSwapTest(manager);
        modifyLiquidityRouter = new PoolModifyLiquidityTest(manager);
    }

    function deployOracle() internal {
        oracle = new OpenClawOracle(owner);
        oracle.setBot(bot);
    }

    function deployHookAtAddress(address hookAddr) internal {
        // Deploy the hook at a specific address matching required flags
        deployCodeTo(
            "OpenClawACLMHook.sol:OpenClawACLMHook",
            abi.encode(address(manager), owner),
            hookAddr
        );
        hook = OpenClawACLMHook(hookAddr);
        hook.setOracle(IOpenClawOracle(address(oracle)));
        oracle.setHook(hookAddr);
    }

    function computeHookAddress() internal pure returns (address) {
        // The hook needs flags for:
        // beforeInitialize, afterInitialize, beforeAddLiquidity, beforeRemoveLiquidity,
        // beforeSwap, afterSwap
        uint160 flags = uint160(
            Hooks.BEFORE_INITIALIZE_FLAG | Hooks.AFTER_INITIALIZE_FLAG
                | Hooks.BEFORE_ADD_LIQUIDITY_FLAG | Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG
                | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG
        );
        return address(flags);
    }

    function deployTokensAndApprove() internal {
        MockERC20 tokenA = new MockERC20("TokenA", "TKA", 18);
        MockERC20 tokenB = new MockERC20("TokenB", "TKB", 18);

        // Sort currencies
        if (uint160(address(tokenA)) > uint160(address(tokenB))) {
            (tokenA, tokenB) = (tokenB, tokenA);
        }

        currency0 = Currency.wrap(address(tokenA));
        currency1 = Currency.wrap(address(tokenB));

        // Mint tokens
        tokenA.mint(address(this), 1000 ether);
        tokenB.mint(address(this), 1000 ether);
        tokenA.mint(user, 1000 ether);
        tokenB.mint(user, 1000 ether);

        // Approve for routers and hook
        tokenA.approve(address(swapRouter), type(uint256).max);
        tokenB.approve(address(swapRouter), type(uint256).max);
        tokenA.approve(address(modifyLiquidityRouter), type(uint256).max);
        tokenB.approve(address(modifyLiquidityRouter), type(uint256).max);
        tokenA.approve(address(hook), type(uint256).max);
        tokenB.approve(address(hook), type(uint256).max);

        vm.startPrank(user);
        tokenA.approve(address(swapRouter), type(uint256).max);
        tokenB.approve(address(swapRouter), type(uint256).max);
        tokenA.approve(address(hook), type(uint256).max);
        tokenB.approve(address(hook), type(uint256).max);
        vm.stopPrank();
    }

    function initPool() internal {
        key = PoolKey(currency0, currency1, LPFeeLibrary.DYNAMIC_FEE_FLAG, TICK_SPACING, IHooks(address(hook)));
        poolId = key.toId();
        manager.initialize(key, SQRT_PRICE_1_1);
    }

    function fullSetup() internal {
        deployManagerAndRouters();
        deployOracle();
        deployHookAtAddress(computeHookAddress());
        deployTokensAndApprove();
        initPool();
    }

    function doSwap(bool zeroForOne, int256 amountSpecified) internal returns (BalanceDelta) {
        SwapParams memory params = SwapParams({
            zeroForOne: zeroForOne,
            amountSpecified: amountSpecified,
            sqrtPriceLimitX96: zeroForOne ? MIN_PRICE_LIMIT : MAX_PRICE_LIMIT
        });

        PoolSwapTest.TestSettings memory settings = PoolSwapTest.TestSettings({
            takeClaims: false,
            settleUsingBurn: false
        });

        return swapRouter.swap(key, params, settings, "");
    }
}
