// What the conversations cost and how full their context is. A conversation's own totals come from its `pi.usage`
// document (display.ts); spend over a period comes from the assistant entries, which carry their usage and when they
// were asked, since `pi.usage` keeps no dates.

import type { EntryRecord } from "@earendil-works/pi-durable";

type EntryUsage = {
	input?: number;
	output?: number;
	cacheRead?: number;
	cacheWrite?: number;
	cost?: { total?: number };
};

type AssistantMessage = { provider?: string; model?: string; timestamp?: number; usage?: EntryUsage };

/** One model answer's spend: when it was asked, by which model. */
export type Spend = { at: number; model: string; input: number; output: number; cost: number };

/** Spend over a period, all models together and each model apart (most expensive first). */
export type SpendTotals = {
	input: number;
	output: number;
	cost: number;
	/** Conversations with spend in the period. */
	conversations: number;
	models: { model: string; input: number; output: number; cost: number }[];
};

function assistant(entry: EntryRecord): AssistantMessage | undefined {
	return entry.kind === "pi.assistant" ? (entry.model?.[0] as AssistantMessage | undefined) : undefined;
}

/** The model answers in a transcript with their spend. Input counts cached tokens too: all of it was sent. */
export function spendOf(entries: readonly EntryRecord[]): Spend[] {
	const spend: Spend[] = [];
	for (const entry of entries) {
		const message = assistant(entry);
		const usage = message?.usage;
		if (usage === undefined || typeof message?.timestamp !== "number") continue;
		spend.push({
			at: message.timestamp,
			model: `${message.provider ?? "?"}/${message.model ?? "?"}`,
			input: (usage.input ?? 0) + (usage.cacheRead ?? 0) + (usage.cacheWrite ?? 0),
			output: usage.output ?? 0,
			cost: usage.cost?.total ?? 0,
		});
	}
	return spend;
}

/** Adds the spend in `[from, to)` of each conversation's answers. */
export function spendBetween(conversations: readonly (readonly Spend[])[], from: number, to: number): SpendTotals {
	const totals: SpendTotals = { input: 0, output: 0, cost: 0, conversations: 0, models: [] };
	const models = new Map<string, SpendTotals["models"][number]>();
	for (const spend of conversations) {
		let counted = false;
		for (const item of spend) {
			if (item.at < from || item.at >= to) continue;
			counted = true;
			totals.input += item.input;
			totals.output += item.output;
			totals.cost += item.cost;
			let model = models.get(item.model);
			if (model === undefined) models.set(item.model, (model = { model: item.model, input: 0, output: 0, cost: 0 }));
			model.input += item.input;
			model.output += item.output;
			model.cost += item.cost;
		}
		if (counted) totals.conversations++;
	}
	totals.models = [...models.values()].sort((a, b) => b.cost - a.cost || b.input + b.output - (a.input + a.output));
	return totals;
}

/**
 * How many tokens the conversation's context holds: what the newest answer read and wrote. Unknown after a compaction
 * or a new context until the next answer, and when no answer since reported usage (errors, the offline model).
 */
export function contextTokens(entries: readonly EntryRecord[]): number | undefined {
	for (let index = entries.length - 1; index >= 0; index--) {
		const entry = entries[index]!;
		if (entry.kind === "pi.compaction" || entry.kind === "pi.reset") return undefined;
		const usage = assistant(entry)?.usage;
		if (usage === undefined) continue;
		const tokens = (usage.input ?? 0) + (usage.cacheRead ?? 0) + (usage.cacheWrite ?? 0) + (usage.output ?? 0);
		if (tokens > 0) return tokens;
	}
	return undefined;
}
