import { describe, it, expect } from "vitest";
import { LimitOrderMonitor } from "../src/engine/LimitOrderMonitor.js";
import { OrderType, type LimitOrder } from "@ghostbot/sdk";

const makeOrder = (overrides: Partial<LimitOrder> = {}): LimitOrder => ({
  owner: "0x0000000000000000000000000000000000000001",
  zeroForOne: true,
  triggerTick: 100,
  amountIn: 1000n,
  amountOutMin: 900n,
  orderType: OrderType.STOP_LOSS,
  linkedPositionId: 0n,
  executed: false,
  cancelled: false,
  ...overrides,
});

describe("LimitOrderMonitor", () => {
  const monitor = new LimitOrderMonitor();

  it("triggers zeroForOne order when tick <= triggerTick", () => {
    const orders = new Map<bigint, LimitOrder>([
      [1n, makeOrder({ zeroForOne: true, triggerTick: 100 })],
    ]);
    const triggered = monitor.checkOrders(orders, 90);
    expect(triggered).toHaveLength(1);
    expect(triggered[0].orderId).toBe(1n);
  });

  it("triggers zeroForOne order when tick == triggerTick", () => {
    const orders = new Map<bigint, LimitOrder>([
      [1n, makeOrder({ zeroForOne: true, triggerTick: 100 })],
    ]);
    const triggered = monitor.checkOrders(orders, 100);
    expect(triggered).toHaveLength(1);
  });

  it("does not trigger zeroForOne order when tick > triggerTick", () => {
    const orders = new Map<bigint, LimitOrder>([
      [1n, makeOrder({ zeroForOne: true, triggerTick: 100 })],
    ]);
    const triggered = monitor.checkOrders(orders, 110);
    expect(triggered).toHaveLength(0);
  });

  it("triggers oneForZero order when tick >= triggerTick", () => {
    const orders = new Map<bigint, LimitOrder>([
      [2n, makeOrder({ zeroForOne: false, triggerTick: 200 })],
    ]);
    const triggered = monitor.checkOrders(orders, 210);
    expect(triggered).toHaveLength(1);
  });

  it("does not trigger oneForZero order when tick < triggerTick", () => {
    const orders = new Map<bigint, LimitOrder>([
      [2n, makeOrder({ zeroForOne: false, triggerTick: 200 })],
    ]);
    const triggered = monitor.checkOrders(orders, 190);
    expect(triggered).toHaveLength(0);
  });

  it("skips executed orders", () => {
    const orders = new Map<bigint, LimitOrder>([
      [1n, makeOrder({ triggerTick: 100, executed: true })],
    ]);
    const triggered = monitor.checkOrders(orders, 50);
    expect(triggered).toHaveLength(0);
  });

  it("skips cancelled orders", () => {
    const orders = new Map<bigint, LimitOrder>([
      [1n, makeOrder({ triggerTick: 100, cancelled: true })],
    ]);
    const triggered = monitor.checkOrders(orders, 50);
    expect(triggered).toHaveLength(0);
  });

  it("handles empty order map", () => {
    const triggered = monitor.checkOrders(new Map(), 100);
    expect(triggered).toHaveLength(0);
  });

  it("triggers multiple orders at once", () => {
    const orders = new Map<bigint, LimitOrder>([
      [1n, makeOrder({ zeroForOne: true, triggerTick: 100 })],
      [2n, makeOrder({ zeroForOne: true, triggerTick: 150 })],
      [3n, makeOrder({ zeroForOne: false, triggerTick: 50 })],
    ]);
    // tick=80: triggers #1 (80 <= 100), not #2 (80 < 150 but yes!), triggers #3 (80 >= 50)
    const triggered = monitor.checkOrders(orders, 80);
    expect(triggered).toHaveLength(3);
  });
});
