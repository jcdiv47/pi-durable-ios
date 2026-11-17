#!/usr/bin/env bash
# Releases a version: sets MARKETING_VERSION in project.yml, adds one to CURRENT_PROJECT_VERSION (the build
# number), regenerates the Xcode project, commits project.yml and tags the commit v<version>.
# Nothing is pushed; the script prints the commands for that.
#
#   scripts/release.sh 0.2        # 0.1 (1) -> 0.2 (2), tag v0.2
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SPEC="$ROOT/project.yml"
fail() { printf '\033[31mFAIL: %s\033[0m\n' "$*" >&2; exit 1; }
log() { printf '\033[1m==> %s\033[0m\n' "$*" >&2; }

version=${1:?usage: release.sh <version>, e.g. release.sh 0.2}
tag="v$version"
[[ $version =~ ^[0-9]+(\.[0-9]+){1,2}$ ]] || fail "$version is not a version like 1.2 or 1.2.3"

cd "$ROOT"
git diff --quiet HEAD -- project.yml || fail "project.yml has uncommitted changes; commit or stash them first"
! git rev-parse -q --verify "refs/tags/$tag" >/dev/null || fail "tag $tag already exists"

current=$(sed -n -E 's/^ *MARKETING_VERSION: "(.*)"/\1/p' "$SPEC")
build=$(sed -n -E 's/^ *CURRENT_PROJECT_VERSION: "(.*)"/\1/p' "$SPEC")
[[ -n $current && $build =~ ^[0-9]+$ ]] || fail "could not read the version settings in project.yml"
[[ $version != "$current" ]] || fail "project.yml is already at $version"
build=$((build + 1))

sed -i '' -E \
	-e "s/^( *MARKETING_VERSION: )\".*\"/\1\"$version\"/" \
	-e "s/^( *CURRENT_PROJECT_VERSION: )\".*\"/\1\"$build\"/" "$SPEC"
xcodegen generate --quiet

git commit --quiet -m "Release $version ($build)" -- project.yml
git tag -a "$tag" -m "Pi $version ($build)"
log "Released $version ($build) as $tag (from $current)"
printf 'To publish: git push origin HEAD %s && gh release create %s --generate-notes\n' "$tag" "$tag" >&2
