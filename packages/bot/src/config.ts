import { type Hex, type Address } from "viem";

export interface BotConfig {
  rpcUrl: string;
  botPrivateKey: Hex;
  oracleAddress: Address;
  hookAddress: Address;
  poolManagerAddress: Address;
  heartbeatInterval: number; // ms
  maxGasPrice: bigint;
}

export function loadConfig(): BotConfig {
  const required = (key: string): string => {
    const value = process.env[key];
    if (!value) throw new Error(`Missing required env var: ${key}`);
    return value;
  };

  return {
    rpcUrl: required("RPC_URL"),
    botPrivateKey: required("BOT_PRIVATE_KEY") as Hex,
    oracleAddress: required("ORACLE_ADDRESS") as Address,
    hookAddress: required("HOOK_ADDRESS") as Address,
    poolManagerAddress: process.env.POOL_MANAGER_ADDRESS as Address ?? "0x000000000004444c5dc75cB358380D2e3dE08A90",
    heartbeatInterval: Number(process.env.HEARTBEAT_INTERVAL ?? "60000"),
    maxGasPrice: BigInt(process.env.MAX_GAS_PRICE ?? "50000000000"), // 50 gwei default
  };
}
