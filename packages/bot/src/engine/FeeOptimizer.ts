import type { MarketAnalysis } from "./MarketAnalyzer.js";

export interface FeeRecommendation {
  fee: number; // in hundredths of bip (3000 = 0.3%)
  confidence: number;
}

export class FeeOptimizer {
  private readonly minFee = 100; // 0.01%
  private readonly maxFee = 10000; // 1.00%
  private readonly baseFee = 3000; // 0.30%

  computeOptimalFee(analysis: MarketAnalysis): FeeRecommendation {
    let fee = this.baseFee;
    let confidence = 80;

    // High volatility -> raise fees
    if (analysis.volatility > 100) {
      fee = Math.min(this.maxFee, Math.round(this.baseFee * (1 + analysis.volatility / 500)));
    }

    // Low volatility + low volume -> lower fees to attract volume
    if (analysis.volatility < 20 && analysis.volume24h < 1000n * 10n ** 18n) {
      fee = Math.max(this.minFee, Math.round(this.baseFee * 0.5));
    }

    // Clamp
    fee = Math.max(this.minFee, Math.min(this.maxFee, fee));

    // Lower confidence if we have limited data
    if (analysis.tickHistory.length < 30) confidence -= 20;
    confidence = Math.max(0, Math.min(100, confidence));

    return { fee, confidence };
  }
}
