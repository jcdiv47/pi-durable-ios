// Test bundle: runs Pi Durable's storage conformance suite inside JSC against the Swift sqlite3 facade.
// Swift evaluates this bundle, then awaits `PiConformance.runStorage(dir)` and reads the JSON report.

import "./host/polyfills.ts";
import { BACKGROUND_CONTEXT } from "@earendil-works/chord/context";
import { SqliteStorage } from "@earendil-works/pi-durable/storage/sqlite";
import { createStorageConformance, type StorageConformanceAssertions } from "@earendil-works/pi-durable/testing";
import { native } from "./host/native.ts";
import { openIOSSqliteDatabase } from "./host/sqlite.ts";
import { createFacadeCases } from "../test/facade-cases.ts";
import { createHttpCases } from "../test/http-cases.ts";
import { createMcpCases } from "../test/mcp-cases.ts";
import { createPolyfillCases } from "../test/polyfill-cases.ts";

class AssertionError extends Error {
	override name = "AssertionError";
}

function show(value: unknown): string {
	try {
		return JSON.stringify(value, (_k, v) => (typeof v === "bigint" ? `${v}n` : v instanceof Uint8Array ? [...v] : v));
	} catch {
		return String(value);
	}
}

function isIterableCollection(v: unknown): v is Map<unknown, unknown> | Set<unknown> {
	return v instanceof Map || v instanceof Set;
}

/** Vitest `toEqual` (partial = false) and `toMatchObject` (partial = true) semantics, enough for the suite. */
function equals(actual: unknown, expected: unknown, partial: boolean): boolean {
	if (Object.is(actual, expected)) return true;
	if (typeof actual !== "object" || typeof expected !== "object" || actual === null || expected === null) return false;
	if (actual instanceof Date || expected instanceof Date) {
		return actual instanceof Date && expected instanceof Date && actual.getTime() === expected.getTime();
	}
	if (actual instanceof RegExp || expected instanceof RegExp) return String(actual) === String(expected);
	if (ArrayBuffer.isView(actual) || ArrayBuffer.isView(expected)) {
		if (!ArrayBuffer.isView(actual) || !ArrayBuffer.isView(expected)) return false;
		if (actual.constructor !== expected.constructor) return false;
		const a = actual as unknown as ArrayLike<unknown>;
		const b = expected as unknown as ArrayLike<unknown>;
		if (a.length !== b.length) return false;
		for (let i = 0; i < a.length; i++) if (!Object.is(a[i], b[i])) return false;
		return true;
	}
	if (Array.isArray(actual) || Array.isArray(expected)) {
		if (!Array.isArray(actual) || !Array.isArray(expected) || actual.length !== expected.length) return false;
		return actual.every((v, i) => equals(v, expected[i], partial));
	}
	if (isIterableCollection(actual) || isIterableCollection(expected)) {
		if (actual.constructor !== expected.constructor) return false;
		const a = actual as Map<unknown, unknown> | Set<unknown>;
		const b = expected as Map<unknown, unknown> | Set<unknown>;
		if (a.size !== b.size) return false;
		if (a instanceof Map && b instanceof Map) {
			for (const [k, v] of b) if (!a.has(k) || !equals(a.get(k), v, partial)) return false;
			return true;
		}
		const remaining = [...a];
		for (const v of b) {
			const index = remaining.findIndex((x) => equals(x, v, partial));
			if (index < 0) return false;
			remaining.splice(index, 1);
		}
		return true;
	}
	const a = actual as Record<string, unknown>;
	const b = expected as Record<string, unknown>;
	const definedKeys = (o: Record<string, unknown>) => Object.keys(o).filter((k) => o[k] !== undefined);
	const expectedKeys = definedKeys(b);
	if (!partial) {
		const actualKeys = definedKeys(a);
		if (actualKeys.length !== expectedKeys.length) return false;
	}
	return expectedKeys.every((k) => (k in a || !partial) && equals(a[k], b[k], partial));
}

const assertions: StorageConformanceAssertions = {
	ok(value, message) {
		if (!value) throw new AssertionError(message ?? `expected truthy, got ${show(value)}`);
	},
	strictEqual(actual, expected) {
		if (!Object.is(actual, expected)) throw new AssertionError(`expected ${show(actual)} to be ${show(expected)}`);
	},
	deepEqual(actual, expected) {
		if (!equals(actual, expected, false)) throw new AssertionError(`expected ${show(actual)} to equal ${show(expected)}`);
	},
	partialDeepEqual(actual, expected) {
		if (!equals(actual, expected, true)) throw new AssertionError(`expected ${show(actual)} to match ${show(expected)}`);
	},
	greaterThan(actual, expected) {
		if (!(actual > expected)) throw new AssertionError(`expected ${actual} > ${expected}`);
	},
	async rejects(operation, messageIncludes) {
		let error: unknown;
		try {
			await operation;
		} catch (caught) {
			error = caught;
		}
		if (error === undefined) throw new AssertionError(`expected rejection including "${messageIncludes}"`);
		const message = error instanceof Error ? error.message : String(error);
		if (!message.includes(messageIncludes)) {
			throw new AssertionError(`expected rejection including "${messageIncludes}", got "${message}"`);
		}
	},
};

export interface CaseResult {
	readonly name: string;
	readonly ok: boolean;
	readonly ms: number;
	readonly error?: string;
}

export interface ConformanceReport {
	readonly suite: string;
	readonly passed: number;
	readonly failed: number;
	readonly totalMs: number;
	readonly cases: CaseResult[];
}

interface TestCase {
	readonly name: string;
	run(): Promise<void>;
}

async function runCases(suite: string, cases: readonly TestCase[], filter?: string): Promise<ConformanceReport> {
	const results: CaseResult[] = [];
	const started = performance.now();
	for (const testCase of cases) {
		if (filter !== undefined && !testCase.name.includes(filter)) continue;
		const t0 = performance.now();
		try {
			await testCase.run();
			results.push({ name: testCase.name, ok: true, ms: performance.now() - t0 });
		} catch (error) {
			const text = error instanceof Error ? `${error.name}: ${error.message}\n${error.stack ?? ""}` : String(error);
			results.push({ name: testCase.name, ok: false, ms: performance.now() - t0, error: text });
			console.error(`FAIL ${testCase.name}: ${text}`);
		}
		native.emit(JSON.stringify({ type: "conformance_case", suite, ...results.at(-1) }));
	}
	const failed = results.filter((r) => !r.ok).length;
	return { suite, passed: results.length - failed, failed, totalMs: performance.now() - started, cases: results };
}

function runStorage(directory: string, options: { filter?: string } = {}): Promise<ConformanceReport> {
	let fileCounter = 0;
	const cases = createStorageConformance({
		assertions,
		withStorage: async (use) => {
			const path = `${directory}/conformance-${++fileCounter}.sqlite`;
			const storage = await SqliteStorage.open(openIOSSqliteDatabase(path), { prefix: "pi_" });
			try {
				await use(storage);
			} finally {
				await storage.close(BACKGROUND_CONTEXT);
			}
		},
	});
	return runCases("storage (SqliteStorage over iOS sqlite3, prefix pi_)", cases, options.filter);
}

function runFacade(directory: string): Promise<ConformanceReport> {
	return runCases("SqliteDatabase facade contract", createFacadeCases(directory, assertions));
}

function runPolyfills(): Promise<ConformanceReport> {
	return runCases("host polyfills", createPolyfillCases(assertions));
}

function runMcp(): Promise<ConformanceReport> {
	return runCases("MCP client and extension", createMcpCases(assertions));
}

function runHttp(): Promise<ConformanceReport> {
	return runCases("HTTP endpoint tools", createHttpCases(assertions));
}

(globalThis as Record<string, unknown>).PiConformance = { runStorage, runFacade, runPolyfills, runMcp, runHttp };
