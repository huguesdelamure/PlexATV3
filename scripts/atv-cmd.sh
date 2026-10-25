#!/bin/sh
# Send a command to the debug channel of a DEBUG build, e.g.: atv-cmd.sh key right
# ATV_APP selects the app (default PlexATV3): /var/mobile/Library/Caches/$ATV_APP/cmd
. "$(dirname "$0")/atv-env.sh"
APP=${ATV_APP:-PlexATV3}
for i in 1 2 3 4 5; do
  $SSH "echo '$*' >> /var/mobile/Library/Caches/$APP/cmd" && exit 0
  echo "atv-cmd: retry $i" >&2; sleep 3
done
exit 1
