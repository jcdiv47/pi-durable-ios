#!/usr/bin/env bash
# Downloads MobileCLIP's Core ML encoders and the CLIP tokenizer into App/Models/ (git-ignored), for photo search
# (docs/adr/0010-photo-search.md). Optional: without them the app downloads S2 in Settings › Photo Search
# (docs/adr/0011-download-mobileclip.md). Keep the file list in step with ClipModelDownload.files.
#
#   scripts/fetch-mobileclip.sh            # MobileCLIP-S2 (default)
#   PI_MOBILECLIP=s0 scripts/fetch-mobileclip.sh
#
# Weights: apple/coreml-mobileclip on Hugging Face, Apple's sample code license (apple-ascl). Tokenizer: OpenAI CLIP's
# BPE vocabulary (MIT), from openai/clip-vit-base-patch32.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VARIANT="${PI_MOBILECLIP:-s2}"
DEST="$ROOT/App/Models"
HF=https://huggingface.co
mkdir -p "$DEST"

fetch() { # url, path
	if [[ -s "$2" ]]; then return; fi
	mkdir -p "$(dirname "$2")"
	echo "  $2"
	curl -fL --retry 3 -o "$2.part" "$1"
	mv "$2.part" "$2"
}

# The app loads `MobileCLIPImage` and `MobileCLIPText`, whatever the variant.
for part in image text; do
	name="mobileclip_${VARIANT}_${part}"
	target="$DEST/MobileCLIP$(tr '[:lower:]' '[:upper:]' <<<"${part:0:1}")${part:1}.mlpackage"
	if [[ -f "$DEST/mobileclip-variant.txt" && "$(cat "$DEST/mobileclip-variant.txt")" != "$VARIANT" ]]; then rm -rf "$target"; fi
	for file in Manifest.json Data/com.apple.CoreML/model.mlmodel Data/com.apple.CoreML/weights/weight.bin; do
		fetch "$HF/apple/coreml-mobileclip/resolve/main/$name.mlpackage/$file" "$target/$file"
	done
done
echo "$VARIANT" >"$DEST/mobileclip-variant.txt"

fetch "$HF/openai/clip-vit-base-patch32/resolve/main/vocab.json" "$DEST/clip-vocab.json"
fetch "$HF/openai/clip-vit-base-patch32/resolve/main/merges.txt" "$DEST/clip-merges.txt"
echo "MobileCLIP-${VARIANT} is in App/Models. Run xcodegen generate, then build."
