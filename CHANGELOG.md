# Changelog

## 1.0.1 - 2026-11-23

- The app refuses an `EMDASH_SITE_URL` with an empty host or an empty port (for example `https://:`) at start instead of failing later. The start-guard tests name Docker Hub images in full, so they run on Podman without a cached image. No change to services or variables.

## 1.0.0 - 2026-11-23

- Initial Railway template for EmDash 1.6.0: upstream's blog template on Astro 7 with the Node adapter, SQLite, uploaded media and sign-in sessions on one volume, EmDash's in-process scheduler, and a Caddy gateway that keeps the admin panel and first-run setup behind a generated password.
