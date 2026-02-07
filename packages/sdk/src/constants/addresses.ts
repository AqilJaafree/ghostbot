export const POOL_MANAGER_ADDRESS = "0x000000000004444c5dc75cB358380D2e3dE08A90" as const;

// Deployed contract addresses per chain
export const ADDRESSES: Record<number, { oracle: `0x${string}`; hook: `0x${string}` }> = {
  // Base Sepolia
  84532: {
    oracle: "0x0000000000000000000000000000000000000000",
    hook: "0x0000000000000000000000000000000000000000",
  },
  // Unichain Sepolia
  1301: {
    oracle: "0x0000000000000000000000000000000000000000",
    hook: "0x0000000000000000000000000000000000000000",
  },
};
