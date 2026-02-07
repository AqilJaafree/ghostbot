// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console} from "forge-std/Script.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";

import {OpenClawOracle} from "../src/OpenClawOracle.sol";
import {OpenClawACLMHook} from "../src/OpenClawACLMHook.sol";
import {IOpenClawOracle} from "../src/interfaces/IOpenClawOracle.sol";

contract Deploy is Script {
    // Uniswap v4 PoolManager address (same across all chains)
    address constant POOL_MANAGER = 0x000000000004444c5dc75cB358380D2e3dE08A90;

    // CREATE2 deployer proxy
    address constant CREATE2_DEPLOYER = 0x4e59b44847b379578588920cA78FbF26c0B4956C;

    function run() external {
        uint256 deployerPrivateKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);
        address botAddress = vm.envAddress("BOT_ADDRESS");

        console.log("Deployer:", deployer);
        console.log("Bot:", botAddress);

        vm.startBroadcast(deployerPrivateKey);

        // 1. Deploy Oracle
        OpenClawOracle oracle = new OpenClawOracle(deployer);
        console.log("Oracle deployed at:", address(oracle));

        // 2. Set bot on oracle
        oracle.setBot(botAddress);
        console.log("Bot set on oracle");

        // 3. Mine hook address and deploy
        uint160 hookFlags = uint160(
            Hooks.BEFORE_INITIALIZE_FLAG | Hooks.AFTER_INITIALIZE_FLAG
                | Hooks.BEFORE_ADD_LIQUIDITY_FLAG | Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG
                | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG
        );

        // Find salt for CREATE2 deployment
        bytes memory creationCode = type(OpenClawACLMHook).creationCode;
        bytes memory constructorArgs = abi.encode(POOL_MANAGER, deployer);
        bytes memory creationCodeWithArgs = abi.encodePacked(creationCode, constructorArgs);

        (address hookAddress, bytes32 salt) = _mineSalt(CREATE2_DEPLOYER, hookFlags, creationCodeWithArgs);
        console.log("Mined hook address:", hookAddress);

        // Deploy via CREATE2
        OpenClawACLMHook hook = new OpenClawACLMHook{salt: salt}(
            IPoolManager(POOL_MANAGER),
            deployer
        );
        console.log("Hook deployed at:", address(hook));
        require(address(hook) == hookAddress, "Hook address mismatch");

        // 4. Configure
        hook.setOracle(IOpenClawOracle(address(oracle)));
        oracle.setHook(address(hook));

        console.log("Configuration complete");
        console.log("---");
        console.log("ORACLE_ADDRESS=", address(oracle));
        console.log("HOOK_ADDRESS=", address(hook));

        vm.stopBroadcast();
    }

    function _mineSalt(address deployer, uint160 flags, bytes memory creationCodeWithArgs)
        internal
        pure
        returns (address, bytes32)
    {
        uint160 flagMask = Hooks.ALL_HOOK_MASK;
        flags = flags & flagMask;

        for (uint256 salt = 0; salt < 160_000; salt++) {
            address hookAddress = address(
                uint160(
                    uint256(keccak256(abi.encodePacked(bytes1(0xFF), deployer, bytes32(salt), keccak256(creationCodeWithArgs))))
                )
            );
            if (uint160(hookAddress) & flagMask == flags) {
                return (hookAddress, bytes32(salt));
            }
        }
        revert("Could not find salt");
    }
}
