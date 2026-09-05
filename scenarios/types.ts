import type { Address, Hex, LocalAccount, PublicClient } from "viem";

export interface DeploymentManifest {
  chainId: number;
  network: string;
  rpcUrl: string;
  pool: {
    fee: number;
    tickSpacing: number;
  };
  poolId: Hex;
  contracts: {
    hook: Address;
    poolManager: Address;
    router: Address;
    subject: Address;
    weth: Address;
    coordinator: Address;
    factory: Address;
  };
}

export interface TradeContext {
  account: LocalAccount;
  index: number;
  manifest: DeploymentManifest;
  publicClient: PublicClient;
}

export interface PreparedTrade {
  to: Address;
  data: Hex;
  value?: bigint;
  gas?: bigint;
}
