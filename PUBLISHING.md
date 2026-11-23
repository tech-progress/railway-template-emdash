# Publishing

The current template release is `v1.0.0`. `EmDash App` builds `tech-progress/railway-template-emdash` from `release-v1` with root directory `/`; the `EmDash` gateway runs the pinned Caddy image.

1. `bun install --frozen-lockfile` and `./scripts/verify.sh`.
2. `./scripts/local-check.sh` (clean build, both smoke phases around a restart, log check, teardown).
3. Sync the public distribution repository (everything except `FINDINGS.md` and `node_modules`), run `./scripts/check-standalone.sh <checkout>`, tag `v<version>`, and fast-forward `release-v1`.
4. Create a project named `emdash-cms`, link it, and run `EMDASH_IAC_SEED=1 EMDASH_IAC_GATEWAY_PASSWORD=<fresh> EMDASH_IAC_ENCRYPTION_KEY=<fresh> railway config apply --yes`. Do not attach a domain to the source project.
5. `railway templates create --project <PROJECT_ID> --environment <ENVIRONMENT_ID> --json`, then `./scripts/restore-template-draft.sh <TEMPLATE_ID> <WORKSPACE_ID>` and `./scripts/audit-template.sh <TEMPLATE_ID>`.
6. `./scripts/deploy-stored-template.sh <TEMPLATE_ID> <WORKSPACE_ID>` deploys the stored `serializedConfig` with `templateDeployV2` into a disposable project. Read `GATEWAY_PASSWORD` from the deployed `EmDash` service into a 0600 file, run `node scripts/smoke.mjs` with `SMOKE_PHASE=initial` and `BASE_URL=https://<EmDash domain>`, redeploy both services, and run it with `SMOKE_PHASE=restart`. Check replicas, metrics, and that no credential appears in the logs.
7. Publish:

```bash
railway templates publish <TEMPLATE_ID> \
  --category CMS \
  --description "EmDash CMS blog on Node with SQLite, uploads volume and admin gateway" \
  --readme-file MARKETPLACE.md \
  --json
```

8. `./scripts/audit-template.sh <TEMPLATE_ID> PUBLISHED`. Add the template to the root `railway-template-metadata.json` (ID and code from the publish output, directory `emdash-cms`, distribution repository `tech-progress/railway-template-emdash`, category `CMS`, the description above, icon `https://github.com/emdash-cms.png`, and the EmDash, Astro and Caddy origins), then from the repository root run `scripts/sync-template-marketplace.sh emdash-cms` and `scripts/audit-template-marketplace.sh emdash-cms`; both must pass.
9. Stop and delete the source and verification projects, prove zero running instances, and tag `emdash-cms-v<version>` in the monorepo.
