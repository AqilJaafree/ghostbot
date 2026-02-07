import { type PublicClient, type Hex, type Address } from "viem";
import { OpenClawOracleABI, type RebalanceSignal, type FeeRecommendation } from "@ghostbot/sdk";

export class OracleReader {
  constructor(
    private readonly publicClient: PublicClient,
    private readonly oracleAddress: Address
  ) {}

  async getPositionsNeedingRebalance(poolId: Hex): Promise<RebalanceSignal[]> {
    const result = await this.publicClient.readContract({
      address: this.oracleAddress,
      abi: OpenClawOracleABI,
      functionName: "getPositionsNeedingRebalance",
      args: [poolId],
    });
    return result as unknown as RebalanceSignal[];
  }

  async getDynamicFee(poolId: Hex): Promise<{ fee: number; confidence: number }> {
    const [fee, confidence] = (await this.publicClient.readContract({
      address: this.oracleAddress,
      abi: OpenClawOracleABI,
      functionName: "getDynamicFee",
      args: [poolId],
    })) as [number, number];
    return { fee, confidence };
  }
}
