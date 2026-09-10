import {
  createPublicClient,
  createWalletClient,
  custom,
  defineChain,
  formatUnits,
  http,
  keccak256,
  parseAbi,
  parseUnits,
  stringToHex,
  type Address,
  type Hex,
} from "viem";

import "./style.css";
import { launchedMarketHint, marketStorageKey, openedPositionId, preparePositionAction, prioritizeMarketHints, readMarketHints, resolveMarket, requirePositionMarket, type Market } from "./markets";

interface DeploymentManifest {
  chainId: number;
  network: string;
  rpcUrl: string;
  pool: { fee: number; tickSpacing: number };
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

declare global {
  interface Window {
    ethereum?: Parameters<typeof custom>[0];
  }
}

const hookAbi = parseAbi([
  "function nextPositionId() view returns (uint256)",
  "function totalCustodiedTokens(bytes32 poolId) view returns (uint256)",
  "function accountedWethClaims() view returns (uint256)",
  "function custodyIsSolvent(bytes32 poolId) view returns (bool)",
  "function claimsAreConserved() view returns (bool)",
  "function sellerRebates(bytes32 poolId, address seller) view returns (uint256)",
  "function ownerShares(bytes32 poolId, address owner) view returns (uint256)",
  "function ownerScaledRewardCredit(bytes32 poolId, address owner) view returns (uint256)",
  "function positions(uint256) view returns (address owner, uint64 openedAt, bool rewardActive, uint128 initialTokens, uint128 remainingTokens, uint128 soldTokens, uint128 withdrawnTokens, uint256 initialBasis, uint256 remainingBasis, uint256 soldBasis, uint256 withdrawnBasis, uint256 profitRemainder)",
  "function withdraw(uint256 positionId, uint128 amount)",
  "function activatePosition(uint256 positionId)",
  "function claimRebate(bytes32 poolId, address seller) returns (uint256 amount)",
  "function claimRewards(bytes32 poolId, address recipient) returns (uint256 amount)",
]);
const erc20Abi = parseAbi([
  "function decimals() view returns (uint8)",
  "function allowance(address owner, address spender) view returns (uint256)",
  "function approve(address spender, uint256 amount) returns (bool)",
]);
const routerAbi = parseAbi([
  "function buy(address subject, uint128 wethAmountIn, uint128 subjectAmountOutMinimum, uint160 sqrtPriceLimitX96, uint64 deadline) returns (uint256 positionId)",
  "function sell(address subject, uint256 positionId, uint128 subjectAmountIn, uint128 wethAmountOutMinimum, uint160 sqrtPriceLimitX96, uint64 deadline) returns (uint256 wethAmountOut)",
]);
const coordinatorAbi = parseAbi([
  "function previewTokenAddress((string name,string symbol,string tagline,string logoURI,address expectedCreator,address feeBeneficiary,bytes32 deploymentSalt,uint160 sqrtPriceX96) args) view returns (address predicted)",
  "function openTokenMarket((string name,string symbol,string tagline,string logoURI,address expectedCreator,address feeBeneficiary,bytes32 deploymentSalt,uint160 sqrtPriceX96) args,address expectedToken) returns (address subject,bytes32 poolId)",
]);
const minSqrtPrice = 4_295_128_739n;
const maxSqrtPrice = 1_461_446_703_485_210_103_287_273_052_203_988_822_378_723_970_342n;
const zeroAddress = "0x0000000000000000000000000000000000000000";

const network = element<HTMLParagraphElement>("#network");
const accountText = element<HTMLParagraphElement>("#account");
const contracts = element<HTMLDListElement>("#contracts");
const protocolState = element<HTMLDListElement>("#state");
const walletState = element<HTMLDListElement>("#wallet-state");
const positionState = element<HTMLDListElement>("#position-state");
const connect = element<HTMLButtonElement>("#connect");
const launchButton = element<HTMLButtonElement>("#launch");
const launchForm = element<HTMLFormElement>("#launch-form");
const buyButton = element<HTMLButtonElement>("#buy");
const buyForm = element<HTMLFormElement>("#buy-form");
const positionForm = element<HTMLFormElement>("#position-form");
const positionIdInput = element<HTMLInputElement>("#position-id");
const inspectButton = element<HTMLButtonElement>("#inspect-position");
const claimRebateButton = element<HTMLButtonElement>("#claim-rebate");
const claimRewardsButton = element<HTMLButtonElement>("#claim-rewards");
const formError = element<HTMLParagraphElement>("#form-error");
const status = element<HTMLParagraphElement>("#status");
const marketPicker = element<HTMLSelectElement>("#market-picker");
const marketForm = element<HTMLFormElement>("#market-form");
const marketButton = element<HTMLButtonElement>("#select-market");

const response = await fetch("/deployment.json");
if (!response.ok) throw new Error("The LOOONG deployment manifest is unavailable.");
const deployment = (await response.json()) as DeploymentManifest;
const chain = defineChain({
  id: deployment.chainId,
  name: deployment.network,
  nativeCurrency: { name: "Ether", symbol: "ETH", decimals: 18 },
  rpcUrls: { default: { http: [deployment.rpcUrl] } },
});
const publicClient = createPublicClient({ chain, transport: http(deployment.rpcUrl) });
let selectedMarket = await resolveMarket(publicClient, deployment, deployment.contracts.subject);
if (selectedMarket.poolId.toLowerCase() !== deployment.poolId.toLowerCase()) throw new Error("The deployment PoolId does not match its subject.");
let { poolId, subject, decimals: subjectDecimals } = selectedMarket;
const storageKey = marketStorageKey(deployment);
let savedHints: ReturnType<typeof readMarketHints> = { subjects: [] };
try {
  savedHints = readMarketHints(localStorage.getItem(storageKey));
} catch {
  status.textContent = "Browser storage is unavailable. Market choices will last for this session.";
}
const knownSubjects = new Set<Address>(prioritizeMarketHints(
  [subject.toLowerCase() as Address, ...savedHints.subjects],
  savedHints.selected ?? subject,
));
if (savedHints.selected) {
  try {
    selectedMarket = await resolveMarket(publicClient, deployment, savedHints.selected);
    ({ poolId, subject, decimals: subjectDecimals } = selectedMarket);
  } catch (error) {
    showError(new Error(`Saved market is unavailable. The deployment market is selected. ${error instanceof Error ? error.message : String(error)}`));
  }
}
renderMarketPicker();
const wethDecimals = await publicClient.readContract({ address: deployment.contracts.weth, abi: erc20Abi, functionName: "decimals" });
let account: Address | undefined;
let working = false;

network.textContent = `${deployment.network} · chain ${deployment.chainId} · 0.30% LP fee`;
contracts.replaceChildren(...definitionRows(Object.entries(deployment.contracts)));
await refreshState();

marketForm.addEventListener("submit", async (event) => {
  event.preventDefault();
  if (working) return;
  clearError();
  setWorking(marketButton, "Select market", true);
  try {
    const enteredSubject = element<HTMLInputElement>("#market-subject").value.trim();
    const market = await resolveMarket(publicClient, deployment, enteredSubject || marketPicker.value);
    selectMarket(market);
    await refreshState();
    status.textContent = `Selected market ${market.subject}.`;
  } catch (error) {
    renderMarketPicker();
    showError(error);
  } finally {
    setWorking(marketButton, "Select market", false);
  }
});

connect.addEventListener("click", async () => {
  if (working) return;
  clearError();
  setWorking(connect, "Connect wallet", true);
  try {
    const wallet = await connectedWallet();
    [account] = await wallet.requestAddresses();
    if (!account) throw new Error("The wallet did not return an account.");
    accountText.textContent = account;
    await refreshState();
    status.textContent = "Wallet connected. You can open or manage a position.";
  } catch (error) {
    showError(error);
  } finally {
    setWorking(connect, "Connect wallet", false);
  }
});

launchForm.addEventListener("submit", async (event) => {
  event.preventDefault();
  if (!requireAccount()) return;
  clearError();
  setWorking(launchButton, "Launch token", true);
  try {
    const name = element<HTMLInputElement>("#token-name").value.trim();
    const symbol = element<HTMLInputElement>("#token-symbol").value.trim();
    const tagline = element<HTMLInputElement>("#token-tagline").value.trim();
    const logoURI = element<HTMLInputElement>("#token-logo").value.trim();
    requireUtf8Length(name, "Token name", 1, 64);
    requireUtf8Length(symbol, "Token symbol", 1, 16);
    requireUtf8Length(tagline, "Tagline", 0, 160);
    requireUtf8Length(logoURI, "Logo URI", 0, 256);
    const deploymentSalt = keccak256(stringToHex(`${account}:${Date.now()}:${crypto.randomUUID()}`));
    const launchArgs = {
      name,
      symbol,
      tagline,
      logoURI,
      expectedCreator: account!,
      feeBeneficiary: account!,
      deploymentSalt,
      sqrtPriceX96: 2n ** 96n,
    } as const;
    const wallet = await connectedWallet();
    const expectedToken = await publicClient.readContract({
      address: deployment.contracts.coordinator,
      abi: coordinatorAbi,
      functionName: "previewTokenAddress",
      args: [launchArgs],
    });
    const simulation = await publicClient.simulateContract({
      account: account!,
      address: deployment.contracts.coordinator,
      abi: coordinatorAbi,
      functionName: "openTokenMarket",
      args: [launchArgs, expectedToken],
    });
    const hash = await wallet.writeContract(simulation.request);
    const receipt = await requireReceipt(hash, "The token launch reverted.");
    const launched = launchedMarketHint(receipt, {
      coordinator: deployment.contracts.coordinator,
      subject: expectedToken,
      creator: launchArgs.expectedCreator,
      feeBeneficiary: launchArgs.feeBeneficiary,
      sqrtPriceX96: launchArgs.sqrtPriceX96,
    });
    const market = await resolveMarket(publicClient, deployment, launched.subject);
    if (market.poolId.toLowerCase() !== launched.poolId.toLowerCase()) throw new Error("The launch event PoolId does not match the registered market.");
    selectMarket(market);
    await refreshState();
    status.textContent = `${symbol} launched at ${subject}. It is now the selected LOOONG market.`;
  } catch (error) {
    showError(error);
  } finally {
    setWorking(launchButton, "Launch token", false);
  }
});

buyForm.addEventListener("submit", async (event) => {
  event.preventDefault();
  if (!requireAccount()) return;
  clearError();
  setWorking(buyButton, "Approve and buy", true);
  try {
    const amountInput = element<HTMLInputElement>("#weth-amount");
    const minimumInput = element<HTMLInputElement>("#minimum-output");
    const amount = parseAmount(amountInput, wethDecimals, "Enter a WETH amount greater than zero.");
    const minimumOutput = parseAmount(
      minimumInput,
      subjectDecimals,
      "Enter zero or a larger subject-token amount.",
      true,
    );
    const wallet = await connectedWallet();
    const allowance = await publicClient.readContract({
      address: deployment.contracts.weth,
      abi: erc20Abi,
      functionName: "allowance",
      args: [account!, deployment.contracts.router],
    });
    if (allowance < amount) {
      status.textContent = "Approve WETH in your wallet.";
      const approvalSimulation = await publicClient.simulateContract({
        account: account!,
        chain,
        address: deployment.contracts.weth,
        abi: erc20Abi,
        functionName: "approve",
        args: [deployment.contracts.router, amount],
      });
      const approval = await wallet.writeContract(approvalSimulation.request);
      await requireReceipt(approval, "The WETH approval reverted.");
    }

    const args = [subject, amount, minimumOutput, priceLimit(true), await deadline()] as const;
    status.textContent = "Simulating the verified buy.";
    const simulation = await publicClient.simulateContract({
      account: account!,
      address: deployment.contracts.router,
      abi: routerAbi,
      functionName: "buy",
      args,
    });
    status.textContent = "Confirm the verified buy in your wallet.";
    const hash = await wallet.writeContract(simulation.request);
    const receipt = await requireReceipt(hash, "The verified buy reverted.");
    const positionId = openedPositionId(receipt, {
      hook: deployment.contracts.hook,
      poolId,
      owner: account!,
    });
    positionIdInput.value = positionId.toString();
    await refreshAll();
    status.textContent = `Position ${positionId} opened.`;
  } catch (error) {
    showError(error);
  } finally {
    setWorking(buyButton, "Approve and buy", false);
  }
});

positionForm.addEventListener("submit", async (event) => {
  event.preventDefault();
  if (!requireAccount()) return;
  clearError();
  const submitter = (event as SubmitEvent).submitter as HTMLButtonElement | null;
  if (!submitter) return;
  const action = submitter.value;
  const idleLabel = submitter.textContent ?? "Submit";
  setWorking(submitter, idleLabel, true);
  try {
    const positionId = parsePositionId();
    const wallet = await preparePositionAction(
      publicClient,
      deployment,
      positionId,
      selectedMarket,
      connectedWallet,
    );
    if (action === "activate") {
      const simulation = await publicClient.simulateContract({
        account: account!,
        address: deployment.contracts.hook,
        abi: hookAbi,
        functionName: "activatePosition",
        args: [positionId],
      });
      const hash = await wallet.writeContract(simulation.request);
      await requireReceipt(hash, "The activation reverted.");
      status.textContent = `Position ${positionId} is active for rewards.`;
    } else {
      const amountInput = element<HTMLInputElement>("#position-amount");
      const amount = parseAmount(amountInput, subjectDecimals, "Enter a subject-token amount greater than zero.");
      if (action === "withdraw") {
        const simulation = await publicClient.simulateContract({
          account: account!,
          address: deployment.contracts.hook,
          abi: hookAbi,
          functionName: "withdraw",
          args: [positionId, amount],
        });
        const hash = await wallet.writeContract(simulation.request);
        await requireReceipt(hash, "The withdrawal reverted.");
        status.textContent = `Subject tokens withdrawn from position ${positionId}.`;
      } else {
        const minimumInput = element<HTMLInputElement>("#minimum-weth-output");
        const minimumOutput = parseAmount(
          minimumInput,
          wethDecimals,
          "Enter zero or a larger WETH amount.",
          true,
        );
        const simulation = await publicClient.simulateContract({
          account: account!,
          address: deployment.contracts.router,
          abi: routerAbi,
          functionName: "sell",
          args: [subject, positionId, amount, minimumOutput, priceLimit(false), await deadline()],
        });
        const hash = await wallet.writeContract(simulation.request);
        await requireReceipt(hash, "The verified sell reverted.");
        status.textContent = `Subject tokens sold from position ${positionId}.`;
      }
    }
    await refreshAll();
  } catch (error) {
    showError(error);
  } finally {
    setWorking(submitter, idleLabel, false);
  }
});

inspectButton.addEventListener("click", async () => {
  if (working) return;
  clearError();
  setWorking(inspectButton, "Inspect", true);
  try {
    await refreshPosition(parsePositionId());
    status.textContent = "Position state refreshed.";
  } catch (error) {
    showError(error);
  } finally {
    setWorking(inspectButton, "Inspect", false);
  }
});

claimRebateButton.addEventListener("click", () => claim("rebate", claimRebateButton));
claimRewardsButton.addEventListener("click", () => claim("rewards", claimRewardsButton));

async function claim(kind: "rebate" | "rewards", button: HTMLButtonElement): Promise<void> {
  if (!requireAccount()) return;
  clearError();
  const idleLabel = button.textContent ?? "Claim";
  setWorking(button, idleLabel, true);
  try {
    const wallet = await connectedWallet();
    const functionName = kind === "rebate" ? "claimRebate" : "claimRewards";
    const simulation = await publicClient.simulateContract({
      account: account!,
      address: deployment.contracts.hook,
      abi: hookAbi,
      functionName,
      args: [poolId, account!],
    });
    const hash = await wallet.writeContract(simulation.request);
    await requireReceipt(hash, `The ${kind} claim reverted.`);
    await refreshAll();
    status.textContent = `${kind === "rebate" ? "Rebate" : "Rewards"} claimed.`;
  } catch (error) {
    showError(error);
  } finally {
    setWorking(button, idleLabel, false);
  }
}

async function connectedWallet() {
  if (!window.ethereum) throw new Error("No injected wallet was found.");
  const wallet = createWalletClient({ chain, transport: custom(window.ethereum) });
  if ((await wallet.getChainId()) !== deployment.chainId) await wallet.switchChain({ id: deployment.chainId });
  if ((await wallet.getChainId()) !== deployment.chainId) throw new Error("Switch the wallet to the deployment chain.");
  await resolveMarket(publicClient, deployment, subject);
  return wallet;
}

async function refreshAll(): Promise<void> {
  await refreshState();
  const rawPositionId = positionIdInput.value.trim();
  if (rawPositionId) await refreshPosition(BigInt(rawPositionId));
}

async function refreshState(): Promise<void> {
  await resolveMarket(publicClient, deployment, subject);
  const [nextPositionId, custody, claims, custodySolvent, claimsConserved] = await Promise.all([
    publicClient.readContract({ address: deployment.contracts.hook, abi: hookAbi, functionName: "nextPositionId" }),
    publicClient.readContract({
      address: deployment.contracts.hook,
      abi: hookAbi,
      functionName: "totalCustodiedTokens",
      args: [poolId],
    }),
    publicClient.readContract({
      address: deployment.contracts.hook,
      abi: hookAbi,
      functionName: "accountedWethClaims",
    }),
    publicClient.readContract({
      address: deployment.contracts.hook,
      abi: hookAbi,
      functionName: "custodyIsSolvent",
      args: [poolId],
    }),
    publicClient.readContract({ address: deployment.contracts.hook, abi: hookAbi, functionName: "claimsAreConserved" }),
  ]);
  protocolState.replaceChildren(
    ...definitionRows([
      ["Positions opened", (nextPositionId - 1n).toString()],
      ["Selected market", subject],
      ["Custodied subject tokens", formatUnits(custody, subjectDecimals)],
      ["Accounted WETH claims", formatUnits(claims, wethDecimals)],
      ["Subject custody", custodySolvent ? "Solvent" : "Invariant failed"],
      ["WETH liabilities", claimsConserved ? "Conserved" : "Invariant failed"],
    ]),
  );
  if (account) {
    const [rebate, shares, scaledRewards] = await Promise.all([
      publicClient.readContract({
        address: deployment.contracts.hook,
        abi: hookAbi,
        functionName: "sellerRebates",
        args: [poolId, account],
      }),
      publicClient.readContract({
        address: deployment.contracts.hook,
        abi: hookAbi,
        functionName: "ownerShares",
        args: [poolId, account],
      }),
      publicClient.readContract({
        address: deployment.contracts.hook,
        abi: hookAbi,
        functionName: "ownerScaledRewardCredit",
        args: [poolId, account],
      }),
    ]);
    walletState.replaceChildren(
      ...definitionRows([
        ["Pending rebate", `${formatUnits(rebate, wethDecimals)} WETH`],
        ["Active shares", `${formatUnits(shares, subjectDecimals)} subject tokens`],
        ["Checkpointed rewards", `${formatUnits(scaledRewards / 10n ** 27n, wethDecimals)} WETH`],
      ]),
    );
  }
}

async function refreshPosition(positionId: bigint): Promise<void> {
  await requirePositionMarket(publicClient, deployment, positionId, selectedMarket);
  const position = await publicClient.readContract({
    address: deployment.contracts.hook,
    abi: hookAbi,
    functionName: "positions",
    args: [positionId],
  });
  const [owner, openedAt, rewardActive, initialTokens, remainingTokens, soldTokens, withdrawnTokens, initialBasis] =
    position;
  if (owner === zeroAddress) {
    positionState.replaceChildren(...definitionRows([["Position", "Closed or not found"]]));
    return;
  }
  positionState.replaceChildren(
    ...definitionRows([
      ["Owner", owner],
      ["Opened", new Date(Number(openedAt) * 1_000).toLocaleString()],
      ["Reward status", rewardActive ? "Active" : "Not active"],
      ["Initial subject tokens", formatUnits(initialTokens, subjectDecimals)],
      ["Remaining subject tokens", formatUnits(remainingTokens, subjectDecimals)],
      ["Sold subject tokens", formatUnits(soldTokens, subjectDecimals)],
      ["Withdrawn subject tokens", formatUnits(withdrawnTokens, subjectDecimals)],
      ["Initial WETH basis", formatUnits(initialBasis, wethDecimals)],
    ]),
  );
}

async function deadline(): Promise<bigint> {
  return (await publicClient.getBlock()).timestamp + 600n;
}

function priceLimit(buyLooong: boolean): bigint {
  const zeroForOne = buyLooong
    ? BigInt(deployment.contracts.weth) < BigInt(subject)
    : BigInt(subject) < BigInt(deployment.contracts.weth);
  return zeroForOne ? minSqrtPrice + 1n : maxSqrtPrice - 1n;
}

function parsePositionId(): bigint {
  try {
    const value = BigInt(positionIdInput.value.trim());
    if (value <= 0n) throw new Error();
    return value;
  } catch {
    showFieldError(positionIdInput, "Enter a position ID greater than zero.");
    throw new Error("Enter a valid position ID.");
  }
}

function parseAmount(input: HTMLInputElement, decimals: number, message: string, allowZero = false): bigint {
  try {
    const amount = parseUnits(input.value.trim(), decimals);
    if (allowZero ? amount < 0n : amount <= 0n) throw new Error();
    return amount;
  } catch {
    showFieldError(input, message);
    throw new Error(message);
  }
}

function requireUtf8Length(value: string, label: string, minimum: number, maximum: number): void {
  const length = new TextEncoder().encode(value).length;
  if (length < minimum || length > maximum) {
    throw new Error(`${label} must be between ${minimum} and ${maximum} UTF-8 bytes.`);
  }
}

async function requireReceipt(hash: `0x${string}`, message: string) {
  const receipt = await publicClient.waitForTransactionReceipt({ hash });
  if (receipt.status !== "success") throw new Error(message);
  return receipt;
}

function requireAccount(): boolean {
  if (working) return false;
  if (account) return true;
  status.textContent = "Connect a wallet first.";
  connect.focus();
  return false;
}

function setWorking(button: HTMLButtonElement, idleLabel: string, pending: boolean): void {
  working = pending;
  for (const control of document.querySelectorAll<HTMLButtonElement | HTMLInputElement | HTMLSelectElement>("button, input, select")) {
    control.disabled = pending;
  }
  button.textContent = pending ? `${idleLabel} · Working…` : idleLabel;
}

function selectMarket(market: Market): void {
  selectedMarket = market;
  ({ poolId, subject, decimals: subjectDecimals } = market);
  const prioritizedSubjects = prioritizeMarketHints(knownSubjects, subject);
  knownSubjects.clear();
  for (const knownSubject of prioritizedSubjects) knownSubjects.add(knownSubject);
  positionState.replaceChildren();
  walletState.replaceChildren();
  protocolState.replaceChildren();
  renderMarketPicker();
  element<HTMLInputElement>("#market-subject").value = "";
  try {
    localStorage.setItem(storageKey, JSON.stringify({ subjects: [...knownSubjects], selected: subject }));
  } catch {
    showError(new Error("Market selected, but browser storage is unavailable. Save its subject address before reloading."));
  }
}

function renderMarketPicker(): void {
  marketPicker.replaceChildren(...[...knownSubjects].map((address) => {
    const option = document.createElement("option");
    option.value = address;
    option.textContent = address;
    option.selected = address === subject.toLowerCase();
    return option;
  }));
}

function definitionRows(entries: [string, string][]): HTMLElement[] {
  return entries.flatMap(([name, value]) => {
    const term = document.createElement("dt");
    term.textContent = name;
    const description = document.createElement("dd");
    description.textContent = value;
    return [term, description];
  });
}

function showError(error: unknown): void {
  formError.hidden = false;
  formError.textContent = error instanceof Error ? error.message : String(error);
}

function showFieldError(input: HTMLInputElement, message: string): void {
  input.setAttribute("aria-invalid", "true");
  input.setAttribute("aria-describedby", "form-error");
  formError.hidden = false;
  formError.textContent = message;
  input.focus();
}

function clearError(): void {
  formError.hidden = true;
  formError.textContent = "";
  for (const input of document.querySelectorAll("input")) {
    input.removeAttribute("aria-invalid");
    input.removeAttribute("aria-describedby");
  }
}

function element<T extends Element>(selector: string): T {
  const result = document.querySelector<T>(selector);
  if (!result) throw new Error(`Required interface element is missing: ${selector}`);
  return result;
}
