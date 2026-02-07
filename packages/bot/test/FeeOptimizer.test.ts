import { describe, it, expect } from "vitest";
import { FeeOptimizer } from "../src/engine/FeeOptimizer.js";
import type { MarketAnalysis } from "../src/engine/MarketAnalyzer.js";

const makeAnalysis = (overrides: Partial<MarketAnalysis> = {}): MarketAnalysis => ({
  currentTick: 0,
  sqrtPriceX96: 0n,
  liquidity: 0n,
  volatility: 50,
  volume24h: 5000n * 10n ** 18n,
  trend: "neutral",
  tickHistory: new Array(100).fill(0),
  ...overrides,
});

describe("FeeOptimizer", () => {
  const optimizer = new FeeOptimizer();

  it("returns base fee for moderate conditions", () => {
    const result = optimizer.computeOptimalFee(makeAnalysis({ volatility: 50 }));
    expect(result.fee).toBe(3000);
  });

  it("increases fee for high volatility", () => {
    const result = optimizer.computeOptimalFee(makeAnalysis({ volatility: 200 }));
    expect(result.fee).toBeGreaterThan(3000);
    expect(result.fee).toBeLessThanOrEqual(10000);
  });

  it("decreases fee for low volatility + low volume", () => {
    const result = optimizer.computeOptimalFee(
      makeAnalysis({ volatility: 10, volume24h: 100n * 10n ** 18n })
    );
    expect(result.fee).toBeLessThan(3000);
    expect(result.fee).toBeGreaterThanOrEqual(100);
  });

  it("clamps fee to [100, 10000]", () => {
    const high = optimizer.computeOptimalFee(makeAnalysis({ volatility: 10000 }));
    expect(high.fee).toBeLessThanOrEqual(10000);
    expect(high.fee).toBeGreaterThanOrEqual(100);
  });

  it("reduces confidence with limited data", () => {
    const enough = optimizer.computeOptimalFee(
      makeAnalysis({ tickHistory: new Array(100).fill(0) })
    );
    const notEnough = optimizer.computeOptimalFee(
      makeAnalysis({ tickHistory: new Array(10).fill(0) })
    );
    expect(notEnough.confidence).toBeLessThan(enough.confidence);
  });
});
