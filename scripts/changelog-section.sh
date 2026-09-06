#!/usr/bin/env bash
# Prints the CHANGELOG.md section for one version, without its heading.
#
#   scripts/changelog-section.sh 0.1.0
#
# Used by the release workflow so the published notes and the changelog cannot
# drift apart.
set -euo pipefail

VERSION="${1:?usage: changelog-section.sh <version>}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

awk -v version="$VERSION" '
    # Section starts at "## [1.2.3]" and ends at the next "## " heading.
    $0 ~ "^## \\[" version "\\]" { found = 1; next }
    found && /^## / { exit }
    found { print }
' "$ROOT/CHANGELOG.md" | sed -e '/./,$!d' | awk 'NF {blank=0} !NF {blank++} blank<2'

if ! grep -q "^## \[$VERSION\]" "$ROOT/CHANGELOG.md"; then
    echo "No CHANGELOG.md section for $VERSION" >&2
    exit 1
fi
