import { describe, it, expect, beforeEach, vi } from "vitest";
import { DecisionAggregator } from "../src/engine/DecisionAggregator.js";
import type { RangeRecommendation } from "../src/engine/RangeOptimizer.js";
import type { FeeRecommendation } from "../src/engine/FeeOptimizer.js";

describe("DecisionAggregator", () => {
  let aggregator: DecisionAggregator;

  beforeEach(() => {
    aggregator = new DecisionAggregator();
    vi.useFakeTimers();
    vi.setSystemTime(new Date("2025-01-01T00:00:00Z"));
  });

  const highConfRange: RangeRecommendation = { tickLower: -120, tickUpper: 120, confidence: 85 };
  const lowConfRange: RangeRecommendation = { tickLower: -60, tickUpper: 60, confidence: 50 };
  const highConfFee: FeeRecommendation = { fee: 3000, confidence: 80 };
  const lowConfFee: FeeRecommendation = { fee: 3000, confidence: 50 };

  it("includes high-confidence rebalance signals", () => {
    const ranges = new Map<bigint, RangeRecommendation>([[1n, highConfRange]]);
    const decision = aggregator.aggregate(ranges, highConfFee, []);
    expect(decision.rebalanceSignals).toHaveLength(1);
    expect(decision.rebalanceSignals[0].positionId).toBe(1n);
    expect(decision.rebalanceSignals[0].newTickLower).toBe(-120);
    expect(decision.rebalanceSignals[0].newTickUpper).toBe(120);
  });

  it("filters out low-confidence rebalance signals", () => {
    const ranges = new Map<bigint, RangeRecommendation>([[1n, lowConfRange]]);
    const decision = aggregator.aggregate(ranges, highConfFee, []);
    expect(decision.rebalanceSignals).toHaveLength(0);
  });

  it("includes fee recommendation when confident and can write", () => {
    const ranges = new Map<bigint, RangeRecommendation>();
    const decision = aggregator.aggregate(ranges, highConfFee, []);
    expect(decision.feeRecommendation).not.toBeNull();
    expect(decision.feeRecommendation!.fee).toBe(3000);
  });

  it("excludes fee recommendation when low confidence", () => {
    const ranges = new Map<bigint, RangeRecommendation>();
    const decision = aggregator.aggregate(ranges, lowConfFee, []);
    expect(decision.feeRecommendation).toBeNull();
  });

  it("rate limits oracle writes (60s interval)", () => {
    const ranges = new Map<bigint, RangeRecommendation>([[1n, highConfRange]]);

    // First call — should write
    const d1 = aggregator.aggregate(ranges, highConfFee, []);
    expect(d1.feeRecommendation).not.toBeNull();

    // Advance 30s — within rate limit
    vi.advanceTimersByTime(30_000);
    const d2 = aggregator.aggregate(ranges, highConfFee, []);
    expect(d2.feeRecommendation).toBeNull();

    // Advance another 31s (total 61s) — past rate limit
    vi.advanceTimersByTime(31_000);
    const d3 = aggregator.aggregate(ranges, highConfFee, []);
    expect(d3.feeRecommendation).not.toBeNull();
  });

  it("passes through triggered orders", () => {
    const ranges = new Map<bigint, RangeRecommendation>();
    const orders = [
      {
        orderId: 5n,
        order: {
          owner: "0x0000000000000000000000000000000000000001" as `0x${string}`,
          zeroForOne: true,
          triggerTick: 100,
          amountIn: 1000n,
          amountOutMin: 900n,
          orderType: 0,
          linkedPositionId: 0n,
          executed: false,
          cancelled: false,
        },
      },
    ];
    const decision = aggregator.aggregate(ranges, lowConfFee, orders);
    expect(decision.triggeredOrders).toHaveLength(1);
    expect(decision.triggeredOrders[0].orderId).toBe(5n);
  });

  it("respects custom minConfidence threshold", () => {
    const ranges = new Map<bigint, RangeRecommendation>([[1n, lowConfRange]]);
    // Default threshold 70 should filter out confidence 50
    const d1 = aggregator.aggregate(ranges, highConfFee, [], 70);
    expect(d1.rebalanceSignals).toHaveLength(0);

    // Lower threshold to 40 should include it
    const d2 = aggregator.aggregate(ranges, highConfFee, [], 40);
    expect(d2.rebalanceSignals).toHaveLength(1);
  });
});
