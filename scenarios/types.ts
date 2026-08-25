import type { Address, Hex, LocalAccount, PublicClient } from "viem";

export interface DeploymentManifest {
  chainId: number;
  rpcUrl: string;
  contracts: {
    hook: Address;
    poolManager: Address;
    router: Address;
    token?: Address;
    nft?: Address;
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
