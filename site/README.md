# EmDash Blog Template

A clean, minimal blog built with [EmDash](https://github.com/emdash-cms/emdash). Runs on any Node.js server with SQLite and local file storage.

![Blog template homepage](https://raw.githubusercontent.com/emdash-cms/emdash/main/assets/templates/blog/latest/homepage-light-desktop.jpg)

## What's Included

- Featured post hero on the homepage
- Post archive with reading time estimates
- Category and tag archives
- Full-text search
- RSS feed
- SEO metadata and JSON-LD
- Dark/light mode

## Pages

| Page | Route |
|---|---|
| Homepage | `/` |
| All posts | `/posts` |
| Single post | `/posts/:slug` |
| Category archive | `/category/:slug` |
| Tag archive | `/tag/:slug` |
| Search | `/search` |
| Static pages | `/pages/:slug` |
| 404 | fallback |

## Screenshots

| | Desktop | Mobile |
|---|---|---|
| Light | ![homepage light desktop](https://raw.githubusercontent.com/emdash-cms/emdash/main/assets/templates/blog/latest/homepage-light-desktop.jpg) | ![homepage light mobile](https://raw.githubusercontent.com/emdash-cms/emdash/main/assets/templates/blog/latest/homepage-light-mobile.jpg) |
| Dark | ![homepage dark desktop](https://raw.githubusercontent.com/emdash-cms/emdash/main/assets/templates/blog/latest/homepage-dark-desktop.jpg) | ![homepage dark mobile](https://raw.githubusercontent.com/emdash-cms/emdash/main/assets/templates/blog/latest/homepage-dark-mobile.jpg) |

## Infrastructure

- **Runtime:** Node.js
- **Database:** SQLite (local file)
- **Storage:** Local filesystem
- **Framework:** Astro with `@astrojs/node`

## Getting Started

This copy of the blog template is the site that the Railway template builds. The root `Dockerfile` runs `npm ci` and `npm run build` here; the database, uploads and sessions live under `/data` on the Railway volume.

To work on the theme locally:

```bash
npm install
mkdir -p data
EMDASH_DATA_DIR=./data npm run dev
```

Open http://localhost:4321/_emdash/admin and complete the setup wizard. EmDash runs database migrations and applies the blog seed during setup. The site is available at http://localhost:4321. Commit `package-lock.json` with any dependency change so Railway builds the same versions.

## See Also

- [All EmDash templates](https://github.com/emdash-cms/templates)
- [EmDash documentation](https://docs.emdashcms.com/)
