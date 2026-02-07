import { snapToTickSpacing } from "@ghostbot/sdk";
import type { MarketAnalysis } from "./MarketAnalyzer.js";

export interface RangeRecommendation {
  tickLower: number;
  tickUpper: number;
  confidence: number; // 0-100
}

export class RangeOptimizer {
  private readonly kFactor: number;

  constructor(kFactor: number = 2.0) {
    this.kFactor = kFactor;
  }

  computeOptimalRange(
    analysis: MarketAnalysis,
    tickSpacing: number
  ): RangeRecommendation {
    const sigma = analysis.volatility;
    const currentTick = analysis.currentTick;

    // Range width proportional to volatility
    // k * sigma gives us the half-width in tick space
    let halfWidth = Math.max(Math.round(this.kFactor * sigma), tickSpacing * 2);

    // Apply trend bias
    let bias = 0;
    if (analysis.trend === "bullish") {
      bias = Math.round(halfWidth * 0.2); // Shift range up
    } else if (analysis.trend === "bearish") {
      bias = -Math.round(halfWidth * 0.2); // Shift range down
    }

    let tickLower = snapToTickSpacing(currentTick - halfWidth + bias, tickSpacing);
    let tickUpper = snapToTickSpacing(currentTick + halfWidth + bias, tickSpacing);

    // Ensure minimum range width
    if (tickUpper - tickLower < tickSpacing * 4) {
      tickLower = snapToTickSpacing(currentTick - tickSpacing * 2, tickSpacing);
      tickUpper = snapToTickSpacing(currentTick + tickSpacing * 2, tickSpacing);
    }

    // Confidence based on data quality
    let confidence = 85;
    if (analysis.tickHistory.length < 60) confidence -= 20; // Not enough data
    if (sigma === 0) confidence -= 30;
    confidence = Math.max(0, Math.min(100, confidence));

    return { tickLower, tickUpper, confidence };
  }
}
