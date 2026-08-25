import type { PreparedTrade, TradeContext } from "./types.js";

/// Replace this seed with the intended Universal Router/Permit2 or project-router call.
export async function prepareTrade(_context: TradeContext): Promise<PreparedTrade> {
  throw new Error(
    "Implement scenarios/trade.ts with the production router path before running the trader scenario.",
  );
}
