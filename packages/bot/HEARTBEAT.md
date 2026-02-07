# GhostBot ACLM Heartbeat

## Cycle: 60 seconds

1. **Fetch pool state** - Read current tick, sqrtPrice, liquidity from PoolManager
2. **Analyze market** - Compute realized volatility, 24h volume, trend detection
3. **Compute signals** - Calculate optimal ranges and fee recommendations
4. **Post to oracle** - Send rebalance signals and fee recommendations on-chain
5. **Monitor orders** - Check limit order trigger conditions
6. **Log metrics** - Record cycle stats for monitoring
