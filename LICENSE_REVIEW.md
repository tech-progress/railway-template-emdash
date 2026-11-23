# License review

- [EmDash](https://github.com/emdash-cms/emdash) is licensed under MIT (copyright 2026 Cloudflare, Inc.; `LICENSE` at tag `emdash@1.6.0`), which permits redistribution, modification and commercial use, provided the copyright and permission notice are kept. `site/` is upstream's `templates/blog` at that tag with exact dependency versions, a `/data` storage path and a session store on the volume; `site/LICENSE` keeps upstream's notice. The repository has no trademark policy, and the template does not claim to be an official EmDash or Cloudflare offering.
- The site installs the published npm packages `emdash` and `@emdash-cms/*` 1.6.0 (MIT) with Astro 7.4.13, `@astrojs/node` and `@astrojs/react` (MIT), React 19.2.4 (MIT) and their dependencies as locked in `site/package-lock.json`.
- [Node.js](https://github.com/nodejs/node) (MIT and bundled licenses) and the Debian base of the official `node:24.22.3-trixie-slim` image run unmodified.
- [Caddy](https://github.com/caddyserver/caddy) is licensed under Apache-2.0 and runs from the official image by digest.
- The wrapper files in this repository (Dockerfile, scripts, Railway configuration and documentation) add no license restrictions.
