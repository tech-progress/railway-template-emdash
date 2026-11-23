#!/bin/sh
# Start contract of the EmDash App service (the image's CMD; Compose runs the
# same file). It refuses a configuration that would leave setup unusable or the
# site on the wrong origin, gives the node user the volume, and runs the Astro
# Node server as that user.
set -eu

fail() { echo "emdash-start: $*" >&2; exit 64; }

DATA_DIR=/data

site_url="${EMDASH_SITE_URL:-}"
case "${site_url}" in
  https://?*) ;;
  http://localhost:* | http://127.0.0.1:*) ;;
  *) fail "EMDASH_SITE_URL must be the site's public https:// origin, for example https://\${{EmDash.RAILWAY_PUBLIC_DOMAIN}} (got '${site_url}')" ;;
esac
host_part="${site_url#*://}"
case "${host_part}" in
  '' | */* | *[!A-Za-z0-9.:-]*) fail "EMDASH_SITE_URL must be an origin with a host and no path (got '${site_url}')" ;;
esac

key="${EMDASH_ENCRYPTION_KEY:-}"
[ -n "${key}" ] || fail "EMDASH_ENCRYPTION_KEY is required; the template generates it"
# Comma-separated during rotation; each entry is emdash_enc_v1_ plus 43
# base64url characters. EmDash checks the decoded length itself at startup.
old_ifs="${IFS}"; IFS=,
for entry in ${key}; do
  body="${entry#emdash_enc_v1_}"
  [ "${body}" != "${entry}" ] || fail "every EMDASH_ENCRYPTION_KEY entry must start with emdash_enc_v1_"
  [ "${#body}" -eq 43 ] || fail "every EMDASH_ENCRYPTION_KEY entry needs 43 characters after emdash_enc_v1_"
  case "${body}" in *[!A-Za-z0-9_-]*) fail "EMDASH_ENCRYPTION_KEY may contain only base64url characters" ;; esac
  # 43 characters carry 258 bits for 32 bytes, so the last one must leave its
  # two low bits zero, or EmDash rejects the key as non-canonical and silently
  # disables secret plugin settings.
  case "${body}" in *[AEIMQUYcgkosw048]) ;; *) fail "EMDASH_ENCRYPTION_KEY is not canonical base64url of 32 bytes; generate one with npx emdash secrets generate" ;; esac
done
IFS="${old_ifs}"

case "${PORT:-}" in '' | *[!0-9]*) fail "PORT must be numeric" ;; esac

[ -d "${DATA_DIR}" ] || fail "${DATA_DIR} is missing; attach the EmDash volume there"
mkdir -p "${DATA_DIR}/uploads" "${DATA_DIR}/sessions"
cd /app
if [ "$(id -u)" = 0 ]; then
  # Railway mounts volumes owned by root. Hand everything on it to node, then
  # run the server without root.
  chown node:node "${DATA_DIR}" "${DATA_DIR}/uploads" "${DATA_DIR}/sessions"
  find "${DATA_DIR}" ! -user node -exec chown node:node {} +
  set -- setpriv --reuid=node --regid=node --init-groups --inh-caps=-all node ./dist/server/entry.mjs
else
  set -- node ./dist/server/entry.mjs
fi

# This shell stays PID 1 and forwards SIGTERM and SIGINT. Node as PID 1 would
# ignore them (the kernel drops default-action signals to PID 1), so every
# stop would wait for SIGKILL; as a child it exits on them, after EmDash's own
# handler saves any open co-editing rooms.
"$@" &
child=$!
trap 'kill -TERM "${child}" 2>/dev/null || true' TERM
trap 'kill -INT "${child}" 2>/dev/null || true' INT
set +e
wait "${child}"
status=$?
while kill -0 "${child}" 2>/dev/null; do
  wait "${child}"
  status=$?
done
exit "${status}"
