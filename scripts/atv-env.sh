# Sourced by the other scripts: loads .env (repo root, else its parent) and
# defines $SSH / $SCP. Variables: ATV_HOST, ATV_USER (root), ATV_SSH_KEY.
# Key auth with connection sharing: sshd on the ATV is slow to accept new
# connections for ~1 min after the UI restarts.
REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
for f in "$REPO_DIR/.env" "$REPO_DIR/../.env"; do [ -f "$f" ] && { . "$f"; break; }; done
ATV_HOST=${ATV_HOST:?set ATV_HOST (Apple TV address) in .env}
ATV_USER=${ATV_USER:-root}
SSH_OPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR \
 -o HostKeyAlgorithms=+ssh-rsa -o ConnectTimeout=30 -o ServerAliveInterval=15 \
 -o ControlMaster=auto -o ControlPath=/tmp/atv-cm-%r@%h -o ControlPersist=1800 -o BatchMode=yes"
[ -n "$ATV_SSH_KEY" ] && SSH_OPTS="$SSH_OPTS -o IdentitiesOnly=yes -i $ATV_SSH_KEY"
SSH="ssh $SSH_OPTS $ATV_USER@$ATV_HOST"
SCP="scp -q -O $SSH_OPTS"
