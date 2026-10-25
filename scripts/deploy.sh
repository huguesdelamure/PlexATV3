#!/bin/sh
# deploy.sh <BundleName>: copy build/<BundleName>.frappliance to the Apple TV
# and restart the AppleTV UI. The old bundle is removed first: overwriting a
# signed binary in place makes the kernel kill it (stale signature cache).
# Rollback: ssh in, rm -rf /Applications/AppleTV.app/Appliances/<BundleName>.frappliance; killall AppleTV
set -e
. "$(dirname "$0")/atv-env.sh"
NAME=${1:?usage: deploy.sh <BundleName>}
DEST=/Applications/AppleTV.app/Appliances
# Refuses when another session holds the device (see atv-lock.sh); release
# with "scripts/atv-lock.sh release" at the end of a test series.
"$(dirname "$0")/atv-lock.sh" take
cd "$REPO_DIR/build"
COPYFILE_DISABLE=1 tar --no-xattrs -cf - "$NAME.frappliance" | $SSH "rm -rf $DEST/$NAME.frappliance && tar -C $DEST -xf - && chown -R root:wheel $DEST/$NAME.frappliance && killall AppleTV"
echo "deployed $NAME to $ATV_HOST, AppleTV restarting"
