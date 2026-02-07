import type { RangeRecommendation } from "./RangeOptimizer.js";
import type { FeeRecommendation } from "./FeeOptimizer.js";
import type { TriggeredOrder } from "./LimitOrderMonitor.js";
import type { RebalanceSignal, FeeRecommendation as FeeRec } from "@ghostbot/sdk";

export interface Decision {
  rebalanceSignals: RebalanceSignal[];
  feeRecommendation: FeeRec | null;
  triggeredOrders: TriggeredOrder[];
}

export class DecisionAggregator {
  private lastOracleWrite = 0;
  private readonly minWriteInterval = 60_000; // 60s rate limit

  aggregate(
    positionRanges: Map<bigint, RangeRecommendation>,
    feeRec: FeeRecommendation,
    triggeredOrders: TriggeredOrder[],
    minConfidence: number = 70
  ): Decision {
    const now = Date.now();
    const canWrite = now - this.lastOracleWrite >= this.minWriteInterval;

    // Build rebalance signals (only high confidence)
    const rebalanceSignals: RebalanceSignal[] = [];
    for (const [positionId, range] of positionRanges) {
      if (range.confidence >= minConfidence) {
        rebalanceSignals.push({
          positionId,
          newTickLower: range.tickLower,
          newTickUpper: range.tickUpper,
          confidence: range.confidence,
          timestamp: BigInt(Math.floor(now / 1000)),
        });
      }
    }

    // Fee recommendation (only if confident enough)
    let feeRecommendation: FeeRec | null = null;
    if (feeRec.confidence >= minConfidence && canWrite) {
      feeRecommendation = {
        fee: feeRec.fee,
        confidence: feeRec.confidence,
        timestamp: BigInt(Math.floor(now / 1000)),
      };
    }

    if (canWrite && (rebalanceSignals.length > 0 || feeRecommendation)) {
      this.lastOracleWrite = now;
    }

    return { rebalanceSignals, feeRecommendation, triggeredOrders };
  }
}
