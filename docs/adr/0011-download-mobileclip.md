# ADR 0011: Download MobileCLIP in the app

Date: 2026-11-04. Status: accepted. Changes how [ADR 0010](0010-photo-search.md) gets the model files.

## Context

ADR 0010 builds MobileCLIP-S2 into the app: `scripts/fetch-mobileclip.sh` downloads it into `App/Models/` before
the build. Every install to the iPhone then copies about 200 MB, a fresh clone needs the script before photo search
works, and an interrupted script leaves a half-downloaded `.mlpackage` that breaks the build.

## Decision

- **Settings › Photo Search downloads the model** (`ClipModelDownload` in PiAppleTools) into Application Support
  (`mobileclip/s2/`), excluded from iCloud backups. It is kept across app updates and reinstalls over Xcode, and goes
  only when the app is deleted or the user taps Remove Model.
- **Pinned and checked**: the same eight files as the script (both encoders' `.mlpackage` parts and CLIP's
  `vocab.json` and `merges.txt`), from fixed Hugging Face commits, each checked against its size and SHA-256 before
  use. A file that doesn't match is deleted and the download fails.
- **Compiled on the device**: `MLModel.compileModel(at:)` compiles both encoders into a staging folder, which is
  loaded once and then renamed into place, so `mobileclip/s2/` is either complete or absent. The `.mlpackage`s are
  then deleted.
- **A background `URLSession`** (`dev.jcdiv47.pidurable.mobileclip`), Wi-Fi only (`allowsExpensiveNetworkAccess` and
  `allowsConstrainedNetworkAccess` off): the transfers go on while Pi is suspended or not running, and iOS relaunches
  Pi in the background when they finish (`PiAppDelegate`'s `handleEventsForBackgroundURLSession`). Each task's
  description is its file's path, so a finished transfer delivered to a new launch still lands in staging. Settings
  shows "Waiting for Wi-Fi" from an `NWPathMonitor`. Checking and compiling need Pi running: when the transfers finish
  while Pi is away, it does them the next time it opens (`ClipModelDownload.resumeIfStarted`, from `ChatStore`
  start), as long as a `requested` marker says the user started the download and didn't cancel it. Files already
  checked are kept when a download fails; a failed file resumes from its resume data within the same launch.
- **Bundled models win**: a build that ran `scripts/fetch-mobileclip.sh` uses its own files and shows no download.
  The script stays for the simulator and the PiAppleTools tests. Both name the index's model `mobileclip-s2`, so
  switching between them keeps the index.
- `PhotoIndex` looks for the model each time until it finds one, so a finished download is used without relaunching.
  When the download finishes, indexing starts.

## Consequences

- The app is about 200 MB smaller, and photo search works only after a one-time download.
- The model is usable only after Pi is next open, when the transfers finished in the background; compiling there
  takes seconds.
- The simulator runs background sessions too, but the relaunch path is only worth checking on the iPhone.
- Only S2 is offered in the app; `PI_MOBILECLIP=s0` still builds S0 in.
