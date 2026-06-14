#!/usr/bin/env bash
# Prove build-order step 3: a full SSH connection authenticated through the
# Agent (Agent -> FileKey -> SSHSession -> libssh2) against a throwaway
# containerized sshd. Tears the container down on exit.
set -euo pipefail

KEY="$(mktemp -t bsns-ssh-agent-key)"
AUTH="$(mktemp -t bsns-ssh-agent-auth)"
CONTAINER="bsns-ssh-agent-sshd"
cd "$(dirname "$0")"

cleanup() {
    docker rm -f "$CONTAINER" >/dev/null 2>&1 || true
    rm -f "$KEY" "$AUTH"
}
trap cleanup EXIT

echo "== building =="
swift build
BIN="$(swift build --show-bin-path)/ssh-signcb-spike"

echo "== generating a FileKey + authorized_keys line =="
"$BIN" agent-keygen "$KEY" | tee "$AUTH"

echo "== starting throwaway sshd (docker) on :2222 =="
docker rm -f "$CONTAINER" >/dev/null 2>&1 || true
docker run -d --name "$CONTAINER" -p 2222:2222 \
    -e PUID=1000 -e PGID=1000 \
    -e USER_NAME=spike -e PASSWORD_ACCESS=false \
    -e PUBLIC_KEY="$(cat "$AUTH")" \
    lscr.io/linuxserver/openssh-server:latest >/dev/null

echo "== waiting for sshd =="
for _ in $(seq 1 40); do
    if nc -z localhost 2222 2>/dev/null; then break; fi
    sleep 1
done
sleep 3

echo "== connecting through the Agent =="
"$BIN" agent-connect "$KEY" 127.0.0.1 2222 spike

echo "== running a command over the agent-authed channel =="
MARKER="BSNS_SSH_CHANNEL_OK"
set +e
OUT="$("$BIN" agent-exec "$KEY" 127.0.0.1 2222 spike "echo $MARKER; uname -s")"
RC=$?
set -e
echo "$OUT"
if [ "$RC" -eq 0 ] && echo "$OUT" | grep -q "$MARKER"; then
    echo "== STEP 3 OK: agent auth + host-key TOFU + channel exec =="
    exit 0
fi
echo "== STEP 3 FAILED (rc=$RC, marker not found) =="
exit 1
