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
import {Position, RebalanceSignal} from "../src/types/DataTypes.sol";

contract RebalanceTest is Test {
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
        hook.setRebalanceCooldown(0); // Disable cooldown for testing
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
    }

    function test_rebalance_triggeredOnSwap() public {
        // Add position with autoRebalance enabled (salt bit 0 = 1)
        bytes32 salt = bytes32(uint256(1));
        BaseCustomAccounting.AddLiquidityParams memory addParams = BaseCustomAccounting.AddLiquidityParams(
            10 ether, 10 ether, 9 ether, 9 ether, MAX_DEADLINE, -120, 120, salt
        );
        hook.addLiquidity(addParams);

        uint256[] memory positions = hook.getUserPositions(address(this));
        uint256 positionId = positions[0];

        Position memory posBefore = hook.getPosition(positionId);
        assertEq(posBefore.tickLower, -120);
        assertEq(posBefore.tickUpper, 120);
        assertTrue(posBefore.autoRebalance);

        // Move price significantly out of range by doing a large swap
        // First add wide liquidity so swap can execute
        BaseCustomAccounting.AddLiquidityParams memory wideLiq = BaseCustomAccounting.AddLiquidityParams(
            100 ether, 100 ether, 90 ether, 90 ether, MAX_DEADLINE, MIN_TICK, MAX_TICK, bytes32(uint256(2))
        );
        hook.addLiquidity(wideLiq);

        // Do a swap to move tick - this puts the narrow position out of range
        _doSwap(true, -50 ether);

        // Get current tick after swap
        (, int24 currentTick,,) = manager.getSlot0(poolId);

        // Post rebalance signal from bot
        bytes32 id = PoolId.unwrap(poolId);
        RebalanceSignal memory signal = RebalanceSignal({
            positionId: positionId,
            newTickLower: currentTick - 120,
            newTickUpper: currentTick + 120,
            confidence: 90,
            timestamp: block.timestamp
        });
        vm.prank(bot);
        oracle.postRebalanceSignal(id, signal);

        // Next swap triggers rebalance check
        _doSwap(false, -1 ether);

        // Verify position was rebalanced (ticks changed)
        Position memory posAfter = hook.getPosition(positionId);
        assertTrue(posAfter.tickLower != posBefore.tickLower || posAfter.tickUpper != posBefore.tickUpper);
    }

    function test_rebalance_respects_cooldown() public {
        hook.setRebalanceCooldown(1 hours); // Re-enable cooldown

        bytes32 salt = bytes32(uint256(1));
        BaseCustomAccounting.AddLiquidityParams memory addParams = BaseCustomAccounting.AddLiquidityParams(
            10 ether, 10 ether, 9 ether, 9 ether, MAX_DEADLINE, -120, 120, salt
        );
        hook.addLiquidity(addParams);

        uint256[] memory positions = hook.getUserPositions(address(this));
        uint256 positionId = positions[0];

        // Add wide liquidity
        BaseCustomAccounting.AddLiquidityParams memory wideLiq = BaseCustomAccounting.AddLiquidityParams(
            100 ether, 100 ether, 90 ether, 90 ether, MAX_DEADLINE, MIN_TICK, MAX_TICK, bytes32(uint256(2))
        );
        hook.addLiquidity(wideLiq);

        // Move price out of range
        _doSwap(true, -50 ether);

        (, int24 currentTick,,) = manager.getSlot0(poolId);
        bytes32 id = PoolId.unwrap(poolId);

        // Post rebalance signal
        vm.prank(bot);
        oracle.postRebalanceSignal(id, RebalanceSignal({
            positionId: positionId,
            newTickLower: currentTick - 120,
            newTickUpper: currentTick + 120,
            confidence: 90,
            timestamp: block.timestamp
        }));

        // Swap but cooldown hasn't elapsed, so no rebalance
        _doSwap(false, -1 ether);

        Position memory pos = hook.getPosition(positionId);
        // Position should NOT have been rebalanced (cooldown active)
        assertEq(pos.tickLower, -120);
        assertEq(pos.tickUpper, 120);
    }

    function test_rebalance_lowConfidence_skipped() public {
        bytes32 salt = bytes32(uint256(1));
        BaseCustomAccounting.AddLiquidityParams memory addParams = BaseCustomAccounting.AddLiquidityParams(
            10 ether, 10 ether, 9 ether, 9 ether, MAX_DEADLINE, -120, 120, salt
        );
        hook.addLiquidity(addParams);

        uint256[] memory positions = hook.getUserPositions(address(this));
        uint256 positionId = positions[0];

        BaseCustomAccounting.AddLiquidityParams memory wideLiq = BaseCustomAccounting.AddLiquidityParams(
            100 ether, 100 ether, 90 ether, 90 ether, MAX_DEADLINE, MIN_TICK, MAX_TICK, bytes32(uint256(2))
        );
        hook.addLiquidity(wideLiq);

        _doSwap(true, -50 ether);

        (, int24 currentTick,,) = manager.getSlot0(poolId);
        bytes32 id = PoolId.unwrap(poolId);

        // Post with low confidence (below 70)
        vm.prank(bot);
        oracle.postRebalanceSignal(id, RebalanceSignal({
            positionId: positionId,
            newTickLower: currentTick - 120,
            newTickUpper: currentTick + 120,
            confidence: 50,
            timestamp: block.timestamp
        }));

        _doSwap(false, -1 ether);

        Position memory pos = hook.getPosition(positionId);
        assertEq(pos.tickLower, -120); // Not rebalanced
    }

    function test_needsRebalancing_outOfRange() public view {
        // Test the logic: current tick outside range
        assertTrue(_callNeedsRebalancing(-200, -120, 120)); // Below range
        assertTrue(_callNeedsRebalancing(200, -120, 120));  // Above range
        assertFalse(_callNeedsRebalancing(0, -120, 120));   // In range center
    }

    function _callNeedsRebalancing(int24 current, int24 lower, int24 upper) internal pure returns (bool) {
        // Replicate the hook's internal logic
        if (current <= lower || current >= upper) return true;
        int24 rangeWidth = upper - lower;
        int24 threshold = rangeWidth / 10;
        if (current - lower < threshold) return true;
        if (upper - current < threshold) return true;
        return false;
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
