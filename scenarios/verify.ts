import { parseAbi, type PublicClient } from "viem";

import type { DeploymentManifest } from "./types.js";

const hookAbi = parseAbi([
  "function nextPositionId() view returns (uint256)",
  "function totalCustodiedTokens() view returns (uint256)",
  "function accountedWethClaims() view returns (uint256)",
  "function custodyIsSolvent() view returns (bool)",
  "function claimsAreConserved() view returns (bool)",
  "function positions(uint256) view returns (address owner, uint64 openedAt, bool rewardActive, uint128 initialTokens, uint128 remainingTokens, uint128 soldTokens, uint128 withdrawnTokens, uint256 initialBasis, uint256 remainingBasis, uint256 soldBasis, uint256 withdrawnBasis, uint256 profitRemainder)",
]);

export interface ProductVerification {
  expectedPositions: number;
  nextPositionId: string;
  totalCustodiedTokens: string;
  accountedWethClaims: string;
  custodyIsSolvent: boolean;
  claimsAreConserved: boolean;
  positionOwnersVerified: number;
}

export async function verifyProduct(
  publicClient: PublicClient,
  manifest: DeploymentManifest,
  traderAddresses: string[],
): Promise<ProductVerification> {
  const [nextPositionId, totalCustodiedTokens, accountedWethClaims, custodyIsSolvent, claimsAreConserved] =
    await Promise.all([
      publicClient.readContract({ address: manifest.contracts.hook, abi: hookAbi, functionName: "nextPositionId" }),
      publicClient.readContract({
        address: manifest.contracts.hook,
        abi: hookAbi,
        functionName: "totalCustodiedTokens",
      }),
      publicClient.readContract({
        address: manifest.contracts.hook,
        abi: hookAbi,
        functionName: "accountedWethClaims",
      }),
      publicClient.readContract({ address: manifest.contracts.hook, abi: hookAbi, functionName: "custodyIsSolvent" }),
      publicClient.readContract({ address: manifest.contracts.hook, abi: hookAbi, functionName: "claimsAreConserved" }),
    ]);
  const expectedNextPositionId = BigInt(traderAddresses.length + 1);
  if (nextPositionId !== expectedNextPositionId) {
    throw new Error(`expected nextPositionId ${expectedNextPositionId}, received ${nextPositionId}`);
  }
  if (totalCustodiedTokens === 0n) throw new Error("verified buys did not create custodied LOOONG");
  if (!custodyIsSolvent) throw new Error("LOOONG custody is insolvent");
  if (!claimsAreConserved) throw new Error("WETH claims do not match liabilities");
  const positionOwners = await Promise.all(
    traderAddresses.map(async (_, index) => {
      const position = await publicClient.readContract({
        address: manifest.contracts.hook,
        abi: hookAbi,
        functionName: "positions",
        args: [BigInt(index + 1)],
      });
      return position[0].toLowerCase();
    }),
  );
  const expectedOwners = new Set(traderAddresses.map((address) => address.toLowerCase()));
  const actualOwners = new Set(positionOwners);
  if (actualOwners.size !== expectedOwners.size || [...expectedOwners].some((owner) => !actualOwners.has(owner))) {
    throw new Error("position owners do not match the successful trader set");
  }
  return {
    expectedPositions: traderAddresses.length,
    nextPositionId: nextPositionId.toString(),
    totalCustodiedTokens: totalCustodiedTokens.toString(),
    accountedWethClaims: accountedWethClaims.toString(),
    custodyIsSolvent,
    claimsAreConserved,
    positionOwnersVerified: actualOwners.size,
  };
}
