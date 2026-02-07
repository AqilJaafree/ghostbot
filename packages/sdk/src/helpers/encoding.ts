import { encodeAbiParameters, decodeAbiParameters, type Hex } from "viem";

export function encodeHookData(autoRebalance: boolean): Hex {
  // salt bit 0 = autoRebalance preference
  const salt = autoRebalance ? 1n : 0n;
  return encodeAbiParameters([{ type: "bytes32" }], [`0x${salt.toString(16).padStart(64, "0")}`]);
}

export function decodeHookData(data: Hex): { autoRebalance: boolean } {
  const [salt] = decodeAbiParameters([{ type: "bytes32" }], data);
  return { autoRebalance: (BigInt(salt) & 1n) === 1n };
}

export function makeAutoRebalanceSalt(userSalt: bigint = 0n): Hex {
  const salt = (userSalt & ~1n) | 1n; // set bit 0
  return `0x${salt.toString(16).padStart(64, "0")}`;
}

export function makeManualSalt(userSalt: bigint = 0n): Hex {
  const salt = userSalt & ~1n; // clear bit 0
  return `0x${salt.toString(16).padStart(64, "0")}`;
}
