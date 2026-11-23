# Upgrades

1. Back up the `/data` volume (stop `EmDash App` first so the SQLite copy is consistent) and keep `EMDASH_ENCRYPTION_KEY` with it.
2. Read the [EmDash release notes](https://github.com/emdash-cms/emdash/releases) and the [updating guide](https://docs.emdashcms.com/deployment/updating/) for migration notes.
3. In `site/`, set the new exact versions of `emdash` and the Astro packages in `package.json` (compare with upstream's `templates/blog` at the new release tag), run `npm install` to refresh `package-lock.json`, and update the Node and Caddy pins in `Dockerfile`, `compose.yaml` and `.railway/railway.ts` together. Bump `VERSION` and `CHANGELOG.md`.
4. Run `./scripts/verify.sh` and `./scripts/local-check.sh`.
5. Tag the release, fast-forward `release-v1`, and let Railway rebuild `EmDash App`.

EmDash applies pending database migrations on the first request after a start. It cannot be downgraded in place; restore the volume backup to roll back.
