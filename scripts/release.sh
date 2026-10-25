#!/bin/sh
# release.sh <version> [--publish]
#
# Builds a release locally (the toolchain cannot run on GitHub's runners:
# iOS 8.4 SDK and ld64-242 from Xcode 6.4 are not redistributable).
#
#   scripts/release.sh 1.0.0            checks + build/dist/PlexATV3-1.0.0.tar.gz
#   scripts/release.sh 1.0.0 --publish  same, then tag v1.0.0, push the tag and
#                                       create the GitHub release (gh CLI)
#
# Checks: version = CFBundleShortVersionString in App/Resources/Info.plist,
# a "## [<version>]" section in CHANGELOG.md, clean tree on main, tag unused.
set -e
cd "$(dirname "$0")/.."
VERSION=${1:?usage: release.sh <version> [--publish]}
PUBLISH=$2

plist=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' App/Resources/Info.plist)
[ "$plist" = "$VERSION" ] || { echo "Info.plist says $plist, not $VERSION" >&2; exit 1; }
grep -q "^## \[$VERSION\]" CHANGELOG.md || { echo "no '## [$VERSION]' section in CHANGELOG.md" >&2; exit 1; }
[ -z "$(git status --porcelain)" ] || { echo "uncommitted changes" >&2; exit 1; }
[ "$(git branch --show-current)" = main ] || { echo "not on main" >&2; exit 1; }
! git rev-parse -q --verify "refs/tags/v$VERSION" >/dev/null || { echo "tag v$VERSION exists" >&2; exit 1; }

make dist
ARCHIVE=build/dist/PlexATV3-$VERSION.tar.gz

# Release notes: the CHANGELOG section of this version + install steps.
NOTES=build/dist/notes-$VERSION.md
awk -v v="## [$VERSION]" 'index($0, v) == 1 { on = 1; next } /^## \[/ { on = 0 } on' CHANGELOG.md > "$NOTES"
cat >> "$NOTES" <<EOF

## Install

Requires a jailbroken Apple TV 3 on software 7.x with an appliance loader
(beigelist) and SSH access.

\`\`\`sh
scp PlexATV3-$VERSION.tar.gz root@<apple-tv>:/tmp/
ssh root@<apple-tv> 'cd /Applications/AppleTV.app/Appliances && rm -rf PlexATV3.frappliance && tar -xzf /tmp/PlexATV3-$VERSION.tar.gz && chown -R root:wheel PlexATV3.frappliance && killall AppleTV'
\`\`\`

SHA-256: \`$(cut -d' ' -f1 "$ARCHIVE.sha256")\`
EOF

if [ "$PUBLISH" != --publish ]; then
  echo "built $ARCHIVE (notes: $NOTES). Run again with --publish to tag and release."
  exit 0
fi

git tag -a "v$VERSION" -m "PlexATV3 $VERSION"
git push origin "v$VERSION"
gh release create "v$VERSION" "$ARCHIVE" "$ARCHIVE.sha256" --title "PlexATV3 $VERSION" --notes-file "$NOTES"
