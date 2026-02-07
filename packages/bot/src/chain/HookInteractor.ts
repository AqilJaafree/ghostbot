import { type PublicClient, type Address } from "viem";
import { OpenClawACLMHookABI, type Position, type LimitOrder } from "@ghostbot/sdk";

export class HookInteractor {
  constructor(
    private readonly publicClient: PublicClient,
    private readonly hookAddress: Address
  ) {}

  async getUserPositions(user: Address): Promise<bigint[]> {
    return (await this.publicClient.readContract({
      address: this.hookAddress,
      abi: OpenClawACLMHookABI,
      functionName: "getUserPositions",
      args: [user],
    })) as bigint[];
  }

  async getPosition(positionId: bigint): Promise<Position> {
    return (await this.publicClient.readContract({
      address: this.hookAddress,
      abi: OpenClawACLMHookABI,
      functionName: "getPosition",
      args: [positionId],
    })) as unknown as Position;
  }

  async getLimitOrder(orderId: bigint): Promise<LimitOrder> {
    return (await this.publicClient.readContract({
      address: this.hookAddress,
      abi: OpenClawACLMHookABI,
      functionName: "getLimitOrder",
      args: [orderId],
    })) as unknown as LimitOrder;
  }

  async getUserLimitOrders(user: Address): Promise<bigint[]> {
    return (await this.publicClient.readContract({
      address: this.hookAddress,
      abi: OpenClawACLMHookABI,
      functionName: "getUserLimitOrders",
      args: [user],
    })) as bigint[];
  }
}
