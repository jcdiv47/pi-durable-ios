// Bundles the JS that runs inside JavaScriptCore:
//   src/runtime.ts      → App/Resources/pi-runtime.js      (the app's harness bootstrap)
//   src/conformance.ts  → App/Resources/pi-conformance.js  (conformance suites, run by `-PiMode conformance`)
//   both                → Packages/PiRuntime/Tests/PiRuntimeTests/JS/ (for `swift test`)
//   quickjs.wasm        → next to each bundle: Code Mode's sandbox, read on its first script (src/app/codemode.ts)
// Usage: bun build.ts [--minify=false] [--sourcemap]

import { copyFileSync, mkdirSync, statSync, writeFileSync } from "node:fs";
import { dirname, join, relative } from "node:path";
import * as esbuild from "esbuild";

const root = join(import.meta.dir, "..");
const minify = !process.argv.includes("--minify=false");
const sourcemap = process.argv.includes("--sourcemap");

const targets = [
	{ entry: "src/runtime.ts", out: join(root, "App/Resources/pi-runtime.js") },
	{ entry: "src/conformance.ts", out: join(root, "App/Resources/pi-conformance.js") },
	{ entry: "src/conformance.ts", out: join(root, "Packages/PiRuntime/Tests/PiRuntimeTests/JS/pi-conformance.js") },
	{ entry: "src/runtime.ts", out: join(root, "Packages/PiRuntime/Tests/PiRuntimeTests/JS/pi-runtime.js") },
];

// pi-mcp in JSC. Its index exports the stdio transport, which needs Node's child_process; the app can't start processes
// (ADR 0006), so that module is a stub. And its SSE reader counts bytes with Node's `Buffer.byteLength`: a global
// `Buffer` would send the provider SDKs down their Node paths (they test `typeof Buffer` and then call `Buffer.from`), so
// that one module gets its own.
const piMcp: esbuild.Plugin = {
	name: "pi-mcp",
	setup(build) {
		build.onResolve({ filter: /^\.\/transports\/stdio\.js$/ }, (args) =>
			/[\\/]@earendil-works[\\/]pi-mcp[\\/]dist[\\/]index\.js$/.test(args.importer) ? { path: "pi-mcp-stdio", namespace: "pi-mcp-stub" } : undefined,
		);
		build.onLoad({ filter: /.*/, namespace: "pi-mcp-stub" }, () => ({
			contents: 'export class StdioTransport { constructor() { throw new Error("stdio MCP servers need a process; the app has none"); } }',
			loader: "js",
		}));
		build.onLoad({ filter: /[\\/]@earendil-works[\\/]pi-mcp[\\/]dist[\\/]transports[\\/]streamable-http\.js$/ }, async (args) => {
			const source = await Bun.file(args.path).text();
			if (!source.includes("Buffer.byteLength")) throw new Error("pi-mcp no longer uses Buffer.byteLength; drop the pi-mcp-buffer plugin");
			const shim = "const Buffer = { byteLength: (text) => new TextEncoder().encode(text).byteLength };\n";
			return { contents: shim + source, loader: "js", resolveDir: dirname(args.path) };
		});
	},
};

for (const target of targets) {
	mkdirSync(dirname(target.out), { recursive: true });
	const result = await esbuild.build({
		entryPoints: [join(import.meta.dir, target.entry)],
		outfile: target.out,
		bundle: true,
		format: "iife",
		// The `browser` condition and field swap the Anthropic SDK's Node internals for its fetch-only ones.
		platform: "browser",
		// JavaScriptCore on iOS 26 supports ES2024 natively; esbuild lowers anything newer.
		target: "safari26",
		minify,
		keepNames: true,
		sourcemap: sourcemap ? "inline" : false,
		legalComments: "none",
		metafile: true,
		logLevel: "warning",
		define: { "process.env.NODE_ENV": '"production"' },
		plugins: [piMcp],
	});
	mkdirSync(join(import.meta.dir, "dist"), { recursive: true });
	writeFileSync(join(import.meta.dir, "dist", `${target.out.split("/").slice(-2).join("_")}.meta.json`), JSON.stringify(result.metafile));
	const kb = (statSync(target.out).size / 1024).toFixed(0);
	console.log(`${relative(root, target.out)}  ${kb} KB`);
}

// Code Mode's QuickJS: a resource, not part of the bundle, so a launch that runs no script never parses it.
const wasm = join(import.meta.dir, "node_modules/quickjs-wasi/quickjs.wasm");
for (const dir of new Set(targets.map((target) => dirname(target.out)))) {
	copyFileSync(wasm, join(dir, "quickjs.wasm"));
	console.log(`${relative(root, join(dir, "quickjs.wasm"))}  ${(statSync(wasm).size / 1024).toFixed(0)} KB`);
}
