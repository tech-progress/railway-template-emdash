#!/usr/bin/env bash
# Container tests of the two start contracts, with the pinned images:
# - emdash-start.sh refuses a missing or non-origin EMDASH_SITE_URL, a missing
#   or malformed EMDASH_ENCRYPTION_KEY, and a missing /data, with exit 64;
# - gateway-start.sh refuses weak or malformed settings with exit 64, and in
#   both GATEWAY_ADMIN_GATE modes guards exactly the intended paths.
# Uses docker or podman, bounded memory, no network beyond loopback.
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
engine="$(command -v docker || command -v podman)" || { echo "docker or podman required" >&2; exit 1; }
pin() { grep -A1 "^export const $1 =\$" "${root}/.railway/railway.ts" | tail -n 1 | sed -E 's/^ *"(.*)";$/\1/'; }
caddy="$(pin CADDY_IMAGE)"; node="$(pin APP_SEED_IMAGE)"
failures=0
bad() { echo "FAIL: $*" >&2; failures=$((failures + 1)); }
key="emdash_enc_v1_$(printf 'A%.0s' $(seq 1 43))"

app_case() { # expected-exit label env...
  local expected="$1" label="$2"; shift 2
  local args=() status=0
  for kv in "$@"; do args+=(-e "${kv}"); done
  "${engine}" run --rm --memory 128m --network none -v "${root}/scripts/emdash-start.sh:/s.sh:ro,Z" "${args[@]}" \
    --entrypoint /bin/sh "${node}" -c 'mkdir -p /data; exec /bin/sh /s.sh' >/dev/null 2>&1 || status=$?
  [[ "${status}" == "${expected}" ]] || bad "app: ${label}: exit ${status}, want ${expected}"
}
site=EMDASH_SITE_URL=https://blog.example.com
app_case 64 "no site URL" "EMDASH_ENCRYPTION_KEY=${key}" PORT=4321
app_case 64 "empty host" EMDASH_SITE_URL=https:// "EMDASH_ENCRYPTION_KEY=${key}" PORT=4321
app_case 64 "site URL with path" EMDASH_SITE_URL=https://blog.example.com/x "EMDASH_ENCRYPTION_KEY=${key}" PORT=4321
app_case 64 "plain http public URL" EMDASH_SITE_URL=http://blog.example.com "EMDASH_ENCRYPTION_KEY=${key}" PORT=4321
app_case 64 "no key" "${site}" PORT=4321
app_case 64 "short key" "${site}" EMDASH_ENCRYPTION_KEY=emdash_enc_v1_AAAA PORT=4321
app_case 64 "wrong prefix" "${site}" "EMDASH_ENCRYPTION_KEY=x${key}" PORT=4321
app_case 64 "bad second key" "${site}" "EMDASH_ENCRYPTION_KEY=${key},${key}+" PORT=4321
app_case 64 "bad port" "${site}" "EMDASH_ENCRYPTION_KEY=${key}" PORT=abc
status=0
"${engine}" run --rm --memory 128m --network none -v "${root}/scripts/emdash-start.sh:/s.sh:ro,Z" -e "${site}" -e "EMDASH_ENCRYPTION_KEY=${key}" -e PORT=4321 \
  --entrypoint /bin/sh "${node}" /s.sh >/dev/null 2>&1 || status=$?
[[ "${status}" == 64 ]] || bad "app: missing /data: exit ${status}, want 64"

password=Abcdefghijkmnpqrstuvwxyz2345678
gw_env=(-e PORT=8080 -e GATEWAY_USERNAME=admin -e GATEWAY_ADMIN_GATE=admin -e EMDASH_APP_ADDRESS=127.0.0.1:9 -e GATEWAY_TRUSTED_PROXIES=100.64.0.0/10)
gw_case() { # label env-overrides...
  local label="$1"; shift
  local args=() status=0
  for kv in "$@"; do args+=(-e "${kv}"); done
  "${engine}" run --rm --memory 128m --network none -v "${root}/scripts/gateway-start.sh:/s.sh:ro,Z" "${gw_env[@]}" "${args[@]}" \
    "${caddy}" /bin/sh /s.sh >/dev/null 2>&1 || status=$?
  [[ "${status}" == 64 ]] || bad "gateway: ${label}: exit ${status}, want 64"
}
gw_case "no password"
gw_case "short password" GATEWAY_PASSWORD=Short1234567890
gw_case "symbol in password" "GATEWAY_PASSWORD=${password}!"
gw_case "bad username" "GATEWAY_PASSWORD=${password}" "GATEWAY_USERNAME=ad min"
gw_case "bad gate mode" "GATEWAY_PASSWORD=${password}" GATEWAY_ADMIN_GATE=off
gw_case "address without port" "GATEWAY_PASSWORD=${password}" EMDASH_APP_ADDRESS=app.railway.internal
gw_case "bad proxies" "GATEWAY_PASSWORD=${password}" "GATEWAY_TRUSTED_PROXIES=0.0.0.0/0;x"

# Both modes: which paths need the credential. The upstream address is a
# closed port, so an ungated path answers 502 and a gated one 401.
for mode in admin setup; do
  name="emdash-gw-test-$$-${mode}"
  "${engine}" run -d --name "${name}" --memory 128m -p 127.0.0.1::8080 -v "${root}/scripts/gateway-start.sh:/s.sh:ro,Z" "${gw_env[@]}" \
    -e "GATEWAY_PASSWORD=${password}" -e "GATEWAY_ADMIN_GATE=${mode}" "${caddy}" /bin/sh /s.sh >/dev/null
  port="$("${engine}" port "${name}" 8080 | head -n 1 | sed 's/.*://')"
  for _ in $(seq 1 30); do curl -fsS -o /dev/null "http://127.0.0.1:${port}/__gateway/health" 2>/dev/null && break; sleep 1; done
  code() { curl -s -o /dev/null -w '%{http_code}' --path-as-is "$@"; }
  [[ "$(code "http://127.0.0.1:${port}/_emdash/api/setup")" == 401 ]] || bad "${mode}: setup API is not gated"
  [[ "$(code -u "admin:${password}" "http://127.0.0.1:${port}/_emdash/api/setup")" == 502 ]] || bad "${mode}: credential does not pass the setup gate"
  [[ "$(code -u "admin:wrong${password}" "http://127.0.0.1:${port}/_emdash/api/setup")" == 401 ]] || bad "${mode}: wrong password passes"
  [[ "$(code "http://127.0.0.1:${port}/")" == 502 ]] || bad "${mode}: the public site is gated"
  [[ "$(code "http://127.0.0.1:${port}/_emdash/api/content/posts")" == 502 ]] || bad "${mode}: the token API is gated"
  [[ "$(code "http://127.0.0.1:${port}/_emdash/api/x/../setup")" == 400 ]] || bad "${mode}: a dot segment is not refused"
  admin="$(code "http://127.0.0.1:${port}/_emdash/admin")"
  if [[ "${mode}" == admin ]]; then [[ "${admin}" == 401 ]] || bad "admin: the admin panel is not gated"
  else [[ "${admin}" == 502 ]] || bad "setup: the admin panel is gated"; fi
  if "${engine}" logs "${name}" 2>&1 | grep -qF "${password}"; then bad "${mode}: the password reached the log"; fi
  "${engine}" rm -f "${name}" >/dev/null
done

(( failures == 0 )) || { echo "start guard tests failed: ${failures}" >&2; exit 1; }
echo "Start guard tests passed."
