# ADR 0010: Photo search with MobileCLIP

Date: 2026-11-04. Status: accepted. Spec: 0001, the "Later" list (Photos). Builds on
[ADR 0008](0008-apple-intelligence.md).

## Context

"Find the photo of the whiteboard from last week" is a common request. PhotoKit gives assets and their metadata
(dates, favorites, screenshots, location) but not the Photos app's own search index. Foundation Models (iOS 27) can
look at an image, but it generates text, has no embeddings, and takes seconds per image, too slow to scan a library.

MobileCLIP (Apple, CVPR 2024) maps images and text into the same 512-dimensional space. Apple publishes Core ML
exports (`apple/coreml-mobileclip` on Hugging Face). MobileCLIP-S2 is about 36M + 63M parameters (about 210 MB as
fp16) and takes a few milliseconds per image or query on an iPhone's Neural Engine. Its weights are under Apple's
sample code license, which is fine for this personal app but not for committing them to the repo.

## Decision

- **Tool `photos_search`** (Apple tools, `replay: "safe"`): a natural-language query, optional date range, favorites
  or screenshots only, and a limit. It returns the best matches: asset ID, date, flags and a similarity score, plus how
  much of the library is indexed. **No pixels, captions or locations go to the model**, so a cloud model learns only
  that matching photos exist and when they were taken. The chat draws the matches as a thumbnail grid
  (`PhotosCard`), read from the library on the device; tapping one shows it full size.
- **On-device index**: `PhotoIndex` (PiAppleTools) embeds every image asset once with the image encoder and keeps the
  vectors (Float16) and asset IDs in Application Support (`photo-index/`), never in the App Group or Pi storage. A
  search embeds the query with the text encoder and ranks by cosine similarity. New, changed and deleted assets are
  picked up incrementally. Images come from the device only (`isNetworkAccessAllowed = false`): an iCloud-only
  original is embedded from its local thumbnail.
- **When indexing runs**: in the foreground after launch while Photos access is granted; a first search indexes the
  newest few hundred photos before answering and says how far it got; and overnight in a `BGProcessingTask`
  (`dev.jcdiv47.pidurable.photos`, needs external power). Settings › Photo Search shows progress, and can index now or
  delete the index.
- **Permission**: Photos read access is requested the first time `photos_search` runs, in the handler, like the other
  Apple tools. Limited access indexes only the photos the user picked.
- **The model files are fetched, not committed**: `scripts/fetch-mobileclip.sh` downloads the S2 encoders and the
  CLIP BPE vocabulary into `App/Models/` (git-ignored); `project.yml` adds them as optional files, so a fresh clone
  still builds and the tool then says the model is missing. `PI_MOBILECLIP=s0` picks the smaller model.
- **Tokenizer**: CLIP's byte-level BPE, in Swift (`CLIPTokenizer`), 77 tokens with start and end markers.

## Consequences

- The app grows by about 210 MB (S2) or 110 MB (S0).
- Indexing a library of 20,000 photos takes on the order of ten minutes of foreground or charging time; the index is
  about 20 MB.
- The index reveals nothing new to the cloud, but Pi's transcript records the query and the dates of matches.
- Later: Foundation Models captions for the top matches, on device, so the agent can answer "what did the receipt
  say" (ADR 0008's image input, iOS 27); attaching a found photo to the conversation; video frames.
