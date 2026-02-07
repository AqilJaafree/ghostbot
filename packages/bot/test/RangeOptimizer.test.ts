import { describe, it, expect } from "vitest";
import { RangeOptimizer } from "../src/engine/RangeOptimizer.js";
import type { MarketAnalysis } from "../src/engine/MarketAnalyzer.js";

const makeAnalysis = (overrides: Partial<MarketAnalysis> = {}): MarketAnalysis => ({
  currentTick: 0,
  sqrtPriceX96: 0n,
  liquidity: 0n,
  volatility: 50,
  volume24h: 1000n * 10n ** 18n,
  trend: "neutral",
  tickHistory: new Array(100).fill(0),
  ...overrides,
});

describe("RangeOptimizer", () => {
  it("returns range centered on current tick for neutral trend", () => {
    const optimizer = new RangeOptimizer(2.0);
    const analysis = makeAnalysis({ currentTick: 1000 });
    const result = optimizer.computeOptimalRange(analysis, 60);
    // Should be roughly centered on 1000
    expect(result.tickLower).toBeLessThan(1000);
    expect(result.tickUpper).toBeGreaterThan(1000);
  });

  it("shifts range up for bullish trend", () => {
    const optimizer = new RangeOptimizer(2.0);
    const neutral = optimizer.computeOptimalRange(makeAnalysis({ currentTick: 1000 }), 60);
    const bullish = optimizer.computeOptimalRange(
      makeAnalysis({ currentTick: 1000, trend: "bullish" }),
      60
    );
    // Bullish midpoint should be higher than neutral midpoint
    const neutralMid = (neutral.tickLower + neutral.tickUpper) / 2;
    const bullishMid = (bullish.tickLower + bullish.tickUpper) / 2;
    expect(bullishMid).toBeGreaterThanOrEqual(neutralMid);
  });

  it("shifts range down for bearish trend", () => {
    const optimizer = new RangeOptimizer(2.0);
    const neutral = optimizer.computeOptimalRange(makeAnalysis({ currentTick: 1000 }), 60);
    const bearish = optimizer.computeOptimalRange(
      makeAnalysis({ currentTick: 1000, trend: "bearish" }),
      60
    );
    const neutralMid = (neutral.tickLower + neutral.tickUpper) / 2;
    const bearishMid = (bearish.tickLower + bearish.tickUpper) / 2;
    expect(bearishMid).toBeLessThanOrEqual(neutralMid);
  });

  it("snaps to tick spacing", () => {
    const optimizer = new RangeOptimizer(2.0);
    const result = optimizer.computeOptimalRange(makeAnalysis({ currentTick: 1000 }), 60);
    expect(result.tickLower % 60).toBe(0);
    expect(result.tickUpper % 60).toBe(0);
  });

  it("enforces minimum range width", () => {
    const optimizer = new RangeOptimizer(0.001); // Very tight kFactor
    const result = optimizer.computeOptimalRange(
      makeAnalysis({ currentTick: 1000, volatility: 0.001 }),
      60
    );
    expect(result.tickUpper - result.tickLower).toBeGreaterThanOrEqual(240); // 4 * tickSpacing
  });

  it("lowers confidence with insufficient data", () => {
    const optimizer = new RangeOptimizer(2.0);
    const sufficient = optimizer.computeOptimalRange(
      makeAnalysis({ tickHistory: new Array(100).fill(0) }),
      60
    );
    const insufficient = optimizer.computeOptimalRange(
      makeAnalysis({ tickHistory: new Array(10).fill(0) }),
      60
    );
    expect(insufficient.confidence).toBeLessThan(sufficient.confidence);
  });

  it("lowers confidence when volatility is zero", () => {
    const optimizer = new RangeOptimizer(2.0);
    const result = optimizer.computeOptimalRange(
      makeAnalysis({ volatility: 0 }),
      60
    );
    expect(result.confidence).toBeLessThanOrEqual(55); // 85 - 30 for zero sigma
  });
});
