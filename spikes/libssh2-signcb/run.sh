#!/usr/bin/env bash
# Stand up a throwaway containerized sshd, generate an in-memory key, and
# prove libssh2 authenticates against it using our sign-callback. Tears the
# container down on exit. Usage: ./run.sh [ed25519|ecdsa]
set -euo pipefail

KT="${1:-ed25519}"
KEY="$(mktemp -t bsns-ssh-spike-key)"
AUTH="$(mktemp -t bsns-ssh-spike-auth)"
CONTAINER="bsns-ssh-spike-sshd"
cd "$(dirname "$0")"

cleanup() {
    docker rm -f "$CONTAINER" >/dev/null 2>&1 || true
    rm -f "$KEY" "$AUTH"
}
trap cleanup EXIT

echo "== building spike =="
swift build
BIN="$(swift build --show-bin-path)/ssh-signcb-spike"

echo "== generating in-memory $KT key + authorized_keys line =="
"$BIN" keygen "$KT" "$KEY" | tee "$AUTH"

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
sleep 3  # give sshd a moment past port-open to finish first-run setup

echo "== connecting via sign-callback =="
set +e
"$BIN" connect "$KT" "$KEY" 127.0.0.1 2222 spike
RC=$?
set -e
exit $RC
