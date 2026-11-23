import { readFileSync } from "node:fs";
import { gzipSync } from "node:zlib";
import { defineRailway, github, group, project, service, volume } from "railway/iac";
import defaults from "../template-defaults.json" with { type: "json" };

// EmDash 1.6.0 (2026-11-22): upstream's blog template on the Astro Node
// adapter, built by the root Dockerfile of the public distribution repository
// from release-v1, with SQLite, uploads and sessions on one volume; Caddy is
// the password gateway and the only public service.
// Keep in sync with compose.yaml and the Dockerfile; scripts/verify.sh checks.
export const CADDY_IMAGE =
  "caddy:2.11.9-alpine@sha256:003a97808e781aa9f7e75cc2f43d34d461099031faf5e20faefb9f61126836f0";
// `railway templates create` rejects a repository source the Railway GitHub App
// cannot read, so the source project is applied with EMDASH_IAC_SEED=1 (this
// image, the same base the Dockerfile builds on) and restore-template-draft.sh
// puts the repository back into the draft.
export const APP_SEED_IMAGE =
  "node:24.22.3-trixie-slim@sha256:af02d57b57719b9657a45199a79264a9437940cd55b3c7b3fc99615654f124a0";
const APP_SOURCE = github("tech-progress/railway-template-emdash", { branch: "release-v1", rootDirectory: "/" });

// The gateway script is embedded byte for byte (gzip + base64) so no variable
// can replace it and the start command stays short.
const embed = (file: string) =>
  gzipSync(readFileSync(new URL(`../scripts/${file}`, import.meta.url)), { level: 9 }).toString("base64");
export const GATEWAY_START =
  `/bin/sh -ec "printf %s '${embed("gateway-start.sh")}' | base64 -d | gzip -dc >/tmp/gateway-start.sh; exec /bin/sh /tmp/gateway-start.sh"`;

// Credentials are never derived here: the IaC random-string helper is a public
// hash of its label. A disposable source project takes fresh values from
// EMDASH_IAC_<NAME> in the applying shell; without them they are empty and the
// services refuse to start. The marketplace draft is restored to the
// ${{secret()}} defaults in template-defaults.json.
const hostSecret = (key: string): string => (globalThis as any).process?.env?.[`EMDASH_IAC_${key}`] ?? "";
const seed = (globalThis as any).process?.env?.EMDASH_IAC_SEED === "1";

const restart = { restartPolicyType: "ON_FAILURE", restartPolicyMaxRetries: 10 } as const;

export default defineRailway(() => {
  const data = volume("EmDash Data", { sizeMB: 5_000 });

  const app = service("EmDash App", {
    ...(seed
      ? { source: { image: APP_SEED_IMAGE } }
      : {
          source: APP_SOURCE,
          build: { builder: "DOCKERFILE", dockerfilePath: "Dockerfile", watchPatterns: ["/Dockerfile", "/site/**", "/scripts/emdash-start.sh"] },
        }),
    healthcheck: "/_emdash/api/health",
    healthcheckTimeout: 300,
    volumeMounts: { "/data": data },
    deploy: restart,
    env: { ...defaults["EmDash App"], EMDASH_ENCRYPTION_KEY: hostSecret("ENCRYPTION_KEY") },
  });

  const gateway = service("EmDash", {
    source: { image: CADDY_IMAGE },
    start: GATEWAY_START,
    healthcheck: "/__gateway/health",
    healthcheckTimeout: 120,
    deploy: restart,
    env: { ...defaults.EmDash, GATEWAY_PASSWORD: hostSecret("GATEWAY_PASSWORD") },
  });

  return project("emdash-cms", {
    resources: [group("Web", [gateway]), group("Site", [app, data])],
  });
});
