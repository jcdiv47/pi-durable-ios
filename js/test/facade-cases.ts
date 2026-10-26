// The `SqliteDatabase` contract from chord's database.d.ts, checked against the iOS facade inside JSC.
// Pi's storage conformance suite does not reach every branch here (notably rollback), so these
// cases pin the facade down directly.

import type { StorageConformanceAssertions } from "@earendil-works/pi-durable/testing";
import { openIOSSqliteDatabase } from "../src/host/sqlite.ts";

type Case = { name: string; run(): Promise<void> };

export function createFacadeCases(directory: string, t: StorageConformanceAssertions): Case[] {
	let counter = 0;
	const fresh = async () => {
		const db = openIOSSqliteDatabase(`${directory}/facade-${++counter}.sqlite`);
		await db.exec("CREATE TABLE t (id INTEGER PRIMARY KEY, v ANY) STRICT");
		return db;
	};

	return [
		{
			name: "opens in WAL mode with synchronous = NORMAL",
			async run() {
				const db = await fresh();
				t.deepEqual(await db.get("PRAGMA journal_mode"), { journal_mode: "wal" });
				t.deepEqual(await db.get("PRAGMA synchronous"), { synchronous: 1 });
				await db.close();
			},
		},
		{
			name: "round-trips null, integers, reals, text, blobs and BigInts",
			async run() {
				const db = await fresh();
				const blob = new Uint8Array([0, 1, 2, 250, 255]);
				const values: [number, unknown][] = [
					[1, null],
					[2, 42],
					[3, -7],
					[4, 1.5],
					[5, "héllo 👋 \u0000 end"],
					[6, blob],
					[7, Number.MAX_SAFE_INTEGER],
					[8, 2n ** 62n],
					[9, new Uint8Array(0)],
					[10, ""],
				];
				for (const [id, v] of values) await db.run("INSERT INTO t (id, v) VALUES (?, ?)", id, v as never);
				const rows = await db.all<{ id: number; v: unknown }>("SELECT id, v FROM t ORDER BY id");
				t.deepEqual(
					rows.map((r) => r.v),
					values.map(([, v]) => v),
				);
				t.strictEqual(typeof rows[7]!.v, "bigint");
				t.strictEqual(await db.get("SELECT v FROM t WHERE id = ?", 999), undefined);
				await db.close();
			},
		},
		{
			name: "rejects a wrong number of bindings and unsupported values",
			async run() {
				const db = await fresh();
				await t.rejects(db.run("INSERT INTO t (id, v) VALUES (?, ?)", 1), "bindings");
				await t.rejects(db.run("INSERT INTO t (id, v) VALUES (?, ?)", 1, true as never), "unsupported binding");
				await t.rejects(db.run("INSERT INTO nope VALUES (1)"), "no such table");
				await db.close();
			},
		},
		{
			name: "exec runs several statements",
			async run() {
				const db = await fresh();
				await db.exec("INSERT INTO t (id, v) VALUES (1, 'a'); INSERT INTO t (id, v) VALUES (2, 'b');");
				t.deepEqual(await db.get("SELECT count(*) AS n FROM t"), { n: 2 });
				await db.close();
			},
		},
		{
			name: "commits when the callback resolves and returns its value",
			async run() {
				const db = await fresh();
				const result = await db.transaction(async (tx) => {
					await tx.run("INSERT INTO t (id, v) VALUES (?, ?)", 1, "x");
					return "value";
				});
				t.strictEqual(result, "value");
				t.deepEqual(await db.get("SELECT v FROM t WHERE id = 1"), { v: "x" });
				await db.close();
			},
		},
		{
			name: "rolls back and rejects with the callback's own error",
			async run() {
				const db = await fresh();
				const failure = new Error("callback failed");
				let caught: unknown;
				try {
					await db.transaction(async (tx) => {
						await tx.run("INSERT INTO t (id, v) VALUES (?, ?)", 1, "x");
						await tx.run("INSERT INTO t (id, v) VALUES (?, ?)", 2, "y");
						throw failure;
					});
				} catch (error) {
					caught = error;
				}
				t.strictEqual(caught, failure);
				t.deepEqual(await db.get("SELECT count(*) AS n FROM t"), { n: 0 });
				await db.close();
			},
		},
		{
			name: "queues unrelated operations until the transaction finishes",
			async run() {
				const db = await fresh();
				const order: string[] = [];
				let release!: () => void;
				const gate = new Promise<void>((resolve) => (release = resolve));
				const transaction = db.transaction(async (tx) => {
					await tx.run("INSERT INTO t (id, v) VALUES (?, ?)", 1, "in-tx");
					order.push("tx-insert");
					await gate;
					order.push("tx-end");
				});
				// Issued while the transaction is open: must not run inside it, and must see its commit.
				const outside = db.get<{ n: number }>("SELECT count(*) AS n FROM t").then((row) => {
					order.push(`outside:${row?.n}`);
				});
				const second = db.transaction(async (tx) => {
					order.push("second-tx");
					await tx.run("INSERT INTO t (id, v) VALUES (?, ?)", 2, "second");
				});
				await new Promise((resolve) => setTimeout(resolve, 20));
				t.deepEqual(order, ["tx-insert"]);
				release();
				await Promise.all([transaction, outside, second]);
				t.deepEqual(order, ["tx-insert", "tx-end", "outside:1", "second-tx"]);
				t.deepEqual(await db.get("SELECT count(*) AS n FROM t"), { n: 2 });
				await db.close();
			},
		},
		{
			name: "expires the transaction handle once the callback settles",
			async run() {
				const db = await fresh();
				let leaked: { run(sql: string, ...p: never[]): Promise<void> } | undefined;
				await db.transaction(async (tx) => {
					leaked = tx as never;
				});
				await t.rejects(leaked!.run("INSERT INTO t (id, v) VALUES (1, 1)"), "no longer active");
				await db.close();
			},
		},
		{
			name: "rejects with a different error when rollback fails",
			async run() {
				const db = await fresh();
				let caught: unknown;
				try {
					await db.transaction(async (tx) => {
						// Ending the transaction early makes the facade's ROLLBACK fail.
						await tx.exec("COMMIT");
						throw new Error("callback failed");
					});
				} catch (error) {
					caught = error;
				}
				t.ok(caught instanceof AggregateError, `expected AggregateError, got ${String(caught)}`);
				await db.close();
			},
		},
		{
			name: "persists across close and reopen",
			async run() {
				const path = `${directory}/facade-reopen.sqlite`;
				const first = openIOSSqliteDatabase(path);
				await first.exec("CREATE TABLE IF NOT EXISTS t (id INTEGER PRIMARY KEY, v ANY) STRICT");
				await first.run("INSERT INTO t (id, v) VALUES (?, ?)", 1, "kept");
				await first.close();
				const second = openIOSSqliteDatabase(path);
				t.deepEqual(await second.get("SELECT v FROM t WHERE id = 1"), { v: "kept" });
				await second.close();
			},
		},
		{
			name: "rejects every operation after close, and close is idempotent",
			async run() {
				const db = await fresh();
				await db.close();
				await db.close();
				await t.rejects(db.get("SELECT 1"), "closed");
				await t.rejects(
					db.transaction(async () => {}),
					"closed",
				);
			},
		},
	];
}
