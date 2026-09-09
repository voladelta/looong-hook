import assert from "node:assert/strict";
import { test } from "node:test";
import { encodeAbiParameters, encodeEventTopics, keccak256, type Address, type PublicClient, type TransactionReceipt } from "viem";
import { launchedMarketHint, marketOpenedAbi, marketStorageKey, maxMarketHints, openedPositionId, positionOpenedAbi, preparePositionAction, prioritizeMarketHints, readMarketHints, requirePositionMarket, resolveMarket, type MarketScope } from "./src/markets";

const address = (n: number) => `0x${n.toString(16).padStart(40, "0")}` as Address;
const scope: MarketScope = {
  chainId: 31337,
  contracts: { hook: address(1), coordinator: address(2), router: address(3), weth: address(4) },
};
const first = address(10);
const second = address(11);
const poolId = (subject: Address) => keccak256(encodeAbiParameters(
  [{ type: "address" }, { type: "address" }, { type: "uint24" }, { type: "int24" }, { type: "address" }],
  [scope.contracts.weth, subject, 3000, 60, scope.contracts.hook],
));

// Substitute the RPC boundary. The production resolver owns all identity checks.
function rpc(overrides: { chainId?: number; live?: boolean; hook?: Address; positionSubject?: Address } = {}): PublicClient {
  return {
    getChainId: async () => overrides.chainId ?? scope.chainId,
    readContract: async ({ functionName, args }: { functionName: string; args?: unknown[] }) => {
      switch (functionName) {
        case "hook": return overrides.hook ?? scope.contracts.hook;
        case "poolKey": return {
          currency0: scope.contracts.weth,
          currency1: args![0],
          fee: 3000,
          tickSpacing: 60,
          hooks: scope.contracts.hook,
        };
        case "poolIsLive": return overrides.live ?? true;
        case "decimals": return 6;
        case "positionPools": return poolId(overrides.positionSubject ?? first);
        default: throw new Error(`Unexpected read ${functionName}`);
      }
    },
  } as unknown as PublicClient;
}

test("reload preserves two subject hints and the selected market, scoped by chain, root and coordinator", async () => {
  const storage = new Map<string, string>();
  storage.set(marketStorageKey(scope), JSON.stringify({ subjects: [first, second], selected: second }));
  const restored = readMarketHints(storage.get(marketStorageKey(scope))!);

  assert.deepEqual(restored.subjects, [first, second]);
  assert.equal((await resolveMarket(rpc(), scope, restored.selected!)).poolId, poolId(second));
  assert.equal((await resolveMarket(rpc(), scope, restored.subjects[0])).poolId, poolId(first));

  for (const other of [
    { ...scope, chainId: 1 },
    { ...scope, contracts: { ...scope.contracts, hook: address(20) } },
    { ...scope, contracts: { ...scope.contracts, coordinator: address(20) } },
  ]) {
    assert.equal(storage.get(marketStorageKey(other)), undefined);
  }
});

test("malformed storage and forged pool identity cannot supply market authority", async () => {
  for (const raw of ["{", "null", "[]", '{"subjects":{}}']) {
    assert.deepEqual(readMarketHints(raw), { subjects: [] });
  }
  const hints = readMarketHints(JSON.stringify({ subjects: [first, first, null, "bad"], selected: second, poolId: poolId(second), decimals: 255 }));
  assert.deepEqual(hints, { subjects: [first], selected: undefined });
  const manyHints = readMarketHints(JSON.stringify({
    subjects: Array.from({ length: maxMarketHints + 10 }, (_, index) => address(index + 100)),
  }));
  assert.equal(manyHints.subjects.length, maxMarketHints);
  const market = await resolveMarket(rpc(), scope, hints.subjects[0]);

  assert.equal(market.poolId, poolId(first));
  assert.equal(market.decimals, 6);
  await assert.rejects(resolveMarket(rpc(), scope, "bad"), /valid subject/);
  await assert.rejects(resolveMarket(rpc({ live: false }), scope, first), /registered, live market/);
  await assert.rejects(resolveMarket(rpc({ chainId: 1 }), scope, first), /wrong chain/);
  await assert.rejects(resolveMarket(rpc({ hook: address(99) }), scope, first), /does not own/);
});

test("the selected market stays first within the bounded hint list", () => {
  const selected = address(999);
  const hints = prioritizeMarketHints(
    Array.from({ length: maxMarketHints + 10 }, (_, index) => address(index + 100)),
    selected,
  );

  assert.equal(hints.length, maxMarketHints);
  assert.equal(hints[0], selected);
  assert.equal(new Set(hints).size, maxMarketHints);
  assert.deepEqual(prioritizeMarketHints([first, second, first], second), [second, first]);
});

test("a position from the first market cannot be sold with the second market selected", async () => {
  const firstMarket = await resolveMarket(rpc(), scope, first);
  const secondMarket = await resolveMarket(rpc(), scope, second);
  let walletCalls = 0;
  const connectWallet = async () => {
    walletCalls += 1;
    return "wallet";
  };

  await assert.rejects(
    preparePositionAction(rpc(), scope, 1n, secondMarket, connectWallet),
    /Select its subject-token market/,
  );
  assert.equal(walletCalls, 0);
  assert.equal(await preparePositionAction(rpc(), scope, 1n, firstMarket, connectWallet), "wallet");
  assert.equal(walletCalls, 1);
  assert.equal((await requirePositionMarket(rpc(), scope, 1n, firstMarket)).subject, first);
  await assert.rejects(requirePositionMarket(rpc({ live: false }), scope, 1n, firstMarket), /registered, live market/);
});

test("launch confirmation rejects reverted receipts, other emitters and mismatched launch fields", () => {
  const expected = {
    coordinator: scope.contracts.coordinator,
    subject: second,
    creator: address(50),
    feeBeneficiary: address(50),
    sqrtPriceX96: 2n ** 96n,
  };
  const log = {
    address: expected.coordinator,
    topics: encodeEventTopics({
      abi: marketOpenedAbi,
      eventName: "LooongMarketOpened",
      args: { subject: second, poolId: poolId(second), creator: expected.creator },
    }),
    data: encodeAbiParameters(
      [{ type: "address" }, { type: "uint160" }, { type: "int24" }, { type: "int24" }, { type: "uint256" }],
      [expected.feeBeneficiary, expected.sqrtPriceX96, 0, 207000, 100n],
    ),
  } as TransactionReceipt["logs"][number];
  const receipt = { status: "success" as const, logs: [log] };

  assert.deepEqual(launchedMarketHint(receipt, expected), { subject: second, poolId: poolId(second) });
  assert.throws(() => launchedMarketHint({ ...receipt, status: "reverted" }, expected), /reverted/);
  assert.throws(() => launchedMarketHint({ ...receipt, logs: [{ ...log, address: address(99) }] }, expected), /expected coordinator/);
  for (const changed of [
    { ...expected, subject: first },
    { ...expected, creator: address(99) },
    { ...expected, feeBeneficiary: address(99) },
    { ...expected, sqrtPriceX96: 1n },
  ]) {
    assert.throws(() => launchedMarketHint(receipt, changed), /expected coordinator/);
  }
});

test("buy confirmation binds the position event to the hook, selected pool and buyer", () => {
  const owner = address(50);
  const expectedPoolId = poolId(second);
  const log = {
    address: scope.contracts.hook,
    topics: encodeEventTopics({
      abi: positionOpenedAbi,
      eventName: "PositionOpened",
      args: { poolId: expectedPoolId, positionId: 7n, owner },
    }),
    data: encodeAbiParameters(
      [{ type: "uint256" }, { type: "uint256" }],
      [100n, 10n],
    ),
  } as TransactionReceipt["logs"][number];
  const receipt = { status: "success" as const, logs: [log] };
  const expected = { hook: scope.contracts.hook, poolId: expectedPoolId, owner };

  assert.equal(openedPositionId(receipt, expected), 7n);
  assert.throws(() => openedPositionId({ ...receipt, status: "reverted" }, expected), /reverted/);
  assert.throws(() => openedPositionId({ ...receipt, logs: [{ ...log, address: address(99) }] }, expected), /expected hook/);
  assert.throws(() => openedPositionId(receipt, { ...expected, poolId: poolId(first) }), /expected hook/);
  assert.throws(() => openedPositionId(receipt, { ...expected, owner: address(99) }), /expected hook/);
  assert.throws(() => openedPositionId({ ...receipt, logs: [log, log] }, expected), /expected hook/);
});
