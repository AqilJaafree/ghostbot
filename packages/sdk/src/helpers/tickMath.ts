// Tick <-> Price conversion utilities
// Based on Uniswap v3/v4 tick math

export const MIN_TICK = -887272;
export const MAX_TICK = 887272;
export const MIN_SQRT_PRICE = 4295128739n;
export const MAX_SQRT_PRICE = 1461446703485210103287273052203988822378723970342n;

export function tickToPrice(tick: number): number {
  return Math.pow(1.0001, tick);
}

export function priceToTick(price: number): number {
  return Math.round(Math.log(price) / Math.log(1.0001));
}

export function snapToTickSpacing(tick: number, tickSpacing: number): number {
  let compressed = Math.floor(tick / tickSpacing);
  if (tick < 0 && tick % tickSpacing !== 0) compressed--;
  return compressed * tickSpacing;
}

export function tickToSqrtPriceX96(tick: number): bigint {
  const price = Math.pow(1.0001, tick);
  const sqrtPrice = Math.sqrt(price);
  return BigInt(Math.floor(sqrtPrice * Number(2n ** 96n)));
}
