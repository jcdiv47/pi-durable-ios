# ADR 0008: Apple Intelligence

Date: 2026-11-04. Status: accepted. Spec: 0001, "Non-goals (v1)" (on-device LLMs) and the "Later" list
(Foundation Models provider). Supersedes that non-goal.

## Context

The spec left on-device models out of v1 and named a Foundation Models provider "for cheap jobs (titles, routing)" as
a later idea. The iPhone Air runs iOS 27.2 with Apple Intelligence on. The SDK (Xcode 27) offers:

- `SystemLanguageModel` (iOS 26+): the on-device model. Its context is 4096 tokens on iOS 26; on iOS 27
  `contextSize` reports the real value. `tokenCount(for:)` exists from iOS 26.4.
- `PrivateCloudComputeLanguageModel` (iOS 27+, watchOS 27+): a larger model on Apple's Private Cloud Compute, with a
  quota (`quotaUsage`, `Error.quotaLimitReached`) and no API key. It needs a **managed entitlement** Apple grants on
  request ("Accessing Private Cloud Compute"), which the free Personal Team can't get.
- Neither model exists on watchOS 26, so a later Watch app gets no model of its own.

Both run without a key and without sending data to a third party. Both are weak at tool use compared with the cloud
providers, and the on-device model's context is far smaller than Pi's system prompt and tool list.

## Decision

### A model provider, `apple`

- Provider `apple` in pi-ai, with one model now: `apple/on-device` ("Apple Intelligence (on device)"). It shows in
  the model picker only while `SystemLanguageModel.availability` is `.available`. Swift passes the available models
  and their context sizes to JS (`PiRuntime.setAppleModels`), so a second model is a Swift change only.
- **Private Cloud Compute is not built**: it needs the managed entitlement. With a paid account and the entitlement,
  it becomes `apple/private-cloud` behind `#available(iOS 27)` and `PrivateCloudComputeLanguageModel.isAvailable`,
  through the same endpoint.
- **Swift serves them as an OpenAI-compatible endpoint in the process**: `JSRuntime.Options.localHosts` maps a
  host (`apple-intelligence.pi.local`) to a Swift handler, and the fetch bridge hands requests for that host to it
  instead of URLSession. Nothing for that host ever reaches the network. JS registers the provider with pi-ai's
  `openai-completions` API and that base URL, so streaming, abort, Pi's idle timeout and resending a cut-off request
  on resume work as for every other provider, with no new JS↔Swift channel.
- The handler (`AppleIntelligence` in PiRuntime) turns the chat request into a Foundation Models transcript and
  streams the answer back as SSE chunks, with estimated usage.
- **Text only, no tools.** The models are registered with text input; pi-ai replaces images with a placeholder.
  Tools in the request are ignored and the model never calls one. Pi's system prompt (tool sections, surfaces,
  skills) is replaced with short instructions written for these models: who Pi is, today's date, that it has no tools
  and should say so when a request needs one, plus the user's AGENTS.md if it fits. Older messages are dropped until
  the transcript fits the context (counted with `tokenCount` where available, else about 3 characters a token),
  keeping room for the answer. Earlier tool calls and results become short text lines.
- Errors become provider errors the transcript shows: guardrail refusals, an unsupported language, context still too
  large.

### Cheap jobs on the on-device model

- **Conversation titles.** A new conversation still gets the first line of its first message at once; then the
  on-device model writes a short title, which replaces it if the user hasn't renamed the conversation meanwhile. JS
  asks Swift through `hostCall("intelligence.title")`.
- **Notification summaries.** When a run finishes in the background, its notification body is a one- or two-sentence
  summary of the answer instead of its first 400 characters, if the answer is long.
- Both are on by default when the model is available (Settings › Apple Intelligence), and fall back to the old
  behavior when it is off, unavailable, slow (a few seconds) or refuses.

### Suggested later use cases

Not built in this change, roughly in order of value:

1. **Offline fallback**: when a cloud request fails with no network, offer to answer the turn on device.
2. **Routing**: classify a prompt (needs tools or web, needs a big model, small talk) and pick the conversation's
   model, or skip the cloud for small talk.
3. **Private pre-processing**: summarize a `web_fetch` page, a shared PDF or a long note on device before it goes to
   the cloud model, saving tokens and keeping raw text local.
4. **Dictation clean-up**: tidy the transcription in the composer (punctuation, filler words) before sending.
5. **Glance text for the Watch and widgets**: a one-line summary of a conversation's last answer or a surface's
   values for `accessoryInline` (and a later Watch app), written on the phone.
6. **Spotlight keywords** for conversations (`IndexedEntity`), and tags for the conversation list.
7. **Quick replies** on notifications for finished runs ("Thanks", a follow-up question).
8. **Writing Tools** in the composer: the system feature, enabled with `writingToolsBehavior(.complete)`.
9. **Tool calling on device**, once the context and tool use are good enough: map a small subset of Pi's tools
   (calendar, reminders) to Foundation Models tools with dynamic schemas.

## Consequences

- The non-goal "On-device LLMs" is narrowed to MLX and other bundled models.
- PiRuntime links FoundationModels (iOS 26 and macOS 26, so `swift test` covers the request translation).
- An `apple/*` conversation can't use tools, widgets or the web; the model is told so and says so. Switching its
  model to a cloud one restores them.
- Requests to the `apple` models are not counted by `ServiceUsage`.
