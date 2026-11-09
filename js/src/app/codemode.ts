// Code Mode (docs/adr/0014-code-mode.md): the `codemode` tool, where the model writes JavaScript that calls the
// conversation's other tools as `await tools.<name>(args)`, and only the script's output reaches the model. Pi's
// extension (`@earendil-works/pi-durable/codemode`) journals every result the script gets, so a script a kill
// interrupts resumes where it was; each nested call is a tool call of its own, with its own replay policy and the
// approval gate in front of it.
//
// The script runs in QuickJS compiled to WebAssembly, on the JS queue (`InlineCodemodeSandbox`: no worker threads in
// JSContext). QuickJS is a bundle resource (`quickjs.wasm`, copied by build.ts), compiled on the first script, so a
// launch that runs none never reads it.

import { InlineCodemodeSandbox } from "@earendil-works/pi-codemode/portable";
import type { CodemodeWasmModule } from "@earendil-works/pi-codemode/portable";
import { CODEMODE_TOOL_NAME, createCodemodeExtension } from "@earendil-works/pi-durable/codemode";
import { native } from "../host/native.ts";

let compiled: Promise<CodemodeWasmModule> | undefined;

function quickjs(): Promise<CodemodeWasmModule> {
	compiled ??= (async () => {
		const bytes = native.readResource("quickjs.wasm");
		if (bytes === null) throw new Error("quickjs.wasm is missing from the app bundle");
		if (typeof WebAssembly !== "object") throw new Error("WebAssembly is not available in this JavaScriptCore");
		return (await WebAssembly.compile(bytes as Uint8Array<ArrayBuffer>)) as CodemodeWasmModule;
	})();
	// A failed load is tried again by the next script.
	compiled.catch(() => {
		compiled = undefined;
	});
	return compiled;
}

/** Awaited by the launcher at every script's start: compiles QuickJS on the first. */
const lazyWasm: PromiseLike<CodemodeWasmModule> = {
	then: (resolve, reject) => quickjs().then(resolve, reject),
};

const sandbox = new InlineCodemodeSandbox({
	wasm: lazyWasm as Promise<CodemodeWasmModule>,
	// The VM's heap. Part of the VM's fingerprint: changing it fails scripts a restart finds running.
	memoryLimitBytes: 64 * 1024 * 1024,
});

export const CodeModeTools = createCodemodeExtension({
	sandbox,
	namespaces: [
		{ name: "mcp", prefix: "mcp__", description: "Tools of the user's MCP servers, named mcp__<server>__<tool>." },
		{ name: "proxmox", prefix: "pve_", description: "Read-only views of the user's Proxmox VE node." },
		{ name: "ssh", prefix: "ssh_", description: "Commands on the user's SSH hosts." },
	],
	// No `models.classify()` or `models.generateImages()`: scripts spend nothing on the user's keys but through tools.
	models: false,
});

export const codeModeToolInfo = [
	{
		name: CODEMODE_TOOL_NAME,
		description: "Runs a JavaScript script that calls Pi's other tools and returns only what the script prints.",
	},
];
