#!/bin/sh
# Send a command to the debug channel of a DEBUG build, e.g.: atv-cmd.sh key right
# ATV_APP selects the app (default PlexATV3): /var/mobile/Library/Caches/$ATV_APP/cmd
# Refused (exit 3) while another owner holds the device lock (atv-lock.sh):
# remote key presses would land in someone else's test.
. "$(dirname "$0")/atv-env.sh"
APP=${ATV_APP:-PlexATV3}
OWNER=${ATV_LOCK_OWNER:-plexatv3}
LOCK=/var/mobile/Library/Caches/atv-lock
for i in 1 2 3 4 5; do
  $SSH "now=\$(date +%s); if [ -f $LOCK ]; then set -- \$(cat $LOCK); \
    if [ \"\$1\" != '$OWNER' ] && [ \$((now - \$2)) -lt 1200 ]; then echo \"atv-cmd: device held by \$1\" >&2; exit 3; fi; fi; \
    echo '$*' >> /var/mobile/Library/Caches/$APP/cmd"
  rc=$?
  [ $rc -eq 0 ] && exit 0
  [ $rc -eq 3 ] && exit 3
  echo "atv-cmd: retry $i" >&2; sleep 3
done
exit 1
