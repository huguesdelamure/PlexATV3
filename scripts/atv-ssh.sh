#!/bin/sh
# Run a command on the Apple TV (key auth, shared connection).
. "$(dirname "$0")/atv-env.sh"
exec $SSH "$@"
