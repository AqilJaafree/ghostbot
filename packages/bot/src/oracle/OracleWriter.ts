import {
  type WalletClient,
  type PublicClient,
  type Hex,
  type Address,
  encodeFunctionData,
} from "viem";
import {
  OpenClawOracleABI,
  type RebalanceSignal,
  type FeeRecommendation,
} from "@ghostbot/sdk";

export class OracleWriter {
  constructor(
    private readonly walletClient: WalletClient,
    private readonly publicClient: PublicClient,
    private readonly oracleAddress: Address
  ) {}

  async postRebalanceSignal(
    poolId: Hex,
    signal: RebalanceSignal
  ): Promise<Hex> {
    const { request } = await this.publicClient.simulateContract({
      address: this.oracleAddress,
      abi: OpenClawOracleABI,
      functionName: "postRebalanceSignal",
      args: [
        poolId,
        {
          positionId: signal.positionId,
          newTickLower: signal.newTickLower,
          newTickUpper: signal.newTickUpper,
          confidence: signal.confidence,
          timestamp: signal.timestamp,
        },
      ],
      account: this.walletClient.account!,
    });
    return this.walletClient.writeContract(request);
  }

  async postFeeRecommendation(
    poolId: Hex,
    recommendation: FeeRecommendation
  ): Promise<Hex> {
    const { request } = await this.publicClient.simulateContract({
      address: this.oracleAddress,
      abi: OpenClawOracleABI,
      functionName: "postFeeRecommendation",
      args: [
        poolId,
        {
          fee: recommendation.fee,
          confidence: recommendation.confidence,
          timestamp: recommendation.timestamp,
        },
      ],
      account: this.walletClient.account!,
    });
    return this.walletClient.writeContract(request);
  }
}
