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
  market: Market;
  publicClient: PublicClient;
}

export interface Market {
  subject: Address;
  poolId: Hex;
}

export interface PreparedTrade {
  to: Address;
  data: Hex;
  value?: bigint;
  gas?: bigint;
}
