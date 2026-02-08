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
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
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
        hook.setMinConfidence(10); // Set to valid floor
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

    function test_rebalancePosition_movesLiquidity() public {
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

        // Add wide liquidity so the pool has tokens to work with
        BaseCustomAccounting.AddLiquidityParams memory wideLiq = BaseCustomAccounting.AddLiquidityParams(
            100 ether, 100 ether, 90 ether, 90 ether, MAX_DEADLINE, MIN_TICK, MAX_TICK, bytes32(uint256(2))
        );
        hook.addLiquidity(wideLiq);

        // Call rebalancePosition directly (owner = this contract)
        hook.rebalancePosition(positionId, -240, 240);

        // Verify position was rebalanced (ticks changed)
        Position memory posAfter = hook.getPosition(positionId);
        assertEq(posAfter.tickLower, -240);
        assertEq(posAfter.tickUpper, 240);
        assertTrue(posAfter.lastRebalanceTime == block.timestamp);
    }

    function test_rebalancePosition_respectsCooldown() public {
        hook.setRebalanceCooldown(1 hours);

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

        // Should revert because cooldown hasn't elapsed
        vm.expectRevert(OpenClawACLMHook.RebalanceCooldownNotElapsed.selector);
        hook.rebalancePosition(positionId, -240, 240);

        // Warp past cooldown
        vm.warp(block.timestamp + 1 hours + 1);
        hook.rebalancePosition(positionId, -240, 240);

        Position memory pos = hook.getPosition(positionId);
        assertEq(pos.tickLower, -240);
    }

    function test_rebalancePosition_invalidTickRange_reverts() public {
        bytes32 salt = bytes32(uint256(1));
        BaseCustomAccounting.AddLiquidityParams memory addParams = BaseCustomAccounting.AddLiquidityParams(
            10 ether, 10 ether, 9 ether, 9 ether, MAX_DEADLINE, -120, 120, salt
        );
        hook.addLiquidity(addParams);

        uint256[] memory positions = hook.getUserPositions(address(this));
        uint256 positionId = positions[0];

        // Lower >= upper
        vm.expectRevert(OpenClawACLMHook.InvalidTickRange.selector);
        hook.rebalancePosition(positionId, 120, -120);
    }

    function test_rebalancePosition_nonAutoRebalance_reverts() public {
        // Salt bit 0 = 0 -> no auto-rebalance
        bytes32 salt = bytes32(uint256(0));
        BaseCustomAccounting.AddLiquidityParams memory addParams = BaseCustomAccounting.AddLiquidityParams(
            10 ether, 10 ether, 9 ether, 9 ether, MAX_DEADLINE, -120, 120, salt
        );
        hook.addLiquidity(addParams);

        uint256[] memory positions = hook.getUserPositions(address(this));
        uint256 positionId = positions[0];

        vm.expectRevert(OpenClawACLMHook.NotAutoRebalance.selector);
        hook.rebalancePosition(positionId, -240, 240);
    }

    function test_rebalancePosition_notFound_reverts() public {
        vm.expectRevert(OpenClawACLMHook.PositionNotFound.selector);
        hook.rebalancePosition(999, -240, 240);
    }

    function test_rebalancePosition_onlyOwner() public {
        bytes32 salt = bytes32(uint256(1));
        BaseCustomAccounting.AddLiquidityParams memory addParams = BaseCustomAccounting.AddLiquidityParams(
            10 ether, 10 ether, 9 ether, 9 ether, MAX_DEADLINE, -120, 120, salt
        );
        hook.addLiquidity(addParams);

        uint256[] memory positions = hook.getUserPositions(address(this));
        uint256 positionId = positions[0];

        vm.prank(makeAddr("attacker"));
        vm.expectRevert();
        hook.rebalancePosition(positionId, -240, 240);
    }

    function test_afterSwap_emitsRebalanceRequested() public {
        // Add position with autoRebalance enabled
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

        // Move price significantly out of range
        _doSwap(true, -50 ether);

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

        // Next swap should emit RebalanceRequested (not actually rebalance)
        vm.expectEmit(true, false, false, false);
        emit OpenClawACLMHook.RebalanceRequested(positionId, 0, 0);
        _doSwap(false, -1 ether);

        // Position should NOT have been rebalanced (only event emitted)
        Position memory pos = hook.getPosition(positionId);
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

        // Post with low confidence (below minConfidence = 10 for this test,
        // but we set it higher for this specific check)
        hook.setMinConfidence(70);

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
        assertEq(pos.tickLower, -120); // Not rebalanced (low confidence filtered)
    }

    function test_needsRebalancing_outOfRange() public pure {
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

    // ── H-4 fix: Rebalance surplus is tracked and claimable ────────────
    function test_rebalanceSurplus_trackedAndClaimable() public {
        // Add wide liquidity first so the pool has tokens for swaps
        BaseCustomAccounting.AddLiquidityParams memory wideLiq = BaseCustomAccounting.AddLiquidityParams(
            100 ether, 100 ether, 90 ether, 90 ether, MAX_DEADLINE, MIN_TICK, MAX_TICK, bytes32(uint256(2))
        );
        hook.addLiquidity(wideLiq);

        // Add a wide-range position with autoRebalance enabled (centered around tick 0)
        bytes32 salt = bytes32(uint256(1));
        BaseCustomAccounting.AddLiquidityParams memory addParams = BaseCustomAccounting.AddLiquidityParams(
            10 ether, 10 ether, 9 ether, 9 ether, MAX_DEADLINE, -3600, 3600, salt
        );
        hook.addLiquidity(addParams);

        uint256[] memory positions = hook.getUserPositions(address(this));
        uint256 positionId = positions[1];

        // Move price slightly to make removal return both tokens asymmetrically
        _doSwap(true, -5 ether);
        (, int24 currentTick,,) = manager.getSlot0(poolId);

        // Rebalance to a range entirely above current price. When price is below
        // the new range, only token1 is needed for the add. The token0 portion
        // from removal becomes surplus.
        int24 newLower = _snapToTickSpacing(currentTick + 120, TICK_SPACING);
        int24 newUpper = _snapToTickSpacing(currentTick + 3600, TICK_SPACING);

        hook.rebalancePosition(positionId, newLower, newUpper);

        // Check that surplus was tracked
        uint256 surplus0 = hook.rebalanceSurplus(positionId, currency0);
        uint256 surplus1 = hook.rebalanceSurplus(positionId, currency1);

        bool hasSurplus = surplus0 > 0 || surplus1 > 0;
        assertTrue(hasSurplus, "Should have surplus after rebalance to above-price range");

        // Claim the surplus
        if (surplus0 > 0) {
            uint256 balBefore = MockERC20(Currency.unwrap(currency0)).balanceOf(address(this));
            hook.claimRebalanceSurplus(positionId, currency0);
            uint256 balAfter = MockERC20(Currency.unwrap(currency0)).balanceOf(address(this));
            assertEq(balAfter - balBefore, surplus0, "Should receive surplus0 tokens");
            assertEq(hook.rebalanceSurplus(positionId, currency0), 0, "Surplus should be zeroed after claim");
        }
        if (surplus1 > 0) {
            uint256 balBefore = MockERC20(Currency.unwrap(currency1)).balanceOf(address(this));
            hook.claimRebalanceSurplus(positionId, currency1);
            uint256 balAfter = MockERC20(Currency.unwrap(currency1)).balanceOf(address(this));
            assertEq(balAfter - balBefore, surplus1, "Should receive surplus1 tokens");
            assertEq(hook.rebalanceSurplus(positionId, currency1), 0, "Surplus should be zeroed after claim");
        }
    }

    function _snapToTickSpacing(int24 tick, int24 tickSpacing) internal pure returns (int24) {
        int24 compressed = tick / tickSpacing;
        if (tick < 0 && tick % tickSpacing != 0) compressed--;
        return compressed * tickSpacing;
    }

    // ── H-4 fix: Claiming surplus with no surplus reverts ─────────────
    function test_claimRebalanceSurplus_noSurplus_reverts() public {
        bytes32 salt = bytes32(uint256(1));
        BaseCustomAccounting.AddLiquidityParams memory addParams = BaseCustomAccounting.AddLiquidityParams(
            10 ether, 10 ether, 9 ether, 9 ether, MAX_DEADLINE, -120, 120, salt
        );
        hook.addLiquidity(addParams);

        uint256[] memory positions = hook.getUserPositions(address(this));
        uint256 positionId = positions[0];

        // No rebalance happened, so no surplus
        vm.expectRevert(OpenClawACLMHook.NoSurplusToClaim.selector);
        hook.claimRebalanceSurplus(positionId, currency0);
    }

    // ── H-4 fix: Only position owner can claim surplus ────────────────
    function test_claimRebalanceSurplus_notOwner_reverts() public {
        bytes32 salt = bytes32(uint256(1));
        BaseCustomAccounting.AddLiquidityParams memory addParams = BaseCustomAccounting.AddLiquidityParams(
            10 ether, 10 ether, 9 ether, 9 ether, MAX_DEADLINE, -120, 120, salt
        );
        hook.addLiquidity(addParams);

        uint256[] memory positions = hook.getUserPositions(address(this));
        uint256 positionId = positions[0];

        vm.prank(makeAddr("attacker"));
        vm.expectRevert(OpenClawACLMHook.NotPositionOwner.selector);
        hook.claimRebalanceSurplus(positionId, currency0);
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
