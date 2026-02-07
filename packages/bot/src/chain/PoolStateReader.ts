import { type PublicClient, type Address, type Hex } from "viem";
import { OpenClawACLMHookABI, type PoolStats } from "@ghostbot/sdk";

// Minimal StateLibrary ABI for reading slot0
const stateLibraryABI = [
  {
    inputs: [{ name: "id", type: "bytes32" }],
    name: "extsload",
    outputs: [{ name: "", type: "bytes32" }],
    stateMutability: "view",
    type: "function",
  },
] as const;

export interface PoolState {
  sqrtPriceX96: bigint;
  tick: number;
  protocolFee: number;
  lpFee: number;
}

export class PoolStateReader {
  constructor(
    private readonly publicClient: PublicClient,
    private readonly hookAddress: Address,
    private readonly poolManagerAddress: Address
  ) {}

  async getPoolStats(poolId: Hex): Promise<PoolStats> {
    const result = await this.publicClient.readContract({
      address: this.hookAddress,
      abi: OpenClawACLMHookABI,
      functionName: "getPoolStats",
      args: [poolId],
    });
    return result as unknown as PoolStats;
  }
}
