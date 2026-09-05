import { encodeFunctionData, parseEther } from "viem";

import type { PreparedTrade, TradeContext } from "./types.js";

const routerAbi = [
  {
    type: "function",
    name: "buy",
    stateMutability: "nonpayable",
    inputs: [
      { name: "subject", type: "address" },
      { name: "wethAmountIn", type: "uint128" },
      { name: "subjectAmountOutMinimum", type: "uint128" },
      { name: "sqrtPriceLimitX96", type: "uint160" },
      { name: "deadline", type: "uint64" },
    ],
    outputs: [{ name: "positionId", type: "uint256" }],
  },
] as const;

const minSqrtPrice = 4_295_128_739n;
const maxSqrtPrice = 1_461_446_703_485_210_103_287_273_052_203_988_822_378_723_970_342n;

export async function prepareTrade(context: TradeContext): Promise<PreparedTrade> {
  const block = await context.publicClient.getBlock();
  const wethIsCurrency0 = BigInt(context.manifest.contracts.weth) < BigInt(context.manifest.contracts.subject);
  return {
    to: context.manifest.contracts.router,
    data: encodeFunctionData({
      abi: routerAbi,
      functionName: "buy",
      args: [
        context.manifest.contracts.subject,
        parseEther("0.01"),
        1n,
        wethIsCurrency0 ? minSqrtPrice + 1n : maxSqrtPrice - 1n,
        block.timestamp + 600n,
      ],
    }),
  };
}
