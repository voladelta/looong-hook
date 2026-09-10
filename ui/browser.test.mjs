import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import { createRequire } from "node:module";
import { after, afterEach, before, beforeEach, test } from "node:test";
import { createPublicClient, encodeFunctionData, formatUnits, http, parseAbi } from "viem";

// Use an existing Playwright installation (NODE_PATH also supports the bundled desktop runtime).
const { chromium } = createRequire(import.meta.url)("playwright");
const appUrl = process.env.BROWSER_APP_URL ?? "http://127.0.0.1:4173";
const deployment = JSON.parse(await readFile(new URL("./public/deployment.json", import.meta.url), "utf8"));
assert.equal(deployment.chainId, 31337, "browser proof requires disposable localhost");
assert.equal(new URL(deployment.rpcUrl).hostname, "127.0.0.1");
assert.equal(new URL(appUrl).hostname, "127.0.0.1");
const client = createPublicClient({ transport: http(deployment.rpcUrl) });
const abi = parseAbi([
  "function positions(uint256) view returns (address,uint64,bool,uint128,uint128,uint128,uint128,uint256,uint256,uint256,uint256,uint256)",
  "function nextPositionId() view returns (uint256)",
  "function approve(address,uint256) returns (bool)",
]);
const accounts = await client.request({ method: "eth_accounts" });
let browser;
let context;
let page;
let snapshot;
let uncaught;

before(async () => { browser = await chromium.launch({ headless: true }); });
after(async () => { await browser?.close(); });
beforeEach(async () => {
  snapshot = await client.request({ method: "evm_snapshot" });
  context = await browser.newContext({ viewport: { width: 1280, height: 900 } });
  await context.addInitScript(({ accounts, rpcUrl }) => {
    const listeners = new Map();
    let selected = [accounts[0]];
    let walletChain = "0x7a69";
    const harness = {
      sent: [],
      rejectNext: false,
      switchAfterSend: false,
      setAccounts(next, notify = true) {
        selected = next;
        if (notify) this.emit("accountsChanged", next);
      },
      emit(event, value) {
        if (event === "disconnect") selected = [];
        if (event === "chainChanged") walletChain = value;
        for (const listener of listeners.get(event) ?? []) listener(value);
      },
    };
    window.walletHarness = harness;
    window.ethereum = {
      on(event, listener) {
        const handlers = listeners.get(event) ?? new Set();
        handlers.add(listener);
        listeners.set(event, handlers);
      },
      removeListener(event, listener) { listeners.get(event)?.delete(listener); },
      async request({ method, params }) {
        if (method === "eth_accounts" || method === "eth_requestAccounts") return selected;
        if (method === "eth_chainId") return walletChain;
        if (method === "wallet_switchEthereumChain") {
          harness.emit("chainChanged", params[0].chainId);
          return null;
        }
        if (method === "eth_sendTransaction") {
          harness.sent.push(params[0]);
          if (harness.rejectNext) {
            harness.rejectNext = false;
            throw Object.assign(new Error("User rejected the request."), { code: 4001 });
          }
        }
        const response = await fetch(rpcUrl, {
          method: "POST",
          headers: { "content-type": "application/json" },
          body: JSON.stringify({ jsonrpc: "2.0", id: 1, method, params: params ?? [] }),
        });
        const payload = await response.json();
        if (payload.error) throw Object.assign(new Error(payload.error.message), { code: payload.error.code });
        if (method === "eth_sendTransaction" && harness.switchAfterSend) {
          harness.switchAfterSend = false;
          harness.setAccounts([accounts[1]]);
        }
        return payload.result;
      },
    };
  }, { accounts, rpcUrl: deployment.rpcUrl });
  page = await context.newPage();
  page.setDefaultTimeout(5_000);
  uncaught = [];
  page.on("pageerror", (error) => uncaught.push(error.message));
});
afterEach(async () => {
  await context?.close();
  assert.equal(await client.request({ method: "evm_revert", params: [snapshot] }), true);
  assert.deepEqual(uncaught, [], "uncaught browser application errors");
});

async function ready() {
  await page.goto(appUrl);
  await page.waitForFunction(() => document.querySelector("#state").textContent.includes("Solvent"));
  await page.waitForFunction(() => !document.querySelector("#connect").disabled);
  assert.match(await page.locator("#state").textContent(), /Solvent/);
}

async function idle() {
  await page.waitForFunction(() => !document.querySelector("#connect").disabled);
}

async function connect() {
  await ready();
  await page.locator("#connect").click();
  await idle();
  assert.equal((await page.locator("#account").textContent()).toLowerCase(), accounts[0].toLowerCase());
}

async function buy() {
  await page.locator("#buy").click();
  await idle();
  assert.equal(await page.locator("#form-error").isVisible(), false);
  const id = BigInt(await page.locator("#position-id").inputValue());
  const position = await client.readContract({ address: deployment.contracts.hook, abi, functionName: "positions", args: [id] });
  assert(position[4] > 0n);
  return { id, remaining: position[4] };
}

test("manifest failure renders a disabled error boundary and retry recovers", async () => {
  await page.route("**/deployment.json", (route) => route.fulfill({ status: 503, body: "Unavailable" }));
  await page.goto(appUrl);
  await page.locator("#retry-startup").waitFor({ state: "visible" });
  assert.equal(await page.locator("#buy").isDisabled(), true);
  assert.equal(await page.locator("#connect").isDisabled(), true);
  assert.match(await page.locator("#form-error").textContent(), /manifest is unavailable/);
  await page.unroute("**/deployment.json");
  await page.locator("#retry-startup").click();
  await idle();
  assert.match(await page.locator("#state").textContent(), /Solvent/);
});

test("initial RPC failure renders recovery guidance and retry recovers", async () => {
  await page.route(deployment.rpcUrl, (route) => route.fulfill({ status: 503, body: "RPC unavailable" }));
  await page.goto(appUrl);
  await page.locator("#retry-startup").waitFor({ state: "visible" });
  assert.equal(await page.locator("#launch").isDisabled(), true);
  assert.match(await page.locator("#status").textContent(), /RPC connection.*retry/);
  await page.unroute(deployment.rpcUrl);
  await page.locator("#retry-startup").click();
  await idle();
  assert.equal(await page.locator("#form-error").isVisible(), false);
});

test("full withdrawal confirms and renders the deleted position as closed", async () => {
  await connect();
  const position = await buy();
  await page.locator("#position-amount").fill(formatUnits(position.remaining, 18));
  await page.locator('button[value="withdraw"]').click();
  await idle();
  assert.match(await page.locator("#position-state").textContent(), /Closed or not found/);
  assert.match(await page.locator("#status").textContent(), /withdrawn/);
  assert.equal(await page.locator("#form-error").isVisible(), false);
});

test("full sell confirms and renders the deleted position as closed", async () => {
  await connect();
  const position = await buy();
  await page.locator("#position-amount").fill(formatUnits(position.remaining, 18));
  await page.locator('button[value="sell"]').click();
  await idle();
  assert.match(await page.locator("#position-state").textContent(), /Closed or not found/);
  assert.equal(await page.locator("#form-error").isVisible(), false);
});

test("a successful claim ignores an unrelated inspector record", async () => {
  await connect();
  const position = await buy();
  await page.locator("#position-amount").fill(formatUnits(position.remaining, 18));
  await page.locator('button[value="sell"]').click();
  await idle();
  await page.locator("#position-id").fill("999999999");
  await page.locator("#claim-rebate").click();
  await idle();
  assert.match(await page.locator("#status").textContent(), /Rebate claimed/);
  assert.equal(await page.locator("#form-error").isVisible(), false);
});

test("launch and market selection clear the previous position inspector", async () => {
  await connect();
  const { id } = await buy();
  await page.locator("#token-name").fill("Browser proof");
  await page.locator("#token-symbol").fill("BROWSE");
  await page.locator("#launch").click();
  await idle();
  assert.match(await page.locator("#status").textContent(), /launched/);
  assert.equal(await page.locator("#position-id").inputValue(), "");
  assert.equal(await page.locator("#position-state").textContent(), "");
  await page.locator("#position-id").fill(String(id));
  await page.locator("#market-subject").fill(deployment.contracts.subject);
  await page.locator("#select-market").click();
  await idle();
  assert.equal(await page.locator("#position-id").inputValue(), "");
});

test("account, chain and disconnect events invalidate account-specific state", async () => {
  await connect();
  await buy();
  await page.evaluate((next) => window.walletHarness.setAccounts([next]), accounts[1]);
  assert.equal((await page.locator("#account").textContent()).toLowerCase(), accounts[1].toLowerCase());
  assert.equal(await page.locator("#position-id").inputValue(), "");
  assert.equal(await page.locator("#position-state").textContent(), "");

  await page.evaluate(() => window.walletHarness.emit("chainChanged", "0x1"));
  assert.equal(await page.locator("#account").textContent(), "Not connected");
  await page.locator("#connect").click();
  await idle();
  await page.evaluate(() => window.walletHarness.emit("disconnect", { code: 4900, message: "Disconnected" }));
  assert.equal(await page.locator("#account").textContent(), "Not connected");
  assert.equal(await page.locator("#wallet-state").textContent(), "");
});

test("a silent account change is rechecked before preparing a buy", async () => {
  await connect();
  await page.evaluate((next) => window.walletHarness.setAccounts([next], false), accounts[1]);
  await page.locator("#buy").click();
  await idle();
  assert.match(await page.locator("#form-error").textContent(), /Wallet account changed/);
  assert.equal(await page.evaluate(() => window.walletHarness.sent.length), 0);
  const { id } = await buy();
  const position = await client.readContract({ address: deployment.contracts.hook, abi, functionName: "positions", args: [id] });
  assert.equal(position[0].toLowerCase(), accounts[1].toLowerCase());
});

test("account changes after approval prevent the dependent buy", async () => {
  const hash = await client.request({ method: "eth_sendTransaction", params: [{
    from: accounts[0],
    to: deployment.contracts.weth,
    data: encodeFunctionData({ abi, functionName: "approve", args: [deployment.contracts.router, 0n] }),
  }] });
  await client.waitForTransactionReceipt({ hash });
  const nextId = await client.readContract({ address: deployment.contracts.hook, abi, functionName: "nextPositionId" });
  await connect();
  await page.evaluate(() => { window.walletHarness.switchAfterSend = true; });
  await page.locator("#buy").click();
  await idle();
  assert.match(await page.locator("#form-error").textContent(), /Wallet changed during this action/);
  assert.equal(await page.evaluate(() => window.walletHarness.sent.length), 1);
  assert.equal(await client.readContract({ address: deployment.contracts.hook, abi, functionName: "nextPositionId" }), nextId);
});

test("provider replacement during market resolution cancels the old wallet session", { timeout: 10_000 }, async () => {
  await connect();
  let release;
  let reached;
  let paused = false;
  const resume = new Promise((resolve) => { release = resolve; });
  const intercepted = new Promise((resolve) => { reached = resolve; });
  await page.route(deployment.rpcUrl, async (route) => {
    if (!paused && route.request().postDataJSON().method === "eth_chainId") {
      paused = true;
      reached();
      await resume;
    }
    await route.continue();
  });
  const click = page.locator("#buy").click();
  await intercepted;
  try {
    await page.evaluate((next) => {
      const original = window.ethereum;
      window.ethereum = {
        on() {},
        removeListener() {},
        request(request) {
          if (request.method === "eth_accounts" || request.method === "eth_requestAccounts") return Promise.resolve([next]);
          return original.request(request);
        },
      };
    }, accounts[1]);
  } finally {
    release();
  }
  await click;
  await idle();
  assert.equal(await page.evaluate(() => window.walletHarness.sent.length), 0);
  assert.equal(await page.locator("#account").textContent(), "Not connected");
  assert.match(await page.locator("#form-error").textContent(), /Wallet changed during this action/);
});

test("wallet rejection and simulation failure return handlers to an actionable state", async () => {
  await connect();
  await page.evaluate(() => { window.walletHarness.rejectNext = true; });
  await page.locator("#buy").click();
  await idle();
  assert.match(await page.locator("#form-error").textContent(), /rejected/i);
  assert.equal(await page.locator("#buy").isDisabled(), false);
  await page.locator("#minimum-output").fill("100000000");
  await page.locator("#buy").click();
  await idle();
  assert.equal(await page.locator("#form-error").isVisible(), true);
  assert.match(await page.locator("#form-error").textContent(), /reverted/i);
  assert.equal(await page.evaluate(() => window.walletHarness.sent.length), 1, "failed simulation requested a signature");
});

test("desktop and 320px render stay in bounds with keyboard access and a simulated write", async () => {
  await connect();
  for (const width of [1280, 320]) {
    await page.setViewportSize({ width, height: 900 });
    assert.equal(await page.evaluate(() => document.documentElement.scrollWidth <= window.innerWidth), true);
    await page.locator("#connect").focus();
    await page.keyboard.press("Tab");
    assert.equal(await page.locator("#claim-rebate").evaluate((button) => button === document.activeElement), true);
    assert.equal(await page.locator("#claim-rebate").evaluate((button) => getComputedStyle(button).outlineStyle !== "none"), true);
    await page.evaluate(() => { window.walletHarness.rejectNext = true; });
    await page.locator("#buy").click();
    await idle();
    assert.match(await page.locator("#form-error").textContent(), /rejected/i);
  }
});
