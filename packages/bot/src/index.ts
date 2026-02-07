import {
  createPublicClient,
  createWalletClient,
  http,
  type Hex,
  type PublicClient,
  type WalletClient,
} from "viem";
import { privateKeyToAccount } from "viem/accounts";
import { baseSepolia } from "viem/chains";

import { type PoolStats } from "@ghostbot/sdk";
import { loadConfig } from "./config.js";
import { MarketAnalyzer } from "./engine/MarketAnalyzer.js";
import { RangeOptimizer } from "./engine/RangeOptimizer.js";
import { FeeOptimizer } from "./engine/FeeOptimizer.js";
import { DecisionAggregator } from "./engine/DecisionAggregator.js";
import { OracleWriter } from "./oracle/OracleWriter.js";
import { OracleReader } from "./oracle/OracleReader.js";
import { PoolStateReader } from "./chain/PoolStateReader.js";
import { HookInteractor } from "./chain/HookInteractor.js";

async function main() {
  const config = loadConfig();
  const account = privateKeyToAccount(config.botPrivateKey);

  const publicClient = createPublicClient({
    chain: baseSepolia,
    transport: http(config.rpcUrl),
  }) as unknown as PublicClient;

  const walletClient = createWalletClient({
    account,
    chain: baseSepolia,
    transport: http(config.rpcUrl),
  }) as unknown as WalletClient;

  // Initialize components
  const marketAnalyzer = new MarketAnalyzer();
  const rangeOptimizer = new RangeOptimizer();
  const feeOptimizer = new FeeOptimizer();
  const decisionAggregator = new DecisionAggregator();

  const oracleWriter = new OracleWriter(walletClient, publicClient, config.oracleAddress);
  const oracleReader = new OracleReader(publicClient, config.oracleAddress);
  const poolStateReader = new PoolStateReader(publicClient, config.hookAddress, config.poolManagerAddress);
  const hookInteractor = new HookInteractor(publicClient, config.hookAddress);

  console.log(`GhostBot ACLM started`);
  console.log(`Bot address: ${account.address}`);
  console.log(`Oracle: ${config.oracleAddress}`);
  console.log(`Hook: ${config.hookAddress}`);

  // Main heartbeat loop
  const poolId = "0x0000000000000000000000000000000000000000000000000000000000000000" as Hex; // Set from env or config

  async function heartbeat() {
    try {
      console.log(`[${new Date().toISOString()}] Heartbeat cycle starting...`);

      // 1. Fetch pool state
      const poolStats = await poolStateReader.getPoolStats(poolId);

      // 2. Analyze market
      const analysis = marketAnalyzer.analyze(
        poolStats.lastTick,
        0n, // sqrtPriceX96 - would come from PoolManager slot0
        0n, // liquidity
        poolStats
      );

      // 3. Compute signals
      const rangeRec = rangeOptimizer.computeOptimalRange(analysis, 60);
      const feeRec = feeOptimizer.computeOptimalFee(analysis);

      // 4. Aggregate decisions
      const positionRanges = new Map<bigint, typeof rangeRec>();
      // In production, iterate actual positions from the hook
      positionRanges.set(1n, rangeRec);

      const decision = decisionAggregator.aggregate(positionRanges, feeRec, []);

      // 5. Post signals to oracle
      for (const signal of decision.rebalanceSignals) {
        try {
          const txHash = await oracleWriter.postRebalanceSignal(poolId, signal);
          console.log(`  Posted rebalance signal, tx: ${txHash}`);
        } catch (e) {
          console.error(`  Failed to post rebalance signal:`, e);
        }
      }

      if (decision.feeRecommendation) {
        try {
          const txHash = await oracleWriter.postFeeRecommendation(
            poolId,
            decision.feeRecommendation
          );
          console.log(`  Posted fee recommendation (${decision.feeRecommendation.fee}), tx: ${txHash}`);
        } catch (e) {
          console.error(`  Failed to post fee recommendation:`, e);
        }
      }

      console.log(`  Cycle complete. Vol=${analysis.volatility.toFixed(2)}, Trend=${analysis.trend}`);
    } catch (error) {
      console.error("Heartbeat error:", error);
    }
  }

  // Run first heartbeat immediately, then on interval
  await heartbeat();
  setInterval(heartbeat, config.heartbeatInterval);
}

main().catch(console.error);
