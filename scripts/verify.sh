#!/usr/bin/env bash
# Static verification: files, version, pins, start contracts, IaC graph, the
# draft contract and Compose/Railway parity. Needs bun's node_modules, jq and
# node; never prints secret values.
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fail() { echo "FAIL: $*" >&2; exit 1; }

for file in .dockerignore .env.example .gitignore .railway/railway.ts CHANGELOG.md Dockerfile LICENSE_REVIEW.md MARKETPLACE.md PUBLISHING.md README.md SUPPORT.md UPGRADE.md VERSION bun.lock compose.yaml package.json \
  template-defaults.json template-descriptions.json template-networking.json template-volumes.json \
  site/package.json site/package-lock.json site/astro.config.mjs site/LICENSE site/seed/seed.json \
  scripts/audit-template.sh scripts/check-standalone.sh scripts/deploy-stored-template.sh scripts/emdash-start.sh scripts/gateway-start.sh scripts/local-check.sh scripts/project-status.sh \
  scripts/restore-template-draft.sh scripts/smoke.mjs scripts/test-draft-contract.sh scripts/test-start-guards.sh scripts/wait-deployment.sh scripts/fixtures/draft.json; do
  [[ -f "${root}/${file}" ]] || fail "missing ${file}"
done

version="$(<"${root}/VERSION")"
[[ "${version}" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || fail "VERSION is not SemVer"
grep -Eq "^## ${version//./\\.} - [0-9]{4}-[0-9]{2}-[0-9]{2}$" "${root}/CHANGELOG.md" || fail "CHANGELOG has no entry for ${version}"
for file in README.md PUBLISHING.md; do grep -Fq "current template release is \`v${version}\`" "${root}/${file}" || fail "${file} does not name v${version}"; done

for file in "${root}"/template-*.json "${root}/package.json" "${root}/site/package.json" "${root}/scripts/fixtures/draft.json"; do jq empty "${file}"; done
for file in "${root}"/scripts/*.sh; do bash -n "${file}"; done
for file in emdash-start.sh gateway-start.sh; do sh -n "${root}/scripts/${file}"; done
node --check "${root}/scripts/smoke.mjs"
! grep -Eq '^VOLUME' "${root}/Dockerfile" || fail "Railway rejects Dockerfile VOLUME"

# The site: upstream's blog template on emdash 1.6.0, exact pins, one volume.
jq -e '.dependencies.emdash=="1.6.0" and .dependencies.astro=="7.4.13" and .dependencies["@astrojs/node"]=="11.1.14"' "${root}/site/package.json" >/dev/null || fail "site dependency pins"
jq -e '[.dependencies[], .devDependencies[]]|all(test("^[0-9]+\\.[0-9]+\\.[0-9]+$"))' "${root}/site/package.json" >/dev/null || fail "site dependencies must be exact versions"
jq -e '.packages["node_modules/emdash"].version=="1.6.0" and .packages["node_modules/astro"].version=="7.4.13"' "${root}/site/package-lock.json" >/dev/null || fail "package-lock.json does not resolve the pinned versions"
grep -Fxq 'const dataDir = process.env.EMDASH_DATA_DIR || "/data";' "${root}/site/astro.config.mjs" || fail "the data directory must default to /data"
grep -Fq 'database: sqlite({ url: `file:${dataDir}/emdash.db` })' "${root}/site/astro.config.mjs" || fail "the database must live in the data directory"
grep -Fq 'directory: `${dataDir}/uploads`' "${root}/site/astro.config.mjs" || fail "uploads must live in the data directory"
grep -Fq 'driver: sessionDrivers.fsLite({ base: `${dataDir}/sessions` })' "${root}/site/astro.config.mjs" || fail "sessions must live in the data directory"
! grep -q 'EMDASH_DATA_DIR' "${root}/Dockerfile" || fail "the image build must not take EMDASH_DATA_DIR"
grep -q 'Copyright 2026 Cloudflare Inc.' "${root}/site/LICENSE" || fail "site/LICENSE is not upstream's MIT notice"

# Image pins: the IaC, the Dockerfile and Compose agree.
pin() { grep -A1 "^export const $1 =\$" "${root}/.railway/railway.ts" | tail -n 1 | sed -E 's/^ *"(.*)";$/\1/'; }
caddy_image="$(pin CADDY_IMAGE)"; node_image="$(pin APP_SEED_IMAGE)"
for image in "${caddy_image}" "${node_image}"; do [[ "${image}" =~ :[^@]+@sha256:[0-9a-f]{64}$ ]] || fail "${image} is not pinned by tag and digest"; done
[[ "$(grep -c "^FROM ${node_image} AS build\$\|^FROM ${node_image}\$" "${root}/Dockerfile")" == 2 ]] || fail "both Dockerfile stages must use APP_SEED_IMAGE"
grep -Fxq "    image: ${caddy_image}" "${root}/compose.yaml" || fail "compose.yaml does not use CADDY_IMAGE"

graph="$(cd "${root}" && env -i PATH="${PATH}" HOME="${HOME}" ./node_modules/.bin/railway-iac-ts .railway/railway.ts </dev/null)"
jq -e '.ok==true' <<<"${graph}" >/dev/null || fail "IaC graph did not compile"
svc() { jq -c --arg n "$1" '.graph.resources[]|select(.type=="service" and .name==$n)' <<<"${graph}"; }
jq -e '([.graph.resources[]|select(.type=="service")|.name]|sort)==["EmDash","EmDash App"]' <<<"${graph}" >/dev/null || fail "IaC service set"
jq -e '([.graph.resources[]|select(.type=="volume")]|length)==1' <<<"${graph}" >/dev/null || fail "IaC volume count"
jq -e '[.graph.resources[]|select(.type=="service")|(.domains // .networking // empty)]|length==0' <<<"${graph}" >/dev/null || fail "the source graph must not create domains"
jq -e --arg img "${caddy_image}" '.source.image==$img and .deploy.healthcheckPath=="/__gateway/health"' <<<"$(svc EmDash)" >/dev/null || fail "EmDash gateway source or health check"
jq -e '.source.repo=="tech-progress/railway-template-emdash" and .source.branch=="release-v1" and .source.rootDirectory=="/" and .build.builder=="DOCKERFILE" and .build.dockerfilePath=="Dockerfile" and .deploy.healthcheckPath=="/_emdash/api/health" and (.deploy.startCommand // null)==null' <<<"$(svc "EmDash App")" >/dev/null || fail "EmDash App source, build or health check"
seeded="$(cd "${root}" && env -i PATH="${PATH}" HOME="${HOME}" EMDASH_IAC_SEED=1 ./node_modules/.bin/railway-iac-ts .railway/railway.ts </dev/null)"
jq -e --arg img "${node_image}" '.graph.resources[]|select(.name=="EmDash App")|.source.image==$img and .build==null' <<<"${seeded}" >/dev/null || fail "the seeded app must use the base image only"
for name in EmDash "EmDash App"; do
  jq -e '.deploy.restartPolicyType=="ON_FAILURE" and .deploy.restartPolicyMaxRetries==10' <<<"$(svc "${name}")" >/dev/null || fail "${name} restart policy"
done

# The gateway start command embeds scripts/gateway-start.sh byte for byte.
start="$(jq -r '.deploy.startCommand' <<<"$(svc EmDash)")"
embedded="$(sed -E "s/^\/bin\/sh -ec \"printf %s '([A-Za-z0-9+\/=]+)' \| base64 -d \| gzip -dc >\/tmp\/gateway-start.sh; exec \/bin\/sh \/tmp\/gateway-start.sh\"$/\1/" <<<"${start}")"
[[ "${embedded}" != "${start}" ]] && cmp -s <(base64 -d <<<"${embedded}" | gzip -dc) "${root}/scripts/gateway-start.sh" || fail "the gateway start command is not scripts/gateway-start.sh"
(( ${#start} < 4000 )) || fail "the gateway start command is too long for Railway"
grep -Fq 'command: ["/bin/sh", "/srv/gateway-start.sh"]' "${root}/compose.yaml" || fail "compose.yaml does not run scripts/gateway-start.sh"
grep -Fq 'COPY scripts/emdash-start.sh /usr/local/bin/emdash-start' "${root}/Dockerfile" && grep -Fq 'CMD ["/usr/local/bin/emdash-start"]' "${root}/Dockerfile" || fail "the image does not run scripts/emdash-start.sh"

# The source graph never derives a credential; the draft defaults generate them.
for pair in "EmDash:GATEWAY_PASSWORD" "EmDash App:EMDASH_ENCRYPTION_KEY"; do
  name="${pair%%:*}"; key="${pair#*:}"
  [[ "$(jq -r --arg k "${key}" '.variables[$k].value' <<<"$(svc "${name}")")" == "" ]] || fail "IaC derives ${name} ${key} without EMDASH_IAC_*"
done
jq -e '.EmDash.GATEWAY_PASSWORD|test("^\\$\\{\\{secret\\(32, \"[A-Za-z0-9]+\"\\)\\}\\}$")' "${root}/template-defaults.json" >/dev/null || fail "gateway password default"
# 42 random base64url characters and a final A decode to 32 canonical bytes.
jq -e '.["EmDash App"].EMDASH_ENCRYPTION_KEY|test("^emdash_enc_v1_\\$\\{\\{secret\\(42, \"[A-Za-z0-9]+\"\\)\\}\\}A$")' "${root}/template-defaults.json" >/dev/null || fail "encryption key default"
jq -e '.["EmDash App"].EMDASH_SITE_URL=="https://${{EmDash.RAILWAY_PUBLIC_DOMAIN}}" and .EmDash.EMDASH_APP_ADDRESS=="${{EmDash App.RAILWAY_PRIVATE_DOMAIN}}:4321"' "${root}/template-defaults.json" >/dev/null || fail "service references"
jq -e '.EmDash.GATEWAY_ADMIN_GATE=="admin"' "${root}/template-defaults.json" >/dev/null || fail "the admin panel must be gated by default"
jq -e '[.[]|to_entries[]|select(.value=="")]|length==0' "${root}/template-defaults.json" >/dev/null || fail "no default may be empty"
jq -e --slurpfile d "${root}/template-defaults.json" '. as $s | (keys==($d[0]|keys)) and ([keys[] | ($s[.]|keys)==($d[0][.]|keys)]|all)' "${root}/template-descriptions.json" >/dev/null || fail "template-defaults.json and template-descriptions.json keys differ"
for name in EmDash "EmDash App"; do
  jq -e --arg n "${name}" --argjson v "$(svc "${name}" | jq -c '.variables|keys')" '.[$n]|keys==$v' "${root}/template-defaults.json" >/dev/null || fail "${name} IaC variables differ from template-defaults.json"
done
jq -e 'keys==["EmDash"] and .EmDash.publicPort==8080' "${root}/template-networking.json" >/dev/null || fail "only the gateway may be public"
jq -e 'keys==["EmDash App"] and .["EmDash App"]=={"mountPath":"/data","sizeMB":5000}' "${root}/template-volumes.json" >/dev/null || fail "template-volumes.json"
jq -e '[.graph.edges[]|select(.from=="service.EmDash App" and .type=="mount" and .key=="/data")]|length==1' <<<"${graph}" >/dev/null || fail "the app volume is not mounted at /data"

# Compose uses the same literal settings.
for pair in "EMDASH_TRUSTED_PROXY_HEADERS: x-real-ip" 'GATEWAY_TRUSTED_PROXIES: 100.64.0.0/10' 'EMDASH_APP_ADDRESS: emdash-app:4321' 'PORT: "4321"' 'PORT: "8080"' 'HOST: "::"' 'GATEWAY_USERNAME: admin'; do
  grep -Fq "      ${pair}" "${root}/compose.yaml" || fail "compose.yaml lacks ${pair}"
done

# Offline tests of the draft contract and the start-script refusals.
"${root}/scripts/test-draft-contract.sh" >/dev/null || fail "scripts/test-draft-contract.sh failed"
if [[ "${SKIP_CONTAINER_TESTS:-0}" != 1 ]]; then
  "${root}/scripts/test-start-guards.sh" >/dev/null || fail "scripts/test-start-guards.sh failed"
fi
echo "EmDash template verification passed (v${version})."
