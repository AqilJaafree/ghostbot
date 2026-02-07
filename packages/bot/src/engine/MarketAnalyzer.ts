import type { PublicClient } from "viem";
import type { PoolStats } from "@ghostbot/sdk";

export interface MarketAnalysis {
  currentTick: number;
  sqrtPriceX96: bigint;
  liquidity: bigint;
  volatility: number; // annualized
  volume24h: bigint;
  trend: "bullish" | "bearish" | "neutral";
  tickHistory: number[];
}

export class MarketAnalyzer {
  private tickHistory: number[] = [];
  private readonly maxHistory = 1440; // 24h at 1-min intervals

  analyze(
    currentTick: number,
    sqrtPriceX96: bigint,
    liquidity: bigint,
    poolStats: PoolStats
  ): MarketAnalysis {
    this.tickHistory.push(currentTick);
    if (this.tickHistory.length > this.maxHistory) {
      this.tickHistory.shift();
    }

    const volatility = this.computeVolatility();
    const trend = this.detectTrend();

    return {
      currentTick,
      sqrtPriceX96,
      liquidity,
      volatility,
      volume24h: poolStats.cumulativeVolume,
      trend,
      tickHistory: [...this.tickHistory],
    };
  }

  private computeVolatility(): number {
    if (this.tickHistory.length < 2) return 0;

    const returns: number[] = [];
    for (let i = 1; i < this.tickHistory.length; i++) {
      returns.push(this.tickHistory[i] - this.tickHistory[i - 1]);
    }

    const mean = returns.reduce((a, b) => a + b, 0) / returns.length;
    const variance = returns.reduce((sum, r) => sum + (r - mean) ** 2, 0) / returns.length;
    const stdDev = Math.sqrt(variance);

    // Annualize: multiply by sqrt(525600) for minute-level data
    return stdDev * Math.sqrt(525600);
  }

  private detectTrend(): "bullish" | "bearish" | "neutral" {
    if (this.tickHistory.length < 20) return "neutral";

    const recent = this.tickHistory.slice(-10);
    const older = this.tickHistory.slice(-20, -10);

    const recentAvg = recent.reduce((a, b) => a + b, 0) / recent.length;
    const olderAvg = older.reduce((a, b) => a + b, 0) / older.length;

    const diff = recentAvg - olderAvg;
    if (diff > 10) return "bullish";
    if (diff < -10) return "bearish";
    return "neutral";
  }
}
