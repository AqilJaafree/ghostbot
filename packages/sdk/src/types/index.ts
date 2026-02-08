export enum OrderType {
  STOP_LOSS = 0,
  TAKE_PROFIT = 1,
  TRAILING_STOP = 2,
}

export interface Position {
  owner: `0x${string}`;
  tickLower: number;
  tickUpper: number;
  liquidity: bigint;
  autoRebalance: boolean;
  lastRebalanceTime: bigint;
  salt: `0x${string}`;
}

export interface LimitOrder {
  owner: `0x${string}`;
  zeroForOne: boolean;
  triggerTick: number;
  amountIn: bigint;
  amountOutMin: bigint;
  orderType: OrderType;
  linkedPositionId: bigint;
  executed: boolean;
  cancelled: boolean;
  claimCurrency: `0x${string}`;
  claimAmount: bigint;
}

export interface PoolStats {
  cumulativeVolume: bigint;
  lastVolumeUpdate: bigint;
  volatility: bigint;
  currentFee: number;
  lastTick: number;
}

export interface RebalanceSignal {
  positionId: bigint;
  newTickLower: number;
  newTickUpper: number;
  confidence: number;
  timestamp: bigint;
}

export interface FeeRecommendation {
  fee: number;
  confidence: number;
  timestamp: bigint;
}
