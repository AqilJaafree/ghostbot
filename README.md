# GhostBot: OpenClaw ACLM

AI-powered Automated Concentrated Liquidity Manager for Uniswap v4. Uses an off-chain bot (OpenClaw Skill) to analyze market conditions and post optimized liquidity signals to an on-chain oracle, which a custom hook reads during swap callbacks to rebalance positions and adjust fees dynamically.

## Architecture

```
Bot (TypeScript)  -->  Oracle (Solidity)  -->  Hook (Solidity)  -->  Uniswap v4 PoolManager
60s heartbeat          Data bridge              BaseCustomAccounting
MarketAnalyzer         Signal storage           ERC6909 shares
RangeOptimizer         TTL enforcement          Dynamic fees
FeeOptimizer           Access control           Auto-rebalance
DecisionAggregator                              Limit orders
```

## Deployed Contracts (Sepolia)

| Contract | Address |
|----------|---------|
| OpenClawACLMHook | [`0xbD2802B7215530894d5696ab8450115f56b1fAC0`](https://sepolia.etherscan.io/address/0xbD2802B7215530894d5696ab8450115f56b1fAC0) |
| OpenClawOracle | [`0x300Fa0Af86201A410bEBD511Ca7FB81548a0f027`](https://sepolia.etherscan.io/address/0x300Fa0Af86201A410bEBD511Ca7FB81548a0f027) |
| PoolManager | [`0xE03A1074c86CFeDd5C142C4F04F1a1536e203543`](https://sepolia.etherscan.io/address/0xE03A1074c86CFeDd5C142C4F04F1a1536e203543) |
| Token GBB (currency0) | [`0x07B55AfA83169093276898f789A27a4e2d511F36`](https://sepolia.etherscan.io/address/0x07B55AfA83169093276898f789A27a4e2d511F36) |
| Token GBA (currency1) | [`0xB960eD7FC078037608615a0b62a1a0295493f26E`](https://sepolia.etherscan.io/address/0xB960eD7FC078037608615a0b62a1a0295493f26E) |

**Pool Configuration:** tick 0 (1:1 price), tickSpacing=60, DYNAMIC_FEE (`0x800000`)

## Project Structure

```
packages/
  contracts/          Foundry project (Solidity 0.8.26, EVM Cancun)
    src/
      OpenClawACLMHook.sol    Main hook (BaseCustomAccounting)
      OpenClawOracle.sol      Oracle data bridge
      interfaces/             IOpenClawACLMHook, IOpenClawOracle
      libraries/              LiquidityAmounts
      types/                  DataTypes (Position, LimitOrder, PoolStats, etc.)
    test/                     33 tests across 4 suites
    script/                   Deploy.s.sol (CREATE2 salt mining)

  sdk/                TypeScript SDK
    src/
      abis/           Auto-generated ABIs from forge output
      types/          TypeScript mirrors of Solidity structs
      helpers/        encoding, tickMath, poolId
      constants/      Contract addresses per chain

  bot/                TypeScript bot (OpenClaw Skill)
    src/
      engine/         MarketAnalyzer, RangeOptimizer, FeeOptimizer, LimitOrderMonitor, DecisionAggregator
      oracle/         OracleWriter, OracleReader
      chain/          PoolStateReader, HookInteractor
    test/             35 tests across 5 suites
```

## Prerequisites

- Node.js >= 18
- pnpm >= 9
- Foundry (foundryup)

## Setup

```bash
git clone <repo-url> && cd ghostbot
pnpm install
```

## Build

```bash
# All contracts
pnpm run build:contracts

# Generate TypeScript ABIs from forge output
pnpm run generate:abis

# SDK
pnpm run build:sdk

# Bot
pnpm run build:bot
```

## Test

```bash
# Solidity tests (33 tests)
pnpm run test:contracts

# Bot unit tests (35 tests)
pnpm run test:bot
```

## Run Bot

```bash
cp .env.example .env
# Fill in: RPC_URL, BOT_PRIVATE_KEY, ORACLE_ADDRESS, HOOK_ADDRESS

pnpm run dev:bot
```

## Contract Deployment

```bash
cd packages/contracts
forge script script/Deploy.s.sol --rpc-url $RPC_URL --broadcast --verify
```

The deploy script mines a CREATE2 salt so the hook address encodes the required permission flag bits.

## How It Works

1. **Bot heartbeat** (every 60s): Fetches pool state, runs market analysis (volatility, trend), computes optimal tick ranges and fees.
2. **Oracle bridge**: Bot posts `RebalanceSignal` and `FeeRecommendation` to the on-chain oracle. Signals have a 5-minute TTL and confidence scores.
3. **Hook callbacks**: During swaps, `beforeSwap` reads the oracle for fee updates (applied if change > 10% and confidence meets threshold). `afterSwap` updates pool stats, checks limit orders, and triggers rebalances for eligible positions.
4. **Custom accounting**: The hook owns all liquidity via `BaseCustomAccounting`. Users receive ERC6909 share tokens representing their positions.

## Key Design Decisions

- **Confidence gating**: All oracle signals require a minimum confidence score (default 70) before the hook acts on them.
- **Rate limiting**: Bot enforces 60s between oracle writes. On-chain rebalances have a configurable cooldown.
- **Bounded iteration**: `MAX_REBALANCES_PER_SWAP = 5`, `MAX_ORDERS_PER_SWAP = 10` to cap gas per swap.
- **Signal TTL**: Oracle signals expire after 5 minutes to prevent stale data from affecting pool behavior.
- **Dynamic fees**: Applied via `poolManager.updateDynamicLPFee()`, only when the recommended fee differs by > 10% from current.

## Environment Variables

| Variable | Required | Description |
|----------|----------|-------------|
| `RPC_URL` | Yes | Base Sepolia RPC endpoint |
| `BOT_PRIVATE_KEY` | Yes | Bot wallet private key (hex) |
| `ORACLE_ADDRESS` | Yes | Deployed OpenClawOracle address |
| `HOOK_ADDRESS` | Yes | Deployed OpenClawACLMHook address |
| `POOL_MANAGER_ADDRESS` | No | Defaults to v4 canonical address |
| `HEARTBEAT_INTERVAL` | No | Milliseconds between cycles (default: 60000) |
| `MAX_GAS_PRICE` | No | Max gas price in gwei (default: 50) |

## Known Limitations

See [AUDIT.md](./AUDIT.md) for a full security audit. Key items:

- Rebalance updates storage ticks but does not yet call `modifyLiquidity` to move actual pool liquidity.
- Limit order execution marks orders as filled but does not perform the swap or implement a claim mechanism.
- These are architectural gaps that must be resolved before mainnet deployment.

## License

MIT
