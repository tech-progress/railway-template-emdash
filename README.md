# EmDash CMS on Railway

The current template release is `v1.0.1`. It runs [EmDash](https://github.com/emdash-cms/emdash) `1.6.0` (its blog template on [Astro](https://astro.build) 7 with the Node adapter) behind a [Caddy](https://caddyserver.com) `2.11.9` gateway. Node and Caddy images are pinned by digest, and the site's npm dependencies are pinned by `site/package-lock.json`.

EmDash is a TypeScript CMS built on Astro: content types, a rich-text editor, media library, menus, taxonomies, scheduled publishing, full-text search, comments, plugins, a REST API and an MCP server, with passkey sign-in. Most EmDash deployment guides target Cloudflare Workers; this template runs the same CMS as a long-running Node server on Railway with SQLite and local media storage.

## Topology

| Service | Public | Source | Purpose |
| --- | --- | --- | --- |
| `EmDash` | yes, port 8080 | `caddy:2.11.9-alpine` by digest | The only public entry. Serves the site, media and EmDash's token-authenticated APIs. Asks for the generated gateway password before the admin panel (`/_emdash/admin`) and the first-run setup API (`/_emdash/api/setup`). |
| `EmDash App` | no | this repository, `release-v1` branch, `Dockerfile` | Builds `site/` (EmDash 1.6.0, Astro 7.4.13, `@astrojs/node` 11.1.14) on `node:24.22.3-trixie-slim` and runs it on Railway's private network, port 4321. |

One 5 GB volume is mounted at `/data` on `EmDash App`:

- `/data/emdash.db` is the SQLite database (content, users, passkeys, settings, search index).
- `/data/uploads/` holds uploaded media.
- `/data/sessions/` holds sign-in sessions, so editors stay signed in across redeploys.

The gateway exists because a fresh EmDash lets whoever opens `/_emdash/admin` first create the admin account. Behind the gateway that first step is yours alone. After setup EmDash signs editors in with passkeys; by default the gateway keeps asking for its password on the admin panel as a second layer. The public site, uploaded images, search, RSS and API calls with EmDash tokens never ask for it.

## Deploy on Railway

1. Deploy the template. Nothing needs to be filled in: Railway generates `GATEWAY_PASSWORD` and `EMDASH_ENCRYPTION_KEY` and wires the services together.
2. Wait for the `EmDash App` build (about 3 to 5 minutes) and for both services to turn healthy.
3. Copy `GATEWAY_USERNAME` (default `admin`) and `GATEWAY_PASSWORD` from the `EmDash` service variables.
4. Open `https://<your EmDash domain>/_emdash/admin`. The browser asks for the gateway credentials; enter the values from step 3.
5. In the setup wizard, enter the site title, choose whether to add the sample blog content, enter your email, and create a passkey (Touch ID, Windows Hello, a phone or a password manager). You land in the admin dashboard.
6. The site is at `https://<your EmDash domain>/`. A site created by the wizard starts hidden from search engines; publish it in EmDash's SEO settings when it is ready.

To let editors sign in with passkeys only, set `GATEWAY_ADMIN_GATE=setup` on the `EmDash` service after setup. The setup API stays behind the password either way, and EmDash refuses it once setup is complete.

## Environment variables

`EmDash` (gateway):

| Variable | Default | Meaning |
| --- | --- | --- |
| `PORT` | `8080` | Public listener. |
| `GATEWAY_USERNAME` | `admin` | Username for the browser password prompt. Letters, digits, `.`, `_`, `-`. |
| `GATEWAY_PASSWORD` | `${{secret(32, ...)}}` | Generated password for the prompt. Letters and digits only; the gateway refuses to start with fewer than 16. |
| `GATEWAY_ADMIN_GATE` | `admin` | `admin` guards the admin panel and the setup API; `setup` guards only the setup API. |
| `EMDASH_APP_ADDRESS` | `${{EmDash App.RAILWAY_PRIVATE_DOMAIN}}:4321` | Private address of the site. |
| `GATEWAY_TRUSTED_PROXIES` | `100.64.0.0/10` | Railway's edge range. The visitor address it reports is passed to EmDash for rate limits. |

`EmDash App`:

| Variable | Default | Meaning |
| --- | --- | --- |
| `PORT` | `4321` | Private Node listener; Railway's health check calls `/_emdash/api/health`. |
| `HOST` | `::` | Listen on IPv6 and IPv4 so Railway's private network reaches the site. |
| `EMDASH_SITE_URL` | `https://${{EmDash.RAILWAY_PUBLIC_DOMAIN}}` | Public origin. Passkeys are bound to this host. The build also reads it to optimize images. |
| `EMDASH_ENCRYPTION_KEY` | `emdash_enc_v1_${{secret(42, ...)}}A` | Encrypts secret plugin settings: `emdash_enc_v1_` plus 43 base64url characters. Keep a copy outside Railway. |
| `EMDASH_TRUSTED_PROXY_HEADERS` | `x-real-ip` | Header the gateway sets to the visitor's address. |

Optional EmDash settings go on `EmDash App` as well, for example `EMAIL_SMTP_HOST`, `EMAIL_SMTP_PORT`, `EMAIL_SMTP_USER`, `EMAIL_SMTP_PASS` and `EMAIL_SMTP_FROM_EMAIL` to send invites and magic links (see EmDash's [email guide](https://docs.emdashcms.com/guides/email/)). EmDash requires TLS and refuses port 25, and Railway allows outbound SMTP only on some plans, so check yours. Without email, invite editors by sharing the invite link EmDash shows on the Users page.

## Custom domain

Passkeys belong to one host name. Add the domain to the `EmDash` service, set `EMDASH_SITE_URL` on `EmDash App` to `https://<your domain>`, and redeploy `EmDash App` (the build also reads it). Then sign in on the old address and use EmDash's sign-in handover in Security settings to add a passkey for the new one, or add the domain before running setup.

## Persistence, backups and limits

Everything EmDash stores lives on the `/data` volume: a redeploy or restart keeps content, media, users, passkeys and sessions. Back up the whole volume before upgrades (stop `EmDash App` first for a consistent SQLite copy), and keep `EMDASH_ENCRYPTION_KEY` with the backup; plugin secrets saved with it cannot be read without it.

This is a single-instance deployment for one site and a small editorial team. SQLite allows one `EmDash App` replica; do not scale it out. Scheduled publishing runs inside the Node process, so keep the service running. Co-editing is off, as upstream ships it; the gateway forwards WebSockets if you turn it on in `site/astro.config.mjs`. Plugins that need EmDash's sandbox runner (`@emdash-cms/sandbox-workerd`) are not installed.

## Customizing the site

`site/` is an ordinary EmDash project created from upstream's blog template, so you can change its theme, pages, collections seed and plugins like any EmDash site. Fork this repository, edit `site/`, run `npm install` there to update the lockfile, and point your Railway service at your fork. EmDash's [documentation](https://docs.emdashcms.com) covers themes, content types and plugins. Content you create in the admin panel lives in the database, not in `site/`, and survives redeploys of a changed theme.

## Local verification

```bash
bun install --frozen-lockfile
./scripts/verify.sh
./scripts/local-check.sh
```

`local-check.sh` builds the image, starts the Compose stack with generated secrets, and runs `scripts/smoke.mjs` twice around a restart of both services. The smoke test checks that anonymous and wrong-password requests to the admin panel and setup are refused, including 34 encoded, double-encoded, dotted and doubled spellings of those paths; completes setup with a software passkey; uploads an image and publishes a post that uses it; finds the post with full-text search; schedules a second post and waits for EmDash's scheduler to publish it; and uses an API token through the gateway. After the restart it checks the post, the image bytes, the scheduled post and the token, and signs in again with the passkey. Run it against Railway with `BASE_URL=https://<domain> GATEWAY_PASSWORD_FILE=<file> SMOKE_STATE=<new file> SMOKE_PHASE=initial node scripts/smoke.mjs`.

## Source and forks

The Railway template builds `EmDash App` from `tech-progress/railway-template-emdash` on the `release-v1` branch with root directory `/`. To run your own fork, change the repository in `.railway/railway.ts`, create a `release-v1` branch, and authorize Railway's GitHub App for it.

## Upstream projects

- [EmDash](https://github.com/emdash-cms/emdash) ([documentation](https://docs.emdashcms.com), [templates](https://github.com/emdash-cms/templates))
- [Astro](https://astro.build) and its [Node adapter](https://docs.astro.build/en/guides/integrations-guide/node/)
- [Caddy](https://caddyserver.com)
