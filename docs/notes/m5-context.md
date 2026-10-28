# M5: context in (share sheet and attachments)

Date: 2026-10-27. pi-durable / pi-ai / chord 1.4.0. Tested on the iPhone Air simulator (iOS 27.0) with DeepSeek
`deepseek-flash` (V4.1 Flash) and the offline `scripted/assistant` model. **Not yet run on the iPhone.** The Watch is
deferred ([ADR 0003](../adr/0003-defer-apple-watch.md)).

## Status

| Item | State | Tested by |
|---|---|---|
| Share extension (PiShare) | done: images (up to 10), text, one web link, files (text, JSON, source, PDF text); optional prompt; new or one of the 8 newest conversations; Send, or Open in Pi to Edit | simulator: a screenshot shared from Photos with "What is this" opened Pi, and DeepSeek described the screenshot |
| Composer attachments | done: + menu with Photos, Paste (images, links, text from the clipboard) and Files; chips with ✕; "This model can't see images" when it can't | simulator: pasted text sent with a question, and the answer used it |
| Transcript | done: thumbnails (tap for full size), text and link chips (a link opens) above the bubble; "Share sheet" origin label | simulator |
| Request IDs | `share:<id>`, `id` made once per share; an inbox item stays until sent, so a crash resends it as the same request | `ChatTests.attachments` checks content and display; inbox draft path on the simulator |

## How it fits together

- **Images** are downscaled in Swift (ImageIO, long edge 1568 px, JPEG 0.82), written to `<App Group>/attachments/`,
  and sent to JS as base64. They become `image` blocks in the user message, so they are in Pi storage once and in
  the request every turn (as any image in context is). The file stays for the transcript's thumbnail.
- **Text and links** go to the model as `<attachment kind="text" name="…">…</attachment>` and
  `<attachment kind="link" title="…">url</attachment>` text blocks after the typed text; each text is cut at 100,000
  characters.
- **Editing a queued message** (`PiRuntime.takeBack`) withdraws it and puts its text and attachments back in the
  composer: images by their files, links from the entry's data, texts out of their `<attachment>` tags in the content
  (a text over 100,000 characters comes back cut, as the model would have got it). An image whose file is gone is left
  out.
- **Sweeping image files**: once Pi is open, at most once a day, `ChatStore` deletes the files in `attachments/` that
  nothing points at and that are over a day old. Kept: images in a listed conversation's history (fork-aware, so a fork
  keeps its parent's), in queued messages, in the share inbox and in share drafts. The day of grace covers what is only
  in memory: images the share sheet saved before its inbox item is written, and the composer's. A removed conversation's
  images go with the next sweep. Tested on the simulator: an old orphan went, an old image in a conversation and a new
  orphan stayed.
- A message with attachments is an `app.input` entry whose data holds the typed text and the attachments' display form
  (no image data), so the bubble shows only what was typed. Steering and queued messages keep it.
- **Opening Pi from the extension**: extensions can't call `UIApplication.shared.open`; the extension finds the
  application on its responder chain and calls `openURL:options:completionHandler:`. That works on the iOS 27
  simulator. If iOS ever refuses, the extension says "Saved. Pi sends it the next time you open it", and the app
  picks the item up when it becomes active.
- The share sheet's conversation list is `<App Group>/inbox/conversations.json`, written by the app whenever its list
  changes.

## Not done / next

- Run on the iPhone: Photos, a Safari page, selected text in Notes, a PDF from Files; check the share extension's
  memory with 10 full-size photos (the limit is about 120 MB; images are decoded as thumbnails).
- PiShare is a third App ID on the free team (`dev.jcdiv47.pidurable.share`).
- No camera capture, no video or audio, no web page fetching (a link is just its URL and title).
- An "Ask Pi" Shortcuts action with a file parameter would add a path from Shortcuts; not built.
