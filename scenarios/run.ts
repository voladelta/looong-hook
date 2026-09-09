import { mkdir, readFile, writeFile } from "node:fs/promises";
import { resolve } from "node:path";

import { createPublicClient, createWalletClient, defineChain, http, parseAbi, parseEventLogs } from "viem";
import { mnemonicToAccount } from "viem/accounts";

import { prepareTrade } from "./trade.js";
import { prepareMarkets } from "./markets.js";
import type { DeploymentManifest, Market } from "./types.js";
import { verifyProduct } from "./verify.js";

const root = resolve(import.meta.dirname, "..");
const manifestPath = resolve(root, ".devnet/deployment.json");
const reportPath = resolve(root, "reports/devnet.json");
const mnemonic =
  process.env.DEVNET_MNEMONIC ??
  "test test test test test test test test test test test junk";
const traderCount = Number(process.env.TRADER_COUNT ?? "100");
const concurrency = Number(process.env.TRADER_CONCURRENCY ?? "10");
const defaultGasLimit = BigInt(process.env.TRADER_GAS_LIMIT ?? "1000000");

if (!Number.isInteger(traderCount) || traderCount < 1 || traderCount > 100) {
  throw new Error("TRADER_COUNT must be an integer from 1 to 100");
}
if (!Number.isInteger(concurrency) || concurrency < 1 || concurrency > traderCount) {
  throw new Error("TRADER_CONCURRENCY must be between 1 and TRADER_COUNT");
}
if (defaultGasLimit < 21_000n) {
  throw new Error("TRADER_GAS_LIMIT must be at least 21000");
}

const manifest = JSON.parse(await readFile(manifestPath, "utf8")) as DeploymentManifest;
const chain = defineChain({
  id: manifest.chainId,
  name: "LOOONG devnet",
  nativeCurrency: { name: "Dev Ether", symbol: "dETH", decimals: 18 },
  rpcUrls: { default: { http: [manifest.rpcUrl] } },
});
const publicClient = createPublicClient({ chain, transport: http(manifest.rpcUrl) });
const positionOpenedAbi = parseAbi([
  "event PositionOpened(bytes32 indexed poolId, uint256 indexed positionId, address indexed owner, uint256 tokens, uint256 wethBasis)",
]);

if (await publicClient.getChainId() !== manifest.chainId) {
  throw new Error("deployment manifest chainId does not match the devnet");
}

const markets = await prepareMarkets(publicClient, chain, manifest, mnemonicToAccount(mnemonic));
const firstPositionId = await publicClient.readContract({
  address: manifest.contracts.hook,
  abi: parseAbi(["function nextPositionId() view returns (uint256)"]),
  functionName: "nextPositionId",
});

interface SuccessfulTransaction {
  index: number;
  address: string;
  hash: string;
  positionId: string;
  gasLimit: string;
  gasUsed: string;
  market: Market;
}

interface FailedTransaction {
  index: number;
  address: string;
  stage: "prepare" | "preflight" | "send" | "receipt";
  error: string;
  to?: string;
  selector?: string;
  value?: string;
  gasLimit?: string;
  gasUsed?: string;
  hash?: string;
  replayError?: string;
}

const results: SuccessfulTransaction[] = [];
const failures: FailedTransaction[] = [];
let nextIndex = 0;

function describeError(error: unknown): string {
  return error instanceof Error ? error.message : String(error);
}

async function worker(): Promise<void> {
  while (true) {
    const index = nextIndex++;
    if (index >= traderCount) return;

    const account = mnemonicToAccount(mnemonic, { addressIndex: index });
    const walletClient = createWalletClient({ account, chain, transport: http(manifest.rpcUrl) });
    const market = markets[index % markets.length];
    let trade;
    try {
      trade = await prepareTrade({ account, index, manifest, market, publicClient });
    } catch (error) {
      failures.push({ index, address: account.address, stage: "prepare", error: describeError(error) });
      continue;
    }

    const value = trade.value ?? 0n;
    const gasLimit = trade.gas ?? defaultGasLimit;
    if (gasLimit < 21_000n) {
      failures.push({
        index,
        address: account.address,
        stage: "prepare",
        error: "prepared trade gas limit must be at least 21000",
      });
      continue;
    }
    const context = {
      index,
      address: account.address,
      to: trade.to,
      selector: trade.data.slice(0, 10),
      value: value.toString(),
      gasLimit: gasLimit.toString(),
    };
    try {
      await publicClient.call({ account: account.address, to: trade.to, data: trade.data, value, gas: gasLimit });
    } catch (error) {
      failures.push({ ...context, stage: "preflight", error: describeError(error) });
      continue;
    }

    let hash;
    try {
      hash = await walletClient.sendTransaction({
        account,
        chain,
        to: trade.to,
        data: trade.data,
        value,
        gas: gasLimit,
      });
    } catch (error) {
      failures.push({ ...context, stage: "send", error: describeError(error) });
      continue;
    }

    let receipt;
    try {
      receipt = await publicClient.waitForTransactionReceipt({ hash });
    } catch (error) {
      failures.push({ ...context, hash, stage: "receipt", error: describeError(error) });
      continue;
    }
    if (receipt.status !== "success") {
      let replayError = "post-receipt eth_call succeeded";
      try {
        await publicClient.call({ account: account.address, to: trade.to, data: trade.data, value, gas: gasLimit });
      } catch (error) {
        replayError = describeError(error);
      }
      failures.push({
        ...context,
        hash,
        gasUsed: receipt.gasUsed.toString(),
        stage: "receipt",
        error: "transaction was mined but reverted",
        replayError,
      });
      continue;
    }

    const opened = parseEventLogs({
      abi: positionOpenedAbi,
      eventName: "PositionOpened",
      logs: receipt.logs.filter((log) => log.address.toLowerCase() === manifest.contracts.hook.toLowerCase()),
    });
    if (
      opened.length !== 1
      || opened[0].args.owner.toLowerCase() !== account.address.toLowerCase()
      || opened[0].args.poolId.toLowerCase() !== market.poolId.toLowerCase()
      || opened[0].args.positionId === 0n
      || opened[0].args.tokens === 0n
      || opened[0].args.wethBasis === 0n
    ) {
      failures.push({
        ...context,
        hash,
        gasUsed: receipt.gasUsed.toString(),
        stage: "receipt",
        error: "receipt did not contain the expected hook position event",
      });
      continue;
    }

    results.push({
      index,
      address: account.address,
      hash,
      positionId: opened[0].args.positionId.toString(),
      gasLimit: gasLimit.toString(),
      gasUsed: receipt.gasUsed.toString(),
      market,
    });
  }
}

await Promise.all(Array.from({ length: concurrency }, worker));
results.sort((left, right) => left.index - right.index);
failures.sort((left, right) => left.index - right.index);

let productVerification;
let verificationError: string | undefined;
if (failures.length === 0) {
  try {
    productVerification = await verifyProduct(publicClient, manifest, results, markets, firstPositionId);
  } catch (error) {
    verificationError = describeError(error);
  }
}

await mkdir(resolve(root, "reports"), { recursive: true });
await writeFile(
  reportPath,
  `${JSON.stringify(
    {
      chainId: manifest.chainId,
      traderCount,
      successfulTransactions: results.length,
      failedTransactions: failures.length,
      transactions: results,
      failures,
      productVerification,
      verificationError,
    },
    null,
    2,
  )}\n`,
);

if (failures.length > 0) {
  throw new Error(`${failures.length} trader transactions failed; inspect ${reportPath}`);
}
if (verificationError) throw new Error(`product verification failed: ${verificationError}; inspect ${reportPath}`);

console.log(`completed ${results.length} trader transactions; report: ${reportPath}`);
