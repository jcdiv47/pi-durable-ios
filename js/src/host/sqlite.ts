// chord's async `SqliteDatabase` facade over the Swift sqlite3 connection.
//
// Swift runs each statement synchronously on the JS queue (as node:sqlite does), so the facade only adds
// what the contract asks for: promise results, one transaction at a time, unrelated operations queued
// behind a running transaction, rollback on callback rejection, and expired transaction handles.
// The queue mirrors chord's NodeSqliteDatabase.

import type { SqliteDatabase, SqliteExecutor, SqliteValue } from "@earendil-works/chord/sqlite";
import { native } from "./native.ts";

const ignore = () => {};

/** Runs operations in call order; an async operation holds the queue until it settles. */
class SerialOperationQueue {
	#tail: Promise<unknown> = Promise.resolve();
	#pending = 0;

	run<T>(operation: () => T): Promise<T> {
		if (this.#pending > 0) return this.#enqueue(operation);
		try {
			return Promise.resolve(operation());
		} catch (error) {
			return Promise.reject(error);
		}
	}

	runAsync<T>(operation: () => Promise<T>): Promise<T> {
		if (this.#pending > 0) return this.#enqueue(operation);
		this.#pending++;
		// Publish the barrier before the operation starts, so calls it makes synchronously wait behind it.
		const { promise: barrier, resolve: releaseBarrier } = Promise.withResolvers<void>();
		this.#tail = barrier;
		let started: Promise<T>;
		try {
			started = operation();
		} catch (error) {
			started = Promise.reject(error);
		}
		return started.finally(() => {
			this.#pending--;
			releaseBarrier();
		});
	}

	#enqueue<T>(operation: () => T | Promise<T>): Promise<T> {
		this.#pending++;
		const settled = this.#tail.then(operation).finally(() => {
			this.#pending--;
		});
		this.#tail = settled.then(ignore, ignore);
		return settled;
	}
}

abstract class IOSSqliteExecutor implements SqliteExecutor {
	constructor(protected readonly handle: number) {}

	protected abstract runOperation<T>(operation: () => T): Promise<T>;

	exec(sql: string): Promise<void> {
		return this.runOperation(() => native.sqliteExec(this.handle, sql));
	}
	run(sql: string, ...params: SqliteValue[]): Promise<void> {
		return this.runOperation(() => native.sqliteRun(this.handle, sql, params));
	}
	get<T extends object>(sql: string, ...params: SqliteValue[]): Promise<T | undefined> {
		return this.runOperation(() => native.sqliteGet(this.handle, sql, params) as T | undefined);
	}
	all<T extends object>(sql: string, ...params: SqliteValue[]): Promise<T[]> {
		return this.runOperation(() => native.sqliteAll(this.handle, sql, params) as T[]);
	}
}

class IOSSqliteTransaction extends IOSSqliteExecutor {
	constructor(
		handle: number,
		private readonly scope: { active: boolean },
	) {
		super(handle);
	}
	protected async runOperation<T>(operation: () => T): Promise<T> {
		if (!this.scope.active) throw new Error("SQLite transaction handle is no longer active");
		return operation();
	}
}

export class IOSSqliteDatabase extends IOSSqliteExecutor implements SqliteDatabase {
	readonly #access = new SerialOperationQueue();
	#closed = false;

	transaction<T>(callback: (transaction: SqliteExecutor) => Promise<T>): Promise<T> {
		return this.#access.runAsync(async () => {
			this.#check();
			native.sqliteExec(this.handle, "BEGIN IMMEDIATE");
			const scope = { active: true };
			try {
				const result = await callback(new IOSSqliteTransaction(this.handle, scope));
				scope.active = false;
				native.sqliteExec(this.handle, "COMMIT");
				return result;
			} catch (error) {
				scope.active = false;
				try {
					native.sqliteExec(this.handle, "ROLLBACK");
				} catch (rollbackError) {
					throw new AggregateError([error, rollbackError], "SQLite transaction failed and rollback failed");
				}
				throw error;
			}
		});
	}

	close(): Promise<void> {
		return this.#access.run(() => {
			if (this.#closed) return;
			this.#closed = true;
			native.sqliteClose(this.handle);
		});
	}

	protected runOperation<T>(operation: () => T): Promise<T> {
		return this.#access.run(() => {
			this.#check();
			return operation();
		});
	}

	#check(): void {
		if (this.#closed) throw new Error("SQLite database is closed");
	}
}

/** Opens (creating if needed) a database file; Swift sets WAL and `synchronous = NORMAL`. */
export function openIOSSqliteDatabase(path: string): IOSSqliteDatabase {
	return new IOSSqliteDatabase(native.sqliteOpen(path));
}
