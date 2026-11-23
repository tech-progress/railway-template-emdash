#!/usr/bin/env node
// Application-level smoke test of the EmDash template through its public
// gateway. Node 22+ built-ins only (fetch, WebCrypto, zlib).
//
//   BASE_URL=https://<domain> GATEWAY_PASSWORD_FILE=<0600 file> \
//   SMOKE_STATE=<file> SMOKE_PHASE=initial|restart node scripts/smoke.mjs
//
// initial: the gateway refuses anonymous admin and setup requests and every
//   ambiguous spelling of them; setup runs through the gateway with a software
//   passkey (ES256, "none" attestation, as a browser authenticator sends);
//   a post with an uploaded image is published and served to anonymous
//   visitors; a second post is scheduled and must be published by EmDash's
//   in-process scheduler; an API token works through the gateway.
// restart (after restarting both services): the post, the image bytes, the
//   scheduled post, the token and the passkey all still work, and setup
//   stays closed.
// The state file (0600) holds the test passkey and token; delete it after use.
// No secret is printed.
import { createHash, webcrypto } from "node:crypto";
import { existsSync, readFileSync, writeFileSync } from "node:fs";
import { crc32, deflateSync } from "node:zlib";

const { subtle } = webcrypto;
const BASE = (process.env.BASE_URL ?? "").replace(/\/+$/, "");
const PHASE = process.env.SMOKE_PHASE ?? "";
const STATE = process.env.SMOKE_STATE ?? "";
const PASSWORD_FILE = process.env.GATEWAY_PASSWORD_FILE ?? "";
const USERNAME = process.env.GATEWAY_USERNAME ?? "admin";
const SCHEDULE_WAIT_S = Number(process.env.SMOKE_SCHEDULE_WAIT_S ?? "180");
if (!/^https?:\/\/[^/]+$/.test(BASE)) die("BASE_URL must be an origin such as https://example.up.railway.app");
if (!["initial", "restart"].includes(PHASE)) die("SMOKE_PHASE must be initial or restart");
if (!STATE) die("SMOKE_STATE is required");
if (!PASSWORD_FILE) die("GATEWAY_PASSWORD_FILE is required");
const PASSWORD = readFileSync(PASSWORD_FILE, "utf8").trim();
const BASIC = "Basic " + Buffer.from(`${USERNAME}:${PASSWORD}`).toString("base64");
const ORIGIN = new URL(BASE).origin;

function die(message) {
  console.error(`smoke: FAIL ${message}`);
  process.exit(1);
}
function pass(message) {
  console.log(`smoke: ok ${message}`);
}
function check(condition, message) {
  if (!condition) die(message);
  pass(message);
}

// ---- HTTP with a small cookie jar ----
const jar = new Map();
async function http(path, { method = "GET", basic = false, body, json, headers = {}, cookies = true, bearer } = {}) {
  const h = { ...headers };
  if (basic) h.Authorization = BASIC;
  if (bearer) h.Authorization = `Bearer ${bearer}`;
  if (json !== undefined) {
    h["Content-Type"] = "application/json";
    body = JSON.stringify(json);
  }
  if (method !== "GET" && method !== "HEAD") {
    h.Origin = ORIGIN;
    h["X-EmDash-Request"] = "1";
  }
  if (cookies && jar.size) h.Cookie = [...jar].map(([k, v]) => `${k}=${v}`).join("; ");
  const response = await fetch(BASE + path, { method, headers: h, body, redirect: "manual" });
  for (const line of response.headers.getSetCookie()) {
    const [pair, ...attrs] = line.split(";");
    const index = pair.indexOf("=");
    const name = pair.slice(0, index).trim();
    const value = pair.slice(index + 1).trim();
    const expired = attrs.some((a) => /^\s*max-age=0\s*$/i.test(a)) || value === "";
    if (expired) jar.delete(name);
    else jar.set(name, value);
  }
  const buffer = Buffer.from(await response.arrayBuffer());
  let parsed;
  try {
    parsed = JSON.parse(buffer.toString("utf8"));
  } catch {
    parsed = undefined;
  }
  return { status: response.status, headers: response.headers, buffer, text: buffer.toString("utf8"), json: parsed };
}

// Raw request target, for path spellings fetch would normalize.
async function rawStatus(target, { basic = false } = {}) {
  const net = await import("node:net");
  const tls = await import("node:tls");
  const url = new URL(BASE);
  const port = Number(url.port || (url.protocol === "https:" ? 443 : 80));
  const lines = [`GET ${target} HTTP/1.1`, `Host: ${url.host}`, "Connection: close"];
  if (basic) lines.push(`Authorization: ${BASIC}`);
  const payload = lines.join("\r\n") + "\r\n\r\n";
  return await new Promise((resolve, reject) => {
    const socket =
      url.protocol === "https:"
        ? tls.connect({ host: url.hostname, port, servername: url.hostname })
        : net.connect({ host: url.hostname, port });
    let data = "";
    socket.setTimeout(30000, () => socket.destroy(new Error("timeout")));
    socket.on(url.protocol === "https:" ? "secureConnect" : "connect", () => socket.write(payload));
    socket.on("data", (chunk) => (data += chunk.toString("latin1")));
    socket.on("end", () => {
      const match = /^HTTP\/1\.[01] (\d{3})/.exec(data);
      resolve({ status: match ? Number(match[1]) : 0, body: data.slice(data.indexOf("\r\n\r\n") + 4) });
    });
    socket.on("error", reject);
  });
}

// ---- WebAuthn software authenticator (ES256, "none" attestation) ----
const b64url = (bytes) => Buffer.from(bytes).toString("base64url");
const sha256 = (bytes) => createHash("sha256").update(bytes).digest();

function cbor(value) {
  const head = (major, n) => {
    if (n < 24) return Buffer.from([(major << 5) | n]);
    if (n < 256) return Buffer.from([(major << 5) | 24, n]);
    if (n < 65536) return Buffer.from([(major << 5) | 25, n >> 8, n & 255]);
    throw new Error("cbor length");
  };
  if (Number.isInteger(value)) return value >= 0 ? head(0, value) : head(1, -1 - value);
  if (Buffer.isBuffer(value)) return Buffer.concat([head(2, value.length), value]);
  if (typeof value === "string") {
    const bytes = Buffer.from(value, "utf8");
    return Buffer.concat([head(3, bytes.length), bytes]);
  }
  if (value instanceof Map) {
    const parts = [head(5, value.size)];
    for (const [k, v] of value) parts.push(cbor(k), cbor(v));
    return Buffer.concat(parts);
  }
  throw new Error("cbor type");
}

function derSignature(raw) {
  const integer = (bytes) => {
    let i = 0;
    while (i < bytes.length - 1 && bytes[i] === 0) i++;
    let v = bytes.subarray(i);
    if (v[0] & 0x80) v = Buffer.concat([Buffer.from([0]), v]);
    return Buffer.concat([Buffer.from([0x02, v.length]), v]);
  };
  const buf = Buffer.from(raw);
  const body = Buffer.concat([integer(buf.subarray(0, 32)), integer(buf.subarray(32))]);
  return Buffer.concat([Buffer.from([0x30, body.length]), body]);
}

async function createCredential(options) {
  const keys = await subtle.generateKey({ name: "ECDSA", namedCurve: "P-256" }, true, ["sign", "verify"]);
  const jwk = await subtle.exportKey("jwk", keys.publicKey);
  const credentialId = webcrypto.getRandomValues(new Uint8Array(32));
  const cose = cbor(
    new Map([
      [1, 2],
      [3, -7],
      [-1, 1],
      [-2, Buffer.from(jwk.x, "base64url")],
      [-3, Buffer.from(jwk.y, "base64url")],
    ]),
  );
  const authData = Buffer.concat([
    sha256(Buffer.from(options.rp.id)),
    Buffer.from([0x45]), // user present, user verified, attested credential data
    Buffer.alloc(4),
    Buffer.alloc(16),
    Buffer.from([0, credentialId.length]),
    Buffer.from(credentialId),
    cose,
  ]);
  const clientDataJSON = Buffer.from(
    JSON.stringify({ type: "webauthn.create", challenge: options.challenge, origin: ORIGIN, crossOrigin: false }),
  );
  const attestationObject = cbor(
    new Map([
      ["fmt", "none"],
      ["attStmt", new Map()],
      ["authData", authData],
    ]),
  );
  return {
    credential: {
      id: b64url(credentialId),
      rawId: b64url(credentialId),
      type: "public-key",
      response: { clientDataJSON: b64url(clientDataJSON), attestationObject: b64url(attestationObject), transports: ["internal"] },
      authenticatorAttachment: "platform",
    },
    saved: { id: b64url(credentialId), privateJwk: await subtle.exportKey("jwk", keys.privateKey), rpId: options.rp.id },
  };
}

async function assertCredential(saved, options) {
  const key = await subtle.importKey("jwk", saved.privateJwk, { name: "ECDSA", namedCurve: "P-256" }, false, ["sign"]);
  const authData = Buffer.concat([sha256(Buffer.from(options.rpId ?? saved.rpId)), Buffer.from([0x05]), Buffer.alloc(4)]);
  const clientDataJSON = Buffer.from(
    JSON.stringify({ type: "webauthn.get", challenge: options.challenge, origin: ORIGIN, crossOrigin: false }),
  );
  const signed = Buffer.concat([authData, sha256(clientDataJSON)]);
  const raw = await subtle.sign({ name: "ECDSA", hash: "SHA-256" }, key, signed);
  return {
    id: saved.id,
    rawId: saved.id,
    type: "public-key",
    response: {
      clientDataJSON: b64url(clientDataJSON),
      authenticatorData: b64url(authData),
      signature: b64url(derSignature(raw)),
    },
    authenticatorAttachment: "platform",
  };
}

// ---- Test image: a 4x4 PNG with a random colour, so no upload deduplicates ----
function testPng() {
  const chunk = (type, data) => {
    const td = Buffer.concat([Buffer.from(type), data]);
    const len = Buffer.alloc(4);
    len.writeUInt32BE(data.length);
    const crc = Buffer.alloc(4);
    crc.writeUInt32BE(crc32(td));
    return Buffer.concat([len, td, crc]);
  };
  const ihdr = Buffer.alloc(13);
  ihdr.writeUInt32BE(4, 0);
  ihdr.writeUInt32BE(4, 4);
  ihdr[8] = 8;
  ihdr[9] = 2;
  const colour = webcrypto.getRandomValues(new Uint8Array(3));
  const rows = [];
  for (let y = 0; y < 4; y++) rows.push(Buffer.from([0, ...colour, ...colour, ...colour, ...colour]));
  return Buffer.concat([
    Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]),
    chunk("IHDR", ihdr),
    chunk("IDAT", deflateSync(Buffer.concat(rows))),
    chunk("IEND", Buffer.alloc(0)),
  ]);
}

const portableText = (text) => [
  { _type: "block", _key: "b1", style: "normal", markDefs: [], children: [{ _type: "span", _key: "s1", text, marks: [] }] },
];
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

// ---- Checks shared by both phases ----
async function gatewayChecks() {
  const health = await http("/__gateway/health");
  check(health.status === 200 && health.text === "ok", "gateway health responds");
  const appHealth = await http("/_emdash/api/health");
  check(appHealth.status === 200 && appHealth.json?.data?.product === "emdash", `EmDash ${appHealth.json?.data?.version} answers through the gateway`);

  for (const [path, method] of [
    ["/_emdash/admin", "GET"],
    ["/_emdash/admin/setup", "GET"],
    ["/_emdash/api/setup/status", "GET"],
    ["/_emdash/api/setup", "POST"],
    ["/_emdash/api/setup/admin", "POST"],
    ["/_emdash/api/setup/admin/verify", "POST"],
  ]) {
    const r = await http(path, { method, cookies: false, json: method === "POST" ? {} : undefined });
    check(r.status === 401 && /^Basic realm="EmDash"/.test(r.headers.get("www-authenticate") ?? ""), `anonymous ${method} ${path} needs the gateway credential`);
  }
  const wrong = await http("/_emdash/api/setup/status", { cookies: false, headers: { Authorization: "Basic " + Buffer.from(`${USERNAME}:wrong-password-123`).toString("base64") } });
  check(wrong.status === 401, "a wrong gateway password is refused");

  // Spellings that must never reach the setup or admin routes anonymously.
  const variants = [
    "/_emdash/%61dmin",
    "/_emdash/api/%73etup/status",
    "/_EMDASH/API/SETUP/STATUS",
    "/_emdash/Admin/setup",
    "/_emdash/api/setup%2fstatus",
    "/_emdash/api/setup%2Fstatus",
    "/_emdash/api/x/../setup/status",
    "/_emdash/api/x/%2e%2e/setup/status",
    "/_emdash/api/x/%2E%2E/setup/status",
    "/x/../_emdash/api/setup/status",
    "/_emdash/./api/setup/status",
    "/_emdash/api/./setup/status",
    "//_emdash/api/setup/status",
    "/_emdash//api/setup/status",
    "/_emdash/api/setup/status/.",
    "/_emdash/api/setup/status/..",
    "/_emdash\\api\\setup\\status",
    "/_emdash%5capi%5csetup%5cstatus",
    "/_emdash/api/setup%00/status",
    "/_emdash/api/setup;/status",
    "/_emdash/api/setup/status;x",
    "/_emdash/admin;x",
    "/_emdash/api/setup/status%3F",
    "/_emdash/api/setup/status%23",
    "/_emdash/api/setup/status?",
    "/_emdash/api/setup/status#",
    "http://evil.example/_emdash/api/setup/status",
  ];
  for (const target of variants) {
    const r = await rawStatus(target);
    const leaked = r.status === 200 || /needsSetup|"step"/.test(r.body) || /<div id="admin-root"|emdash-admin/.test(r.body);
    if (leaked) die(`ambiguous target ${target} reached EmDash anonymously (HTTP ${r.status})`);
  }
  pass(`${variants.length} ambiguous spellings of gated paths stay closed`);
}

async function initial() {
  if (existsSync(STATE)) die(`state file ${STATE} already exists; use a fresh path`);
  await gatewayChecks();

  const status = await http("/_emdash/api/setup/status", { basic: true });
  check(status.status === 200 && status.json?.data?.needsSetup === true, "setup is pending on a fresh deployment");

  // Step 1: site title and the blog seed, possibly over several requests.
  let seeded = false;
  for (let attempt = 0; attempt < 20 && !seeded; attempt++) {
    const r = await http("/_emdash/api/setup", { method: "POST", basic: true, json: { title: "Railway Smoke Blog", tagline: "Template verification", includeContent: true } });
    if (r.status !== 200) die(`setup step 1 returned HTTP ${r.status}: ${r.text.slice(0, 300)}`);
    seeded = r.json?.data?.complete !== false;
  }
  check(seeded, "setup applied the blog seed");

  // Step 2 and 3: the first admin, with a passkey.
  const email = `smoke-${Date.now()}@example.com`;
  const adminOptions = await http("/_emdash/api/setup/admin", { method: "POST", basic: true, json: { email, name: "Smoke Admin" } });
  check(adminOptions.status === 200 && adminOptions.json?.data?.options?.challenge, "setup issued passkey registration options");
  const options = adminOptions.json.data.options;
  check(options.rp?.id === new URL(BASE).hostname, `passkey relying party is the public host (${options.rp?.id})`);
  const { credential, saved } = await createCredential(options);
  const verify = await http("/_emdash/api/setup/admin/verify", { method: "POST", basic: true, json: { credential } });
  check(verify.status === 200 && verify.json?.data?.user?.role >= 50, `first admin created (role ${verify.json?.data?.user?.role})`);

  const closed = await http("/_emdash/api/setup", { method: "POST", basic: true, json: { title: "x", includeContent: false } });
  check(closed.status === 409, "setup refuses to run again");
  const me = await http("/_emdash/api/auth/me");
  check(me.status === 200 && me.json?.data?.email === email, "the admin session works through the gateway");

  // API token, used through the ungated API path.
  const tokenResponse = await http("/_emdash/api/admin/api-tokens", { method: "POST", json: { name: "smoke", scopes: ["content:read", "content:write", "media:read", "media:write"] } });
  const token = tokenResponse.json?.data?.token;
  check(tokenResponse.status === 201 || tokenResponse.status === 200 ? Boolean(token) : false, "an API token was created");

  // Upload an image through the API with the token.
  const png = testPng();
  const form = new FormData();
  form.append("file", new Blob([png], { type: "image/png" }), "smoke.png");
  form.append("alt", "Smoke test image");
  form.append("width", "4");
  form.append("height", "4");
  const upload = await http("/_emdash/api/media", { method: "POST", body: form, bearer: token, cookies: false });
  const item = upload.json?.data?.item ?? upload.json?.data;
  check(upload.status === 201 && item?.id, `image uploaded (HTTP ${upload.status})`);
  const mediaUrl = item.url ?? `/_emdash/api/media/file/${item.storageKey}`;
  const mediaPath = mediaUrl.startsWith("http") ? new URL(mediaUrl).pathname : mediaUrl;
  const fetched = await http(mediaPath, { cookies: false });
  check(fetched.status === 200 && sha256(fetched.buffer).equals(sha256(png)), "anonymous visitors get the uploaded bytes");

  // A published post that uses the image, created with the token.
  const slug = `railway-smoke-${Date.now()}`;
  const title = `Railway smoke post ${slug.slice(-6)}`;
  const created = await http("/_emdash/api/content/posts", {
    method: "POST",
    bearer: token,
    cookies: false,
    json: {
      slug,
      data: {
        title,
        excerpt: "Created by the template smoke test.",
        content: portableText("This post must survive a restart."),
        featured_image: { id: item.id, provider: "local", src: mediaUrl, alt: "Smoke test image", width: 4, height: 4 },
      },
    },
  });
  const postId = created.json?.data?.item?.id;
  check(created.status === 201 && postId, "post created");
  const published = await http(`/_emdash/api/content/posts/${postId}/publish`, { method: "POST", bearer: token, cookies: false, json: {} });
  check(published.status === 200, "post published");
  const page = await http(`/posts/${slug}`, { cookies: false });
  check(page.status === 200 && page.text.includes(title), "anonymous visitors see the published post");
  const search = await http(`/_emdash/api/search?q=${encodeURIComponent(slug.slice(-6))}`, { cookies: false });
  check(search.status === 200 && JSON.stringify(search.json).includes(slug), "full-text search (SQLite FTS5) finds the post");

  // A post scheduled for later must be published by the in-process scheduler.
  const schedSlug = `${slug}-scheduled`;
  const schedTitle = `Scheduled smoke post ${slug.slice(-6)}`;
  const scheduledCreate = await http("/_emdash/api/content/posts", {
    method: "POST",
    bearer: token,
    cookies: false,
    json: { slug: schedSlug, data: { title: schedTitle, content: portableText("Published by the scheduler.") } },
  });
  const schedId = scheduledCreate.json?.data?.item?.id;
  check(scheduledCreate.status === 201 && schedId, "scheduled post created");
  const scheduledAt = new Date(Date.now() + 20_000).toISOString();
  const schedule = await http(`/_emdash/api/content/posts/${schedId}/schedule`, { method: "POST", bearer: token, cookies: false, json: { scheduledAt } });
  check(schedule.status === 200, "post scheduled 20 s ahead");
  const before = await http(`/posts/${schedSlug}`, { cookies: false });
  check(before.status === 404 || !before.text.includes(schedTitle), "the scheduled post is not public yet");
  const deadline = Date.now() + SCHEDULE_WAIT_S * 1000;
  let live = false;
  while (Date.now() < deadline && !live) {
    await sleep(5000);
    const r = await http(`/posts/${schedSlug}`, { cookies: false });
    live = r.status === 200 && r.text.includes(schedTitle);
  }
  check(live, "the scheduler published the scheduled post");

  // The gateway strips a Basic credential on API paths; the token still works.
  const listed = await http("/_emdash/api/content/posts?limit=50", { bearer: token, cookies: false });
  check(listed.status === 200 && JSON.stringify(listed.json).includes(slug), "token reads content through the gateway");
  const basicOnApi = await http("/_emdash/api/content/posts?limit=1", { basic: true, cookies: false });
  check(basicOnApi.status === 401 || basicOnApi.status === 403, "the gateway credential alone grants no API access");

  writeFileSync(STATE, JSON.stringify({ base: BASE, email, credential: saved, token, slug, title, schedSlug, schedTitle, mediaPath, sha256: sha256(png).toString("hex"), postId }), { mode: 0o600 });
  pass(`state written to ${STATE}`);
}

async function restart() {
  if (!existsSync(STATE)) die(`state file ${STATE} not found; run the initial phase first`);
  const state = JSON.parse(readFileSync(STATE, "utf8"));
  if (state.base !== BASE) die("BASE_URL differs from the initial phase");
  await gatewayChecks();

  const page = await http(`/posts/${state.slug}`, { cookies: false });
  check(page.status === 200 && page.text.includes(state.title), "the post survived the restart");
  const scheduled = await http(`/posts/${state.schedSlug}`, { cookies: false });
  check(scheduled.status === 200 && scheduled.text.includes(state.schedTitle), "the scheduled post is still published");
  const media = await http(state.mediaPath, { cookies: false });
  check(media.status === 200 && sha256(media.buffer).toString("hex") === state.sha256, "the uploaded image survived with identical bytes");
  const listed = await http(`/_emdash/api/content/posts/${state.postId}`, { bearer: state.token, cookies: false });
  check(listed.status === 200, "the API token still works");

  const status = await http("/_emdash/api/setup/status", { basic: true });
  check(status.status === 200 && status.json?.data?.needsSetup === false, "setup stays complete");
  const again = await http("/_emdash/api/setup/admin", { method: "POST", basic: true, json: { email: "late@example.com" } });
  check(again.status === 400, "no second admin can be created through setup");

  const options = await http("/_emdash/api/auth/passkey/options", { method: "POST", json: {} });
  check(options.status === 200 && options.json?.data?.options?.challenge, "passkey sign-in options issued");
  const credential = await assertCredential(state.credential, options.json.data.options);
  const login = await http("/_emdash/api/auth/passkey/verify", { method: "POST", json: { credential } });
  check(login.status === 200, "the setup passkey signs in after the restart");
  const me = await http("/_emdash/api/auth/me");
  check(me.status === 200 && me.json?.data?.email === state.email, "the signed-in session is the admin");
  const admin = await http("/_emdash/admin/", { basic: true });
  check(admin.status === 200, "the admin panel loads with the gateway credential and session");
}

try {
  if (PHASE === "initial") await initial();
  else await restart();
  console.log(`smoke: PASS ${PHASE}`);
} catch (error) {
  die(error instanceof Error ? error.message : String(error));
}
