#!/usr/bin/env bash
# Moves a provider API key into PiApp's Keychain (debug builds) without putting it on a command line:
# the file is copied into the app container, and the app imports and deletes it on its next launch.
#
#   scripts/push-key.sh deepseek <file-containing-the-key>      # booted simulator
#   PI_DEVICE=<udid> scripts/push-key.sh deepseek <file>        # iPhone
source "$(dirname "$0")/lib.sh"

provider=${1:?usage: push-key.sh <provider> <key file>}
file=${2:?usage: push-key.sh <provider> <key file>}
[[ -s "$file" ]] || fail "$file is empty or missing"
name="import-$provider.key"
if [[ $TARGET == simulator ]]; then
	directory="$(xcrun simctl get_app_container "$UDID" "$BUNDLE_ID" data)/Documents/m0"
	mkdir -p "$directory"
	(umask 077 && cp "$file" "$directory/$name")
else
	xcrun devicectl device copy to --device "$UDID" --domain-type appDataContainer \
		--domain-identifier "$BUNDLE_ID" --source "$file" --destination "Documents/m0/$name" >/dev/null
fi
log "Copied the $provider key into the app container; the next launch moves it into the Keychain"
