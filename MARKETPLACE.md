# Deploy and Host EmDash CMS on Railway

EmDash is a TypeScript CMS built on Astro, with passkey sign-in, a rich-text editor, a media library, scheduled publishing, full-text search, plugins, a REST API and an MCP server. This template runs EmDash 1.6.0 with its blog theme as a Node server, keeps all content and media on a Railway volume, and puts a password gateway in front of the admin panel and first-run setup.

## About Hosting EmDash CMS

The `EmDash App` service builds upstream's blog template on Astro's Node adapter and stores the SQLite database, uploaded media and sign-in sessions on one 5 GB volume at `/data`, so posts, images, users and passkeys survive restarts and redeploys. EmDash's built-in scheduler publishes scheduled posts inside the same process.

The `EmDash` service is a Caddy gateway and the only public service. A fresh EmDash lets the first visitor create the admin account, so the gateway asks for a generated password (`GATEWAY_USERNAME` and `GATEWAY_PASSWORD` on the `EmDash` service) before the admin panel and setup. The public site, media, search, RSS and token-authenticated API calls stay open.

After deploying: open the `/_emdash/admin` path on the `EmDash` service's domain, enter the gateway credentials, then run the setup wizard and create your passkey.

## Why Deploy EmDash CMS on Railway

- Runs EmDash on Node, not only on Cloudflare Workers, with SQLite full-text search working.
- No first-visit takeover: setup stays behind a generated password.
- Content, media and sessions on a persistent volume; images and dependencies pinned.

## Common Use Cases

- A personal or company blog with a modern editor and passkey sign-in.
- A content site whose theme you customize in Astro, with content managed in the admin panel.
- A CMS that AI agents and scripts can edit through EmDash's REST API or MCP server.

## Dependencies for EmDash CMS Hosting

The template uses two services and one Railway volume. No external database, storage or account is needed.

### Deployment Dependencies

- [EmDash](https://github.com/emdash-cms/emdash) provides the CMS, admin panel, APIs and blog template.
- [Astro](https://astro.build) and its Node adapter render the site.
- [Caddy](https://caddyserver.com) provides the public gateway and its password prompt.
- [Railway](https://railway.com) provides the build, private networking, HTTPS and the persistent volume.
