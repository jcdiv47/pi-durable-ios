# ADR 0014: Code Mode

Date: 2026-11-09. Status: accepted, built. Spec: 0001, "Risks and open questions" (Code Mode). Builds on
[ADR 0005](0005-pi-1.5.md).

## Context

The spec left open whether Pi Durable's Code Mode (`@earendil-works/pi-durable/codemode`) is worth using. The model
writes JavaScript that calls the conversation's tools as `await tools.<name>(args)`. Only what the script prints reaches
the model, not every tool result. That suits the questions the app gets: "which of my reminders are overdue and on
which list", "which guests didn't back up", "steps per day this week". The model would otherwise make many tool calls
and read every result into its context.

The pinned pi-durable 1.5.0 ships it. Scripts run in QuickJS compiled to WebAssembly (`@earendil-works/pi-codemode`).
The tool journals each result it hands a script, so after a restart it runs the script again and hands back the same
results. The script makes the same calls, which reattach to their nested tool calls, and then it carries on live. That
is the kill-test property, for scripts.

What had to be checked here:

- **WebAssembly in a bare JSContext with no JIT.** It is there on the iPhone Air (iOS 27.3) and in the simulator with
  `JSC_useJIT=false`. The M0 capabilities check (`webAssembly`) records it.
- **JSC's async WebAssembly API never settles on the JS queue.** `WebAssembly.compile` and `instantiate` resolve from
  the thread's run loop, and `JSRuntime.queue` is a dispatch queue with none. The synchronous `Module` and `Instance`
  constructors work.
- **JSC will not pin a WebAssembly memory buffer.** `JSObjectGetArrayBufferBytesPtr` fails on it, so
  `__native.utf8Decode` read every string QuickJS hands out (tool names, results, errors) as empty. Its view pointer
  (`JSObjectGetTypedArrayBytesPtr`) points at the wrong bytes.
- **Worker threads** don't exist in JSContext, so `CodemodeSandbox` (Node, Bun) is out.

## Decision

- **The `codemode` extension, in every conversation**, next to the app's other tools; the model keeps its direct tools.
  `src/app/codemode.ts` builds it over `InlineCodemodeSandbox`, which runs the VM on the JS queue. A script that
  computes holds the queue until it awaits a tool or uses up its interrupt budget (the default, 100,000 polls). Heap:
  64 MB.
- **QuickJS is a bundle resource, read on the first script.** `build.ts` copies `quickjs.wasm` (622 KB) next to the
  bundles. JS reads it with `__native.readResource(name)`, which reads only plain file names in the bundle's directory
  (`JSRuntime.Options.resourceDirectory`, set by `PiHarness.load`). A launch that runs no script never reads or parses
  it, and `pi-runtime.js` grows by about 108 KB.
- **Polyfill:** `WebAssembly.compile` and `instantiate` wrap the synchronous constructors (`polyfills.ts`).
- **`JSBytes`:** when JSC will not pin a buffer, it reads through a `slice()` copy, and writes go into a copy that
  `set()` puts back. That also covers `crypto.getRandomValues` into QuickJS's memory, from its WASI shim.
- **Approvals are unchanged.** A script's call of an "ask" tool goes through the same `beforeTool` gate. Its request
  carries the `codemode` call's ID (`modelCallId`, approvals.ts), because the transcript never shows a nested call ID
  (`<call ID>/c<n>`). So the inline card appears on the `codemode` row. It names the script's tool and its arguments.
  A denial rejects inside the script with the declined message, and the script can catch it.
- **No `models.*` in scripts** (`models: false`). `models.classify()` and `models.generateImages()` would spend the
  user's keys outside the tools the user sees. Turn them on later if a use comes up.
- **Namespaces** for the tool listing and `searchTools()`: `mcp__` (MCP servers), `pve_`, `ssh_`.
- The tool appears in Settings' tool list (`codeModeToolInfo`), where its policy can be set to "deny".

## Consequences

- On the iPhone Air (`m0-check.sh measure`), each of the offline model's `code` round trips (prompt, script, answer)
  took 0.30 s for the first script, which includes compiling QuickJS, and 0.23 s warm. A 100,000-iteration loop in the
  script took 0.50 s. Memory footprint went up 3 MB.
- Cards (Apple tools, `pve_*`, photos) come from top-level results. A script's nested calls draw none; the model gets
  the script's output only.
- `web_fetch` and `ssh_exec` skip approval only for calls the conversation already "trusts", judged from the
  transcript. What a script read never reaches the transcript, so a script's call of either always asks. A
  `codemode` result counts as outside text too, so later direct `ssh_exec` calls ask as well (`untrustedText`).
- The VM's fingerprint includes the heap limit and the interrupt budget. Changing either, or upgrading pi-codemode or
  quickjs-wasi, makes a script that a restart finds running end with an error instead of replaying.
- With no execution environment, a result cut to its token budget can't spill to a file. The model sees the cut text
  and a note that the file could not be written.
