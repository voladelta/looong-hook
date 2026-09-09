import { parseAbi, type PublicClient } from "viem";

import type { DeploymentManifest, Market } from "./types.js";

const hookAbi = parseAbi([
  "function nextPositionId() view returns (uint256)",
  "function totalCustodiedTokens(bytes32 poolId) view returns (uint256)",
  "function accountedWethClaims() view returns (uint256)",
  "function accountingLiabilityScaled() view returns (uint256)",
  "function positionPools(uint256 positionId) view returns (bytes32)",
  "function custodyIsSolvent(bytes32 poolId) view returns (bool)",
  "function claimsAreConserved() view returns (bool)",
  "function positions(uint256) view returns (address owner, uint64 openedAt, bool rewardActive, uint128 initialTokens, uint128 remainingTokens, uint128 soldTokens, uint128 withdrawnTokens, uint256 initialBasis, uint256 remainingBasis, uint256 soldBasis, uint256 withdrawnBasis, uint256 profitRemainder)",
]);
const erc20Abi = parseAbi(["function balanceOf(address owner) view returns (uint256)"]);
const managerAbi = parseAbi(["function balanceOf(address owner, uint256 id) view returns (uint256)"]);

interface MarketVerification extends Market {
  positionCount: number;
  totalCustodiedTokens: string;
  custodyIsSolvent: boolean;
}

export interface ProductVerification {
  expectedPositions: number;
  nextPositionId: string;
  totalCustodiedTokens: string;
  accountedWethClaims: string;
  actualWethClaims: string;
  custodyIsSolvent: boolean;
  claimsAreConserved: boolean;
  positionOwnersVerified: number;
  markets: MarketVerification[];
}

export async function verifyProduct(
  publicClient: PublicClient,
  manifest: DeploymentManifest,
  trades: { address: string; market: Market; positionId: string }[],
  markets: Market[],
  firstPositionId: bigint,
): Promise<ProductVerification> {
  const [nextPositionId, accountedWethClaims, liabilityScaled, actualWethClaims, claimsAreConserved] =
    await Promise.all([
      publicClient.readContract({ address: manifest.contracts.hook, abi: hookAbi, functionName: "nextPositionId" }),
      publicClient.readContract({
        address: manifest.contracts.hook,
        abi: hookAbi,
        functionName: "accountedWethClaims",
      }),
      publicClient.readContract({
        address: manifest.contracts.hook,
        abi: hookAbi,
        functionName: "accountingLiabilityScaled",
      }),
      publicClient.readContract({
        address: manifest.contracts.poolManager,
        abi: managerAbi,
        functionName: "balanceOf",
        args: [manifest.contracts.hook, BigInt(manifest.contracts.weth)],
      }),
      publicClient.readContract({ address: manifest.contracts.hook, abi: hookAbi, functionName: "claimsAreConserved" }),
    ]);
  const expectedNextPositionId = firstPositionId + BigInt(trades.length);
  if (nextPositionId !== expectedNextPositionId) {
    throw new Error(`expected nextPositionId ${expectedNextPositionId}, received ${nextPositionId}`);
  }
  if (!claimsAreConserved || accountedWethClaims * 10n ** 27n !== liabilityScaled || actualWethClaims < accountedWethClaims) {
    throw new Error("WETH claims do not conserve backed protocol liabilities");
  }
  const expectedByOwner = new Map(trades.map((trade) => [trade.address.toLowerCase(), trade.market]));
  const seenPositionIds = new Set<string>();
  const positions = await Promise.all(
    trades.map(async (trade) => {
      const id = BigInt(trade.positionId);
      if (id < firstPositionId || id >= expectedNextPositionId || seenPositionIds.has(trade.positionId)) {
        throw new Error(`position event returned an invalid or repeated id: ${trade.positionId}`);
      }
      seenPositionIds.add(trade.positionId);
      const [position, poolId] = await Promise.all([
        publicClient.readContract({ address: manifest.contracts.hook, abi: hookAbi, functionName: "positions", args: [id] }),
        publicClient.readContract({ address: manifest.contracts.hook, abi: hookAbi, functionName: "positionPools", args: [id] }),
      ]);
      const owner = position[0].toLowerCase();
      if (
        owner !== trade.address.toLowerCase()
        || trade.market.poolId.toLowerCase() !== poolId.toLowerCase()
      ) {
        throw new Error(`position ${id} is assigned to the wrong trader or pool`);
      }
      if (position[4] === 0n || position[3] !== position[4] || position[7] !== position[8]) {
        throw new Error(`position ${id} does not preserve its new token and basis balances`);
      }
      return { owner, poolId, tokens: position[4] };
    }),
  );
  if (seenPositionIds.size !== trades.length) throw new Error("position events do not cover every successful trade");
  const actualOwners = new Set(positions.map((position) => position.owner));
  if (actualOwners.size !== expectedByOwner.size || [...expectedByOwner.keys()].some((owner) => !actualOwners.has(owner))) {
    throw new Error("position owners do not match the successful trader set");
  }
  const marketVerification = await Promise.all(markets.map(async (market) => {
    const [totalCustodiedTokens, actualTokens, custodyIsSolvent] = await Promise.all([
      publicClient.readContract({
        address: manifest.contracts.hook, abi: hookAbi, functionName: "totalCustodiedTokens", args: [market.poolId],
      }),
      publicClient.readContract({
        address: market.subject, abi: erc20Abi, functionName: "balanceOf", args: [manifest.contracts.hook],
      }),
      publicClient.readContract({
        address: manifest.contracts.hook, abi: hookAbi, functionName: "custodyIsSolvent", args: [market.poolId],
      }),
    ]);
    const poolPositions = positions.filter((position) => position.poolId.toLowerCase() === market.poolId.toLowerCase());
    const expectedCustody = poolPositions.reduce((total, position) => total + position.tokens, 0n);
    if (!custodyIsSolvent || totalCustodiedTokens !== expectedCustody || actualTokens !== expectedCustody) {
      throw new Error(`subject custody does not match the positions in pool ${market.poolId}`);
    }
    if (trades.length >= markets.length && poolPositions.length === 0) throw new Error(`market ${market.poolId} was not exercised`);
    return { ...market, positionCount: poolPositions.length, totalCustodiedTokens: totalCustodiedTokens.toString(), custodyIsSolvent };
  }));
  return {
    expectedPositions: trades.length,
    nextPositionId: nextPositionId.toString(),
    totalCustodiedTokens: marketVerification.reduce((total, market) => total + BigInt(market.totalCustodiedTokens), 0n).toString(),
    accountedWethClaims: accountedWethClaims.toString(),
    actualWethClaims: actualWethClaims.toString(),
    custodyIsSolvent: marketVerification.every((market) => market.custodyIsSolvent),
    claimsAreConserved,
    positionOwnersVerified: actualOwners.size,
    markets: marketVerification,
  };
}
