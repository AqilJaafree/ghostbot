// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console} from "forge-std/Script.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {TestToken} from "../src/TestToken.sol";
import {OpenClawACLMHook} from "../src/OpenClawACLMHook.sol";
import {BaseCustomAccounting} from "@openzeppelin/uniswap-hooks/base/BaseCustomAccounting.sol";

contract SetupPool is Script {
    address constant POOL_MANAGER = 0xE03A1074c86CFeDd5C142C4F04F1a1536e203543;
    address constant HOOK = 0xbD2802B7215530894d5696ab8450115f56b1fAC0;

    int24 constant TICK_SPACING = 60;
    uint160 constant SQRT_PRICE_1_1 = 79228162514264337593543950336; // 1:1 price

    function run() external {
        uint256 deployerPrivateKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);

        vm.startBroadcast(deployerPrivateKey);

        // 1. Deploy test tokens
        TestToken tokenA = new TestToken("GhostBot Token A", "GBA");
        TestToken tokenB = new TestToken("GhostBot Token B", "GBB");
        console.log("Token A:", address(tokenA));
        console.log("Token B:", address(tokenB));

        // 2. Sort tokens (currency0 < currency1 required by Uniswap v4)
        address currency0;
        address currency1;
        if (address(tokenA) < address(tokenB)) {
            currency0 = address(tokenA);
            currency1 = address(tokenB);
        } else {
            currency0 = address(tokenB);
            currency1 = address(tokenA);
        }
        console.log("Currency0:", currency0);
        console.log("Currency1:", currency1);

        // 3. Mint tokens to deployer (1M each)
        uint256 mintAmount = 1_000_000 ether;
        TestToken(currency0).mint(deployer, mintAmount);
        TestToken(currency1).mint(deployer, mintAmount);
        console.log("Minted", mintAmount / 1e18, "of each token to deployer");

        // 4. Approve hook and PoolManager to spend tokens
        IERC20(currency0).approve(HOOK, type(uint256).max);
        IERC20(currency1).approve(HOOK, type(uint256).max);
        IERC20(currency0).approve(POOL_MANAGER, type(uint256).max);
        IERC20(currency1).approve(POOL_MANAGER, type(uint256).max);
        console.log("Approved hook and PoolManager");

        // 5. Initialize pool
        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(currency0),
            currency1: Currency.wrap(currency1),
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(HOOK)
        });

        int24 tick = IPoolManager(POOL_MANAGER).initialize(key, SQRT_PRICE_1_1);
        console.log("Pool initialized at tick:", tick);

        // 6. Add initial liquidity via hook
        OpenClawACLMHook hook = OpenClawACLMHook(payable(HOOK));
        uint256 liquidityAmount = 100_000 ether;

        // autoRebalance salt: bit 0 set
        bytes32 salt = bytes32(uint256(1));

        hook.addLiquidity(
            BaseCustomAccounting.AddLiquidityParams({
                amount0Desired: liquidityAmount,
                amount1Desired: liquidityAmount,
                amount0Min: 0,
                amount1Min: 0,
                deadline: block.timestamp + 3600,
                tickLower: -600,
                tickUpper: 600,
                userInputSalt: salt
            })
        );
        console.log("Initial liquidity added (100K each token, range [-600, 600])");

        vm.stopBroadcast();

        console.log("---");
        console.log("CURRENCY0=", currency0);
        console.log("CURRENCY1=", currency1);
        console.log("TOKEN_A=", address(tokenA));
        console.log("TOKEN_B=", address(tokenB));
    }
}
