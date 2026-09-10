import { encodeAbiParameters, isAddress, keccak256, parseAbi, parseEventLogs, type Address, type Hex, type PublicClient, type TransactionReceipt } from "viem";

export interface Market {
  subject: Address;
  poolId: Hex;
  decimals: number;
}

export interface MarketScope {
  chainId: number;
  contracts: { hook: Address; coordinator: Address; router: Address; weth: Address };
}

export const maxMarketHints = 100;

export function prioritizeMarketHints(subjects: Iterable<Address>, selected: Address): Address[] {
  const selectedSubject = selected.toLowerCase() as Address;
  return [...new Set([selectedSubject, ...[...subjects].map((subject) => subject.toLowerCase() as Address)])]
    .slice(0, maxMarketHints);
}

const abi = parseAbi([
  "function hook() view returns (address)",
  "function poolKey(address subject) view returns ((address currency0,address currency1,uint24 fee,int24 tickSpacing,address hooks))",
  "function poolIsLive(bytes32 poolId) view returns (bool)",
  "function positionPools(uint256 positionId) view returns (bytes32)",
  "function decimals() view returns (uint8)",
]);

export const marketOpenedAbi = parseAbi([
  "event LooongMarketOpened(address indexed subject, bytes32 indexed poolId, address indexed creator, address feeBeneficiary, uint160 sqrtPriceX96, int24 tickLower, int24 tickUpper, uint256 subjectUsed)",
]);

export const positionOpenedAbi = parseAbi([
  "event PositionOpened(bytes32 indexed poolId, uint256 indexed positionId, address indexed owner, uint256 tokens, uint256 wethBasis)",
]);

export function launchedMarketHint(
  receipt: Pick<TransactionReceipt, "status" | "logs">,
  expected: { coordinator: Address; subject: Address; creator: Address; feeBeneficiary: Address; sqrtPriceX96: bigint },
): { subject: Address; poolId: Hex } {
  if (receipt.status !== "success") throw new Error("The token launch reverted.");
  const launched = parseEventLogs({ abi: marketOpenedAbi, logs: receipt.logs, eventName: "LooongMarketOpened" }).find(
    (event) => event.address.toLowerCase() === expected.coordinator.toLowerCase()
      && event.args.subject.toLowerCase() === expected.subject.toLowerCase()
      && event.args.creator.toLowerCase() === expected.creator.toLowerCase()
      && event.args.feeBeneficiary.toLowerCase() === expected.feeBeneficiary.toLowerCase()
      && event.args.sqrtPriceX96 === expected.sqrtPriceX96
      && event.args.tickLower < event.args.tickUpper
      && event.args.subjectUsed > 0n,
  );
  if (!launched) throw new Error("The launch receipt did not contain the expected coordinator market event.");
  return { subject: launched.args.subject, poolId: launched.args.poolId };
}

export function openedPositionId(
  receipt: Pick<TransactionReceipt, "status" | "logs">,
  expected: { hook: Address; poolId: Hex; owner: Address },
): bigint {
  if (receipt.status !== "success") throw new Error("The verified buy reverted.");
  const opened = parseEventLogs({ abi: positionOpenedAbi, logs: receipt.logs, eventName: "PositionOpened" }).filter(
    (event) => event.address.toLowerCase() === expected.hook.toLowerCase()
      && event.args.poolId.toLowerCase() === expected.poolId.toLowerCase()
      && event.args.owner.toLowerCase() === expected.owner.toLowerCase()
      && event.args.positionId > 0n
      && event.args.tokens > 0n
      && event.args.wethBasis > 0n,
  );
  if (opened.length !== 1) throw new Error("The buy receipt did not contain the expected hook position event.");
  return opened[0].args.positionId;
}

export function marketStorageKey(scope: MarketScope): string {
  return `looong:markets:v1:${scope.chainId}:${scope.contracts.hook.toLowerCase()}:${scope.contracts.coordinator.toLowerCase()}`;
}

// Storage contains discovery hints only. Each selected subject must pass resolveMarket.
export function readMarketHints(raw: string | null): { subjects: Address[]; selected?: Address } {
  try {
    const value = JSON.parse(raw ?? "null");
    if (!value || !Array.isArray(value.subjects)) return { subjects: [] };
    const subjects = [...new Set<string>(value.subjects.slice(0, maxMarketHints).filter(
      (subject: unknown): subject is string => typeof subject === "string" && isAddress(subject),
    ).map((subject: string) => subject.toLowerCase()))] as Address[];
    const selected = typeof value.selected === "string" && isAddress(value.selected)
      && subjects.includes(value.selected.toLowerCase()) ? value.selected.toLowerCase() as Address : undefined;
    return { subjects, selected };
  } catch {
    return { subjects: [] };
  }
}

export async function resolveMarket(client: PublicClient, scope: MarketScope, subject: string): Promise<Market> {
  if (!isAddress(subject)) throw new Error("Enter a valid subject-token address.");
  if (await client.getChainId() !== scope.chainId) throw new Error("The RPC is on the wrong chain.");

  const coordinatorHook = await client.readContract({ address: scope.contracts.coordinator, abi, functionName: "hook" });
  if (coordinatorHook.toLowerCase() !== scope.contracts.hook.toLowerCase()) {
    throw new Error("The coordinator does not own this root hook.");
  }
  const key = await client.readContract({ address: scope.contracts.router, abi, functionName: "poolKey", args: [subject] });
  const currencies = [key.currency0.toLowerCase(), key.currency1.toLowerCase()];
  if (key.hooks.toLowerCase() !== scope.contracts.hook.toLowerCase()
    || subject.toLowerCase() === scope.contracts.weth.toLowerCase()
    || !currencies.includes(subject.toLowerCase()) || !currencies.includes(scope.contracts.weth.toLowerCase())) {
    throw new Error("The router returned a different market.");
  }
  const poolId = keccak256(encodeAbiParameters(
    [{ type: "address" }, { type: "address" }, { type: "uint24" }, { type: "int24" }, { type: "address" }],
    [key.currency0, key.currency1, key.fee, key.tickSpacing, key.hooks],
  ));
  const live = await client.readContract({ address: scope.contracts.hook, abi, functionName: "poolIsLive", args: [poolId] });
  if (!live) throw new Error("This subject has no registered, live market on this root hook.");
  const decimals = await client.readContract({ address: subject, abi, functionName: "decimals" });
  return { subject, poolId, decimals };
}

export async function requirePositionMarket(client: PublicClient, scope: MarketScope, positionId: bigint, selected: Market): Promise<Market> {
  const market = await resolveMarket(client, scope, selected.subject);
  const poolId = await client.readContract({ address: scope.contracts.hook, abi, functionName: "positionPools", args: [positionId] });
  if (poolId.toLowerCase() !== market.poolId.toLowerCase()) {
    throw new Error(`Position ${positionId} belongs to pool ${poolId}. Select its subject-token market before managing this position.`);
  }
  return market;
}

export async function preparePositionAction<T>(
  client: PublicClient,
  scope: MarketScope,
  positionId: bigint,
  selected: Market,
  afterAuthority: () => Promise<T>,
): Promise<T> {
  await requirePositionMarket(client, scope, positionId, selected);
  return afterAuthority();
}
