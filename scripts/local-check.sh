#!/usr/bin/env bash
# Clean-state local verification with Docker Compose (or podman-compose):
# build, start, initial smoke, restart both services, restart smoke, check that
# no generated secret reaches a container log, print memory, then remove the
# containers and volume. Secrets are generated into a private temporary
# directory and never printed.
# Usage: ./scripts/local-check.sh
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${root}"
if command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
  compose=(docker compose); engine=docker
else
  compose=(podman-compose); engine=podman
fi
port="${EMDASH_LOCAL_PORT:-18080}"
export EMDASH_LOCAL_PORT="${port}"
work="$(mktemp -d)"
chmod 700 "${work}"
# A bounded read: no reader closes a pipe early, so pipefail stays quiet.
random_alnum() {
  local chars
  chars="$(head -c 4096 /dev/urandom | LC_ALL=C tr -dc 'A-Za-z0-9')"
  (( ${#chars} >= $1 )) || { echo "local-check: not enough random characters" >&2; exit 1; }
  printf '%s' "${chars:0:$1}"
}
GATEWAY_PASSWORD="$(random_alnum 32)"
EMDASH_ENCRYPTION_KEY="emdash_enc_v1_$(random_alnum 42)A"
export GATEWAY_PASSWORD EMDASH_ENCRYPTION_KEY
( umask 077; printf '%s\n' "${GATEWAY_PASSWORD}" > "${work}/gateway-password" )
cleanup() {
  "${compose[@]}" down -v >/dev/null 2>&1 || true
  rm -rf "${work:?}"
}
trap cleanup EXIT

wait_healthy() {
  local deadline=$((SECONDS + 180))
  until curl -fsS -o /dev/null "http://127.0.0.1:${port}/_emdash/api/health"; do
    (( SECONDS < deadline )) || { echo "local-check: EmDash did not become healthy" >&2; return 1; }
    sleep 2
  done
}

"${compose[@]}" down -v >/dev/null 2>&1 || true
"${compose[@]}" build
"${compose[@]}" up -d
wait_healthy
smoke() {
  BASE_URL="http://localhost:${port}" GATEWAY_PASSWORD_FILE="${work}/gateway-password" \
    SMOKE_STATE="${work}/state.json" SMOKE_PHASE="$1" node scripts/smoke.mjs
}
smoke initial

container_of() {
  "${engine}" ps -q --filter label=com.docker.compose.project=emdash-cms --filter "label=com.docker.compose.service=$1" | head -n 1
}
app="$(container_of emdash-app)"
gateway="$(container_of emdash)"
[[ -n "${app}" && -n "${gateway}" ]] || { echo "local-check: containers not found" >&2; exit 1; }
started=$SECONDS
"${engine}" stop -t 15 "${app}" >/dev/null
echo "local-check: the app stopped in $((SECONDS - started)) s after SIGTERM"
"${engine}" start "${app}" >/dev/null
"${engine}" restart "${gateway}" >/dev/null
wait_healthy
smoke restart

for container in "${app}" "${gateway}"; do
  if "${engine}" logs "${container}" 2>&1 | grep -qF -e "${GATEWAY_PASSWORD}" -e "${EMDASH_ENCRYPTION_KEY#emdash_enc_v1_}"; then
    echo "local-check: a generated secret appeared in a container log" >&2
    exit 1
  fi
done
echo "local-check: no generated secret in the container logs"
server_identity="$("${engine}" exec "${app}" sh -c 'for p in /proc/[0-9]*; do if tr "\0" " " <"$p/cmdline" 2>/dev/null | grep -q "^node ./dist/server/entry.mjs"; then grep -E "^(Uid|CapEff):" "$p/status"; fi; done')"
grep -Eq '^Uid:[[:space:]]+1000[[:space:]]' <<<"${server_identity}" && grep -Eq '^CapEff:[[:space:]]+0+$' <<<"${server_identity}" \
  || { echo "local-check: the Node server is not running as node without capabilities" >&2; exit 1; }
echo "local-check: the Node server runs as UID 1000 with no capabilities"
"${engine}" stats --no-stream --format '{{.Name}} {{.MemUsage}}' "${app}" "${gateway}"
echo "local-check: PASS"
