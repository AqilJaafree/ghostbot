import { describe, it, expect, beforeEach } from "vitest";
import { MarketAnalyzer, type MarketAnalysis } from "../src/engine/MarketAnalyzer.js";
import type { PoolStats } from "@ghostbot/sdk";

const makePoolStats = (overrides: Partial<PoolStats> = {}): PoolStats => ({
  cumulativeVolume: 0n,
  lastVolumeUpdate: 0n,
  volatility: 0n,
  currentFee: 3000,
  lastTick: 0,
  ...overrides,
});

describe("MarketAnalyzer", () => {
  let analyzer: MarketAnalyzer;

  beforeEach(() => {
    analyzer = new MarketAnalyzer();
  });

  it("returns zero volatility with single data point", () => {
    const result = analyzer.analyze(100, 0n, 0n, makePoolStats());
    expect(result.volatility).toBe(0);
    expect(result.currentTick).toBe(100);
  });

  it("computes non-zero volatility with multiple data points", () => {
    const stats = makePoolStats();
    analyzer.analyze(100, 0n, 0n, stats);
    analyzer.analyze(110, 0n, 0n, stats);
    const result = analyzer.analyze(95, 0n, 0n, stats);
    expect(result.volatility).toBeGreaterThan(0);
  });

  it("returns neutral trend with < 20 data points", () => {
    const stats = makePoolStats();
    let result: MarketAnalysis = analyzer.analyze(0, 0n, 0n, stats);
    for (let i = 1; i < 19; i++) {
      result = analyzer.analyze(i * 10, 0n, 0n, stats);
    }
    expect(result.trend).toBe("neutral");
  });

  it("detects bullish trend", () => {
    const stats = makePoolStats();
    // 10 older ticks at low value
    for (let i = 0; i < 10; i++) {
      analyzer.analyze(100, 0n, 0n, stats);
    }
    // 10 recent ticks at higher value (diff > 10)
    let result: MarketAnalysis = analyzer.analyze(100, 0n, 0n, stats);
    for (let i = 0; i < 9; i++) {
      result = analyzer.analyze(120, 0n, 0n, stats);
    }
    expect(result.trend).toBe("bullish");
  });

  it("detects bearish trend", () => {
    const stats = makePoolStats();
    // 10 older ticks at high value
    for (let i = 0; i < 10; i++) {
      analyzer.analyze(120, 0n, 0n, stats);
    }
    // 10 recent ticks at lower value (diff < -10)
    let result: MarketAnalysis = analyzer.analyze(120, 0n, 0n, stats);
    for (let i = 0; i < 9; i++) {
      result = analyzer.analyze(100, 0n, 0n, stats);
    }
    expect(result.trend).toBe("bearish");
  });

  it("caps history at maxHistory (1440)", () => {
    const stats = makePoolStats();
    let result: MarketAnalysis = analyzer.analyze(0, 0n, 0n, stats);
    for (let i = 1; i < 1500; i++) {
      result = analyzer.analyze(i, 0n, 0n, stats);
    }
    expect(result.tickHistory.length).toBe(1440);
  });

  it("includes pool stats volume in analysis", () => {
    const stats = makePoolStats({ cumulativeVolume: 5000n * 10n ** 18n });
    const result = analyzer.analyze(100, 0n, 0n, stats);
    expect(result.volume24h).toBe(5000n * 10n ** 18n);
  });
});
