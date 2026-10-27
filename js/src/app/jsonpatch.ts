// RFC 6902 JSON Patch over plain JSON values, for `patch_surface`. Returns a new value; the input is never
// changed, so a failed patch leaves the stored spec as it was. Errors name the operation for the model.

export type PatchOperation = {
	op: "add" | "remove" | "replace" | "move" | "copy" | "test";
	path: string;
	value?: unknown;
	from?: string;
};

export class PatchError extends Error {}

function parsePointer(pointer: string): string[] {
	if (pointer === "") return [];
	if (!pointer.startsWith("/")) throw new PatchError(`"${pointer}" is not a JSON Pointer; it must start with "/", e.g. "/slots/0/goal"`);
	return pointer
		.slice(1)
		.split("/")
		.map((token) => token.replace(/~1/g, "/").replace(/~0/g, "~"));
}

type Container = Record<string, unknown> | unknown[];

function isContainer(value: unknown): value is Container {
	return typeof value === "object" && value !== null;
}

function index(array: unknown[], token: string, allowEnd: boolean): number {
	if (allowEnd && token === "-") return array.length;
	if (!/^(0|[1-9][0-9]*)$/.test(token)) throw new PatchError(`"${token}" is not an array index`);
	const at = Number(token);
	if (at > array.length || (!allowEnd && at === array.length)) throw new PatchError(`index ${at} is out of range (length ${array.length})`);
	return at;
}

/** The container holding the pointer's last token, and that token. */
function parent(root: unknown, tokens: string[], pointer: string): { container: Container; key: string } {
	let current = root;
	for (const token of tokens.slice(0, -1)) {
		if (Array.isArray(current)) current = current[index(current, token, false)];
		else if (isContainer(current) && Object.hasOwn(current, token)) current = (current as Record<string, unknown>)[token];
		else throw new PatchError(`${pointer}: no value at "${token}"`);
	}
	if (!isContainer(current)) throw new PatchError(`${pointer}: the parent is not an object or array`);
	return { container: current, key: tokens[tokens.length - 1]! };
}

function get(root: unknown, pointer: string): unknown {
	let current = root;
	for (const token of parsePointer(pointer)) {
		if (Array.isArray(current)) current = current[index(current, token, false)];
		else if (isContainer(current) && Object.hasOwn(current, token)) current = (current as Record<string, unknown>)[token];
		else throw new PatchError(`${pointer}: no value at "${token}"`);
	}
	return current;
}

function add(root: unknown, pointer: string, value: unknown): unknown {
	const tokens = parsePointer(pointer);
	if (tokens.length === 0) return value;
	const { container, key } = parent(root, tokens, pointer);
	if (Array.isArray(container)) container.splice(index(container, key, true), 0, value);
	else container[key] = value;
	return root;
}

function remove(root: unknown, pointer: string): unknown {
	const tokens = parsePointer(pointer);
	if (tokens.length === 0) throw new PatchError("cannot remove the whole spec");
	const { container, key } = parent(root, tokens, pointer);
	if (Array.isArray(container)) container.splice(index(container, key, false), 1);
	else if (Object.hasOwn(container, key)) delete container[key];
	else throw new PatchError(`${pointer}: nothing to remove`);
	return root;
}

export function applyPatch<T>(document: T, operations: readonly PatchOperation[]): T {
	let root: unknown = structuredClone(document);
	operations.forEach((operation, at) => {
		const where = `operation ${at} (${operation.op} ${operation.path})`;
		try {
			switch (operation.op) {
				case "add":
					root = add(root, operation.path, structuredClone(operation.value));
					break;
				case "remove":
					root = remove(root, operation.path);
					break;
				case "replace":
					get(root, operation.path);
					if (operation.path === "") {
						root = structuredClone(operation.value);
						break;
					}
					root = add(remove(root, operation.path), operation.path, structuredClone(operation.value));
					break;
				case "move": {
					if (operation.from === undefined) throw new PatchError("move needs from");
					const value = get(root, operation.from);
					root = add(remove(root, operation.from), operation.path, value);
					break;
				}
				case "copy":
					if (operation.from === undefined) throw new PatchError("copy needs from");
					root = add(root, operation.path, structuredClone(get(root, operation.from)));
					break;
				case "test":
					if (JSON.stringify(get(root, operation.path)) !== JSON.stringify(operation.value)) throw new PatchError("test failed");
					break;
				default:
					throw new PatchError(`unknown op ${(operation as { op: string }).op}`);
			}
		} catch (error) {
			throw new PatchError(`${where}: ${error instanceof Error ? error.message : String(error)}`);
		}
	});
	return root as T;
}
