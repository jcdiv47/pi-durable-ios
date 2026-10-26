// Bundles the JS that runs inside JavaScriptCore:
//   src/runtime.ts      → App/Resources/pi-runtime.js                         (the app's harness bootstrap)
//   src/conformance.ts  → Packages/PiRuntime/Tests/PiRuntimeTests/Resources/  (storage conformance, test-only)
// Usage: bun build.ts [--minify=false] [--sourcemap]

import { mkdirSync, statSync, writeFileSync } from "node:fs";
import { dirname, join, relative } from "node:path";
import * as esbuild from "esbuild";

const root = join(import.meta.dir, "..");
const minify = !process.argv.includes("--minify=false");
const sourcemap = process.argv.includes("--sourcemap");

const targets = [
	{ entry: "src/runtime.ts", out: join(root, "App/Resources/pi-runtime.js") },
	{ entry: "src/conformance.ts", out: join(root, "Packages/PiRuntime/Tests/PiRuntimeTests/Resources/pi-conformance.js") },
	{ entry: "src/runtime.ts", out: join(root, "Packages/PiRuntime/Tests/PiRuntimeTests/Resources/pi-runtime.js") },
];

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
	});
	mkdirSync(join(import.meta.dir, "dist"), { recursive: true });
	writeFileSync(join(import.meta.dir, "dist", `${target.out.split("/").slice(-2).join("_")}.meta.json`), JSON.stringify(result.metafile));
	const kb = (statSync(target.out).size / 1024).toFixed(0);
	console.log(`${relative(root, target.out)}  ${kb} KB`);
}
