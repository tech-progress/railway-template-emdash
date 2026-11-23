# EmDash site for Railway: upstream's blog template (emdash 1.6.0, Astro 7 with
# the Node adapter) built from site/, with the SQLite database and uploaded
# media on the volume mounted at /data. The EmDash gateway service (Caddy) is
# the only public service; this one listens on Railway's private network.
FROM node:24.22.3-trixie-slim@sha256:af02d57b57719b9657a45199a79264a9437940cd55b3c7b3fc99615654f124a0 AS build

WORKDIR /app
COPY site/package.json site/package-lock.json ./
RUN npm ci --no-audit --no-fund

COPY site/ ./
# The public origin, when Railway passes it to the build, lets Astro optimize
# images stored on the volume (EmDash bakes it into image.remotePatterns). The
# server reads EMDASH_SITE_URL again at run time for everything else.
ARG EMDASH_SITE_URL=""
ENV NODE_OPTIONS=--max-old-space-size=3072
RUN EMDASH_SITE_URL="${EMDASH_SITE_URL}" npm run build && npm prune --omit=dev --no-audit --no-fund

FROM node:24.22.3-trixie-slim@sha256:af02d57b57719b9657a45199a79264a9437940cd55b3c7b3fc99615654f124a0

ENV NODE_ENV=production \
    HOST=:: \
    PORT=4321
WORKDIR /app
COPY --from=build /app/package.json ./package.json
COPY --from=build /app/node_modules ./node_modules
COPY --from=build /app/dist ./dist
COPY scripts/emdash-start.sh /usr/local/bin/emdash-start
RUN chmod 0755 /usr/local/bin/emdash-start && mkdir -p /data

EXPOSE 4321
# Starts as root only to give the node user the Railway volume, then drops to it.
CMD ["/usr/local/bin/emdash-start"]
