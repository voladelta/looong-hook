import {
  createWalletClient,
  encodeAbiParameters,
  http,
  keccak256,
  parseAbi,
  parseEventLogs,
  stringToHex,
  type Chain,
  type LocalAccount,
  type PublicClient,
} from "viem";

import type { DeploymentManifest, Market } from "./types.js";

const coordinatorAbi = parseAbi([
  "function previewTokenAddress((string name,string symbol,string tagline,string logoURI,address expectedCreator,address feeBeneficiary,bytes32 deploymentSalt,uint160 sqrtPriceX96) args) view returns (address predicted)",
  "function openTokenMarket((string name,string symbol,string tagline,string logoURI,address expectedCreator,address feeBeneficiary,bytes32 deploymentSalt,uint160 sqrtPriceX96) args,address expectedToken) returns (address subject,bytes32 poolId)",
  "event LooongMarketOpened(address indexed subject, bytes32 indexed poolId, address indexed creator, address feeBeneficiary, uint160 sqrtPriceX96, int24 tickLower, int24 tickUpper, uint256 subjectUsed)",
]);
const hookAbi = parseAbi(["function poolIsLive(bytes32 poolId) view returns (bool)"]);

export async function prepareMarkets(
  publicClient: PublicClient,
  chain: Chain,
  manifest: DeploymentManifest,
  creator: LocalAccount,
): Promise<Market[]> {
  const first = { subject: manifest.contracts.subject, poolId: manifest.poolId };
  const firstIsCurrency0 = BigInt(first.subject) < BigInt(manifest.contracts.weth);
  const args = {
    name: "LOOONG Devnet Two",
    symbol: "LONG2",
    tagline: "Second market on the shared LOOONG root",
    logoURI: "ipfs://looong-devnet-two",
    expectedCreator: creator.address,
    feeBeneficiary: creator.address,
    deploymentSalt: keccak256(stringToHex("LOOONG_DEVNET_TWO:0")),
    sqrtPriceX96: 2n ** 96n,
  };

  // Force the second currency ordering so both paths run in every devnet gate.
  for (let attempt = 0; attempt < 256; attempt++) {
    args.deploymentSalt = keccak256(stringToHex(`LOOONG_DEVNET_TWO:${attempt}`));
    const predicted = await publicClient.readContract({
      address: manifest.contracts.coordinator,
      abi: coordinatorAbi,
      functionName: "previewTokenAddress",
      args: [args],
    });
    if ((BigInt(predicted) < BigInt(manifest.contracts.weth)) === firstIsCurrency0) continue;

    const simulation = await publicClient.simulateContract({
      account: creator,
      address: manifest.contracts.coordinator,
      abi: coordinatorAbi,
      functionName: "openTokenMarket",
      args: [args, predicted],
      gas: 12_000_000n,
    });
    const wallet = createWalletClient({ account: creator, chain, transport: http(manifest.rpcUrl) });
    const hash = await wallet.writeContract(simulation.request);
    const receipt = await publicClient.waitForTransactionReceipt({ hash, timeout: 120_000 });
    if (receipt.status !== "success") throw new Error(`second market launch reverted: ${hash}`);
    const events = parseEventLogs({
      abi: coordinatorAbi,
      eventName: "LooongMarketOpened",
      logs: receipt.logs.filter((log) => log.address.toLowerCase() === manifest.contracts.coordinator.toLowerCase()),
    });
    const opened = events[0]?.args;
    if (
      events.length !== 1 || !opened || opened.subject.toLowerCase() !== predicted.toLowerCase()
      || opened.creator.toLowerCase() !== creator.address.toLowerCase()
      || opened.feeBeneficiary.toLowerCase() !== creator.address.toLowerCase()
      || opened.sqrtPriceX96 !== args.sqrtPriceX96
      || opened.tickLower >= opened.tickUpper
      || opened.subjectUsed === 0n
    ) throw new Error(`second market receipt does not match the prepared launch: ${hash}`);
    const second = { subject: opened.subject, poolId: opened.poolId };
    for (const market of [first, second]) {
      const currencies = BigInt(market.subject) < BigInt(manifest.contracts.weth)
        ? [market.subject, manifest.contracts.weth] as const
        : [manifest.contracts.weth, market.subject] as const;
      const expectedPoolId = keccak256(encodeAbiParameters(
        [{ type: "address" }, { type: "address" }, { type: "uint24" }, { type: "int24" }, { type: "address" }],
        [...currencies, manifest.pool.fee, manifest.pool.tickSpacing, manifest.contracts.hook],
      ));
      const live = await publicClient.readContract({
        address: manifest.contracts.hook, abi: hookAbi, functionName: "poolIsLive", args: [market.poolId],
      });
      if (expectedPoolId.toLowerCase() !== market.poolId.toLowerCase() || !live) {
        throw new Error(`market is not registered under the configured shared root: ${market.poolId}`);
      }
    }
    return [first, second];
  }
  throw new Error("could not prepare a second market with the opposite token ordering");
}
