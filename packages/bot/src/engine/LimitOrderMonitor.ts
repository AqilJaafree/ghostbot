import type { LimitOrder } from "@ghostbot/sdk";

export interface TriggeredOrder {
  orderId: bigint;
  order: LimitOrder;
}

export class LimitOrderMonitor {
  checkOrders(
    orders: Map<bigint, LimitOrder>,
    currentTick: number
  ): TriggeredOrder[] {
    const triggered: TriggeredOrder[] = [];

    for (const [orderId, order] of orders) {
      if (order.executed || order.cancelled) continue;

      const shouldTrigger = order.zeroForOne
        ? currentTick <= order.triggerTick
        : currentTick >= order.triggerTick;

      if (shouldTrigger) {
        triggered.push({ orderId, order });
      }
    }

    return triggered;
  }
}
