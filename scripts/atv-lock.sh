#!/bin/sh
# atv-lock.sh take|release|status: shared lock on the Apple TV between the
# sessions or developers working on it at the same time. File on the ATV:
# /var/mobile/Library/Caches/atv-lock = "<owner> <epoch>". A lock held by
# another owner and younger than 20 min blocks deploys and UI restarts;
# older, it is considered abandoned. "take" also refreshes our own lock.
. "$(dirname "$0")/atv-env.sh"
OWNER=${ATV_LOCK_OWNER:-plexatv3}
LOCK=/var/mobile/Library/Caches/atv-lock
case "$1" in
  take)
    $SSH "now=\$(date +%s); if [ -f $LOCK ]; then set -- \$(cat $LOCK); \
      if [ \"\$1\" != '$OWNER' ] && [ \$((now - \$2)) -lt 1200 ]; then \
        echo \"atv-lock: held by \$1 for \$(( (now - \$2) / 60 )) min\" >&2; exit 3; fi; fi; \
      echo '$OWNER' \$now > $LOCK" ;;
  release)
    $SSH "[ -f $LOCK ] && [ \"\$(cut -d' ' -f1 $LOCK)\" = '$OWNER' ] && rm -f $LOCK; true" ;;
  status)
    $SSH "cat $LOCK 2>/dev/null && echo now \$(date +%s) || echo free" ;;
  *) echo "usage: atv-lock.sh take|release|status" >&2; exit 2 ;;
esac
