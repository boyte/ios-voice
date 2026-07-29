#!/usr/bin/env bash
set -euo pipefail

TAG="${1:-}"
OUTPUT_DIR="${2:-dist}"

if [[ -z "$TAG" ]]; then
  echo "usage: $0 <tag> [output-directory]" >&2
  exit 2
fi

if [[ ! "$TAG" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "refusing non-semantic-version tag: $TAG (expected vMAJOR.MINOR.PATCH)" >&2
  exit 2
fi

if ! git rev-parse --verify --quiet "refs/tags/$TAG^{commit}" >/dev/null; then
  echo "tag does not resolve to a commit: $TAG" >&2
  exit 1
fi

TAG_COMMIT="$(git rev-parse --verify "refs/tags/$TAG^{commit}")"
HEAD_COMMIT="$(git rev-parse --verify HEAD)"
if [[ "$TAG_COMMIT" != "$HEAD_COMMIT" ]]; then
  echo "refusing to archive: HEAD is not the tagged commit" >&2
  echo "  tag $TAG: $TAG_COMMIT" >&2
  echo "  HEAD:     $HEAD_COMMIT" >&2
  exit 1
fi

if [[ -n "$(git status --porcelain)" ]]; then
  echo "refusing to archive a dirty worktree" >&2
  exit 1
fi

mkdir -p "$OUTPUT_DIR"
ARCHIVE="${OUTPUT_DIR}/AppLocalVoice-${TAG}.tar.gz"
CHECKSUM="${ARCHIVE}.sha256"

# Keep the tar stream and gzip header deterministic for a given commit. Git
# supplies stable member metadata from the commit; gzip -n omits the current
# filename and timestamp from the outer header.
git archive --format=tar --prefix="AppLocalVoice-${TAG}/" "$TAG" \
  | gzip -n > "$ARCHIVE"

# Write a relocatable checksum file: consumers can move the archive and its
# checksum together and run `shasum -a 256 -c ...` from that directory.
ARCHIVE_DIR="$(dirname "$ARCHIVE")"
ARCHIVE_NAME="$(basename "$ARCHIVE")"
(cd "$ARCHIVE_DIR" && shasum -a 256 "$ARCHIVE_NAME" > "${ARCHIVE_NAME}.sha256")
echo "source archive: $ARCHIVE"
echo "checksum: $CHECKSUM"
