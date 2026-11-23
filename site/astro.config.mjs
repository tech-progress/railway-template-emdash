import node from "@astrojs/node";
import react from "@astrojs/react";
import { defineConfig, fontProviders, sessionDrivers } from "astro/config";
import emdash, { local } from "emdash/astro";
import { sqlite } from "emdash/db";
import { Features } from "lightningcss";

// Railway template: the database, uploaded media and sign-in sessions share the
// one Railway volume mounted at /data, so all of them survive redeploys. The
// path is fixed when the site is built; EMDASH_DATA_DIR only exists for local
// development (for example EMDASH_DATA_DIR=./data npm run dev), and the
// Dockerfile does not pass it to the build.
const dataDir = process.env.EMDASH_DATA_DIR || "/data";

export default defineConfig({
	output: "server",
	adapter: node({
		mode: "standalone",
	}),
	// The Node adapter's default session store is under node_modules/.astro,
	// which the server's user cannot write and which every redeploy replaces.
	session: {
		driver: sessionDrivers.fsLite({ base: `${dataDir}/sessions` }),
	},
	image: {
		layout: "constrained",
		responsiveStyles: true,
	},
	vite: {
		css: {
			// Keep light-dark() native so the footer theme switcher works in
			// production. For older browsers, Lightning CSS otherwise rewrites
			// it into variables that follow only prefers-color-scheme, which the
			// :root.light / :root.dark color-scheme rules in Base.astro can't
			// reach. Browsers without light-dark() get the light fallback in
			// tokens.css.
			lightningcss: { exclude: Features.LightDark },
		},
	},
	integrations: [
		react(),
		emdash({
			database: sqlite({ url: `file:${dataDir}/emdash.db` }),
			storage: local({
				directory: `${dataDir}/uploads`,
				baseUrl: "/_emdash/api/media/file",
			}),
		}),
	],
	fonts: [
		{
			provider: fontProviders.google(),
			name: "Inter",
			cssVariable: "--font-body",
			weights: [400, 500, 600, 700],
			fallbacks: ["sans-serif"],
		},
		{
			provider: fontProviders.google(),
			name: "JetBrains Mono",
			cssVariable: "--font-mono",
			weights: [400, 500],
			fallbacks: ["monospace"],
		},
	],
	devToolbar: { enabled: false },
});
