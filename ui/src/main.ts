import { createWalletClient, custom, numberToHex, type Address } from "viem";

import "./style.css";

interface DeploymentManifest {
  chainId: number;
  network: string;
  contracts: Record<string, Address>;
}

declare global {
  interface Window {
    ethereum?: Parameters<typeof custom>[0];
  }
}

const network = document.querySelector<HTMLParagraphElement>("#network")!;
const contracts = document.querySelector<HTMLDListElement>("#contracts")!;
const connect = document.querySelector<HTMLButtonElement>("#connect")!;
const status = document.querySelector<HTMLParagraphElement>("#status")!;

const response = await fetch("/deployment.json");
if (!response.ok) throw new Error("deployment manifest is unavailable");
const deployment = (await response.json()) as DeploymentManifest;

network.textContent = `${deployment.network} · chain ${deployment.chainId}`;
contracts.replaceChildren(
  ...Object.entries(deployment.contracts).flatMap(([name, address]) => {
    const term = document.createElement("dt");
    term.textContent = name;
    const value = document.createElement("dd");
    value.textContent = address;
    return [term, value];
  }),
);

connect.addEventListener("click", async () => {
  if (!window.ethereum) {
    status.textContent = "No injected wallet found.";
    return;
  }

  const wallet = createWalletClient({ transport: custom(window.ethereum) });
  const currentChainId = await wallet.getChainId();
  if (currentChainId !== deployment.chainId) {
    await wallet.switchChain({ id: deployment.chainId });
  }
  const [account] = await wallet.requestAddresses();
  status.textContent = account
    ? `Connected ${account} on ${numberToHex(deployment.chainId)}`
    : "Wallet connection returned no account.";
});
