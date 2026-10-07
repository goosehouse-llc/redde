// Redde push relay. Two services share this Worker.
//
// The public one, /v1: a pipe that cannot read what it carries. A phone registers its APNs token
// and the hash of a secret; whoever holds that secret (the Redde plugin on that person's own
// Hermes, paired with the phone) may post an opaque blob, which goes to APNs as it came. The blob
// is encrypted between the plugin and the phone with a key the two agreed on directly; the relay
// never has it. The phone's notification extension decrypts it. What the relay stores is the APNs
// token, the secret's hash and when the phone last checked in; what it sees pass is ciphertext
// and its size. docs/push.md has the whole design.
//
//   POST   /v1/devices            {token, env: "dev"|"prod", auth: sha256(secret) hex}   -> 201 {id}
//   PUT    /v1/devices/:id        {token, env}          Authorization: Bearer <secret>   -> 204
//   DELETE /v1/devices/:id                              Authorization: Bearer <secret>   -> 204
//   POST   /v1/devices/:id/push   {payload, collapse?, ttl?}   Bearer <secret>   -> 202 | 410 gone
//   PUT    /v1/pairings/:rid      {pub, box}   Bearer <secret>, X-Redde-Device: <id>     -> 204
//   GET    /v1/pairings/:rid                                               -> 200 {pub, box} | 404
//
// A pairing is how the phone's half of the key agreement reaches the plugin: a slot named by a
// hash of the plugin's public key (which the phone read off a QR code), written once by a
// registered phone, read once, gone in ten minutes. Nothing in it is secret from the relay
// except what is encrypted to the plugin.
//
// The older one, for a single household: hermes outbound webhooks (HMAC-signed, GitHub-style)
// mapped into APNs alerts for every token registered with one bearer secret. It sends the text
// in the clear and is not offered to anyone else.
//
//   POST   /register  {token, env: "dev"|"prod"}   Authorization: Bearer <REGISTER_SECRET>
//   DELETE /register  {token}                      same auth
//   POST   /hermes    hermes outbound webhook      X-Hermes-Signature-256 verified
//
// Without APNS_KEY configured nothing is sent to Apple; what would have been is logged, so the
// pipeline can be wired end to end before the key exists.

const encoder = new TextEncoder();

const b64url = (buf) =>
  btoa(String.fromCharCode(...new Uint8Array(buf))).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");

async function verifySignature(secret, body, header) {
  if (!header?.startsWith("sha256=")) return false;
  const key = await crypto.subtle.importKey("raw", encoder.encode(secret), { name: "HMAC", hash: "SHA-256" }, false, ["sign"]);
  const mac = await crypto.subtle.sign("HMAC", key, encoder.encode(body));
  const expected = [...new Uint8Array(mac)].map((b) => b.toString(16).padStart(2, "0")).join("");
  const given = header.slice(7);
  if (given.length !== expected.length) return false;
  let diff = 0;
  for (let i = 0; i < expected.length; i++) diff |= expected.charCodeAt(i) ^ given.charCodeAt(i);
  return diff === 0;
}

/** APNs provider JWT (ES256 with the .p8), cached in KV for 45 minutes. */
async function apnsJWT(env) {
  // A stand-in for Apple (APNS_ORIGIN, tests and local runs) takes any bearer.
  if (env.APNS_ORIGIN) return "local";
  const cached = await env.STORE.get("apns:jwt");
  if (cached) return cached;
  const pem = env.APNS_KEY || "";
  const body = pem.replace(/-----[A-Z ]+-----/g, "").replace(/\s+/g, "");
  if (!body) return null;
  const der = Uint8Array.from(atob(body), (c) => c.charCodeAt(0));
  const key = await crypto.subtle.importKey("pkcs8", der, { name: "ECDSA", namedCurve: "P-256" }, false, ["sign"]);
  const head = b64url(encoder.encode(JSON.stringify({ alg: "ES256", kid: env.APNS_KEY_ID })));
  const claims = b64url(encoder.encode(JSON.stringify({ iss: env.APNS_TEAM_ID, iat: Math.floor(Date.now() / 1000) })));
  const sig = await crypto.subtle.sign({ name: "ECDSA", hash: "SHA-256" }, key, encoder.encode(`${head}.${claims}`));
  const jwt = `${head}.${claims}.${b64url(sig)}`;
  await env.STORE.put("apns:jwt", jwt, { expirationTtl: 45 * 60 });
  return jwt;
}

async function sendPush(env, jwt, tokenKey, meta, note) {
  const token = tokenKey.slice(4);
  const host = meta.env === "dev" ? "api.sandbox.push.apple.com" : "api.push.apple.com";
  const res = await fetch(`https://${host}/3/device/${token}`, {
    method: "POST",
    headers: {
      authorization: `bearer ${jwt}`,
      "apns-topic": env.APNS_TOPIC,
      "apns-push-type": "alert",
      "apns-priority": "10",
      ...(note.collapse ? { "apns-collapse-id": note.collapse.slice(0, 60) } : {}),
    },
    body: JSON.stringify({
      aps: { alert: { title: note.title, body: note.body }, sound: "default", "thread-id": note.thread || "redde" },
      kind: note.kind,
      session: note.thread || "",
    }),
  });
  if (res.ok) {
    console.log(`apns sent ${res.status} to ${meta.env} device`);
  } else if (res.status === 410 || res.status === 400) {
    const reason = (await res.json().catch(() => ({})))?.reason || "";
    if (reason === "Unregistered" || reason === "BadDeviceToken") await env.STORE.delete(tokenKey);
    console.log(`apns drop ${res.status} ${reason}`);
  } else {
    console.log(`apns error ${res.status} ${await res.text()}`);
  }
}

const trunc = (s, n) => (s && s.length > n ? s.slice(0, n - 1) + "…" : s || "");

/** Which hermes events become a banner, and what they say. */
function noteFor(event, payload) {
  const extra = payload.extra || {};
  if (event === "pre_approval_request") {
    return {
      kind: "approval",
      title: "Sol needs approval",
      body: trunc(extra.command || payload.tool_input || extra.description || "A guarded command is waiting.", 140),
      thread: extra.session_key || payload.session_id || "",
      collapse: `approval-${extra.request_id || extra.session_key || ""}`,
    };
  }
  if (event === "post_llm_call") {
    const platforms = (payload._pushPlatforms || "").split(",");
    if (!platforms.includes(extra.platform || "")) return null;
    const text = trunc(extra.assistant_response || "", 160);
    if (!text) return null;
    return {
      kind: "replied",
      title: "Sol replied",
      body: text,
      thread: payload.session_id || "",
      collapse: `turn-${payload.session_id || ""}`,
    };
  }
  return null;
}

async function handleHermes(request, env, ctx) {
  const body = await request.text();
  if (!(await verifySignature(env.HMAC_SECRET, body, request.headers.get("X-Hermes-Signature-256")))) {
    return new Response("bad signature", { status: 401 });
  }
  let payload;
  try {
    payload = JSON.parse(body);
  } catch {
    return new Response("bad json", { status: 400 });
  }
  // Replay protection: both fields live inside the signed body.
  const ts = Date.parse(payload.timestamp || "");
  if (!ts || Math.abs(Date.now() - ts) > 5 * 60 * 1000) return new Response("stale", { status: 400 });
  const dedupeKey = `seen:${payload.delivery_id}`;
  if (payload.delivery_id) {
    if (await env.STORE.get(dedupeKey)) return new Response(null, { status: 204 });
    ctx.waitUntil(env.STORE.put(dedupeKey, "1", { expirationTtl: 600 }));
  }
  const event = request.headers.get("X-Hermes-Event") || payload.hook_event_name || "";
  payload._pushPlatforms = env.PUSH_PLATFORMS || "";
  const note = noteFor(event, payload);
  if (!note) return new Response(null, { status: 204 });

  ctx.waitUntil(
    (async () => {
      const jwt = await apnsJWT(env);
      const tokens = await env.STORE.list({ prefix: "tok:" });
      if (!jwt) {
        console.log(`APNS_KEY not configured; would push "${note.title}: ${note.body}" to ${tokens.keys.length} device(s)`);
        return;
      }
      for (const k of tokens.keys) {
        const meta = JSON.parse((await env.STORE.get(k.name)) || "{}");
        await sendPush(env, jwt, k.name, meta, note);
      }
    })()
  );
  return new Response(null, { status: 204 });
}

async function handleRegister(request, env, remove) {
  if (request.headers.get("Authorization") !== `Bearer ${env.REGISTER_SECRET}`) {
    return new Response("unauthorized", { status: 401 });
  }
  const { token, env: tokenEnv } = await request.json().catch(() => ({}));
  if (!/^[0-9a-fA-F]{32,200}$/.test(token || "")) return new Response("bad token", { status: 400 });
  if (remove) {
    await env.STORE.delete(`tok:${token}`);
  } else {
    // Refreshed on every app launch; unrefreshed tokens age out.
    await env.STORE.put(`tok:${token}`, JSON.stringify({ env: tokenEnv === "dev" ? "dev" : "prod", seen: Date.now() }),
                        { expirationTtl: 90 * 24 * 3600 });
  }
  return new Response(null, { status: 204 });
}

// ---- /v1: the relay that cannot read ---------------------------------------------------------

const json = (status, body) =>
  new Response(body === undefined ? null : JSON.stringify(body), {
    status,
    headers: body === undefined ? {} : { "content-type": "application/json" },
  });

const TOKEN = /^[0-9a-fA-F]{32,200}$/;
const HASH = /^[0-9a-f]{64}$/;
const ID = /^[A-Za-z0-9_-]{16,64}$/;
const BLOB = /^[A-Za-z0-9+/_=-]+$/;
const DEVICE_TTL = 120 * 24 * 3600; // a phone that hasn't checked in for four months is forgotten
const MAX_PAYLOAD = 3600; // base64 characters; APNs takes 4096 bytes in all
const MAX_PAIRING = 1200;

async function sha256Hex(text) {
  const digest = await crypto.subtle.digest("SHA-256", encoder.encode(text));
  return [...new Uint8Array(digest)].map((b) => b.toString(16).padStart(2, "0")).join("");
}

function sameText(a, b) {
  if (a.length !== b.length) return false;
  let diff = 0;
  for (let i = 0; i < a.length; i++) diff |= a.charCodeAt(i) ^ b.charCodeAt(i);
  return diff === 0;
}

/** The device a request may act on: it exists and the bearer hashes to what it registered. */
async function ownedDevice(request, env, id) {
  if (!ID.test(id || "")) return null;
  const bearer = (request.headers.get("Authorization") || "").replace(/^Bearer\s+/i, "");
  if (!bearer) return null;
  const device = JSON.parse((await env.STORE.get(`dev:${id}`)) || "null");
  if (!device || !sameText(device.auth, await sha256Hex(bearer))) return null;
  return device;
}

async function readJSON(request, limit) {
  const text = await request.text();
  if (text.length > limit) return null;
  try {
    const body = JSON.parse(text);
    return body && typeof body === "object" ? body : null;
  } catch {
    return null;
  }
}

async function registerDevice(request, env) {
  const body = await readJSON(request, 1000);
  if (!body || !TOKEN.test(body.token || "") || !HASH.test(body.auth || "")) return json(400, { error: "bad registration" });
  const id = b64url(crypto.getRandomValues(new Uint8Array(16)));
  const device = { token: body.token.toLowerCase(), env: body.env === "dev" ? "dev" : "prod", auth: body.auth, seen: Date.now() };
  await env.STORE.put(`dev:${id}`, JSON.stringify(device), { expirationTtl: DEVICE_TTL });
  return json(201, { id });
}

async function updateDevice(request, env, id) {
  const device = await ownedDevice(request, env, id);
  if (!device) return json(404, { error: "no such device" });
  const body = await readJSON(request, 1000);
  if (!body || !TOKEN.test(body.token || "")) return json(400, { error: "bad token" });
  Object.assign(device, { token: body.token.toLowerCase(), env: body.env === "dev" ? "dev" : "prod", seen: Date.now() });
  await env.STORE.put(`dev:${id}`, JSON.stringify(device), { expirationTtl: DEVICE_TTL });
  return json(204);
}

async function removeDevice(request, env, id) {
  if (!(await ownedDevice(request, env, id))) return json(404, { error: "no such device" });
  await env.STORE.delete(`dev:${id}`);
  return json(204);
}

/** What Apple is handed: words that say nothing, and the blob for the phone to open. */
function sealedNotification(payload) {
  return {
    aps: {
      alert: { title: "Redde", body: "Open Redde to see what's new." },
      sound: "default",
      "mutable-content": 1,
    },
    e: payload,
  };
}

async function pushToDevice(request, env, id) {
  const device = await ownedDevice(request, env, id);
  // "Gone" for a wrong secret too: either way this sender has no device here and should stop.
  if (!device) return json(410, { error: "gone" });
  if (env.PUSH_LIMIT && !(await env.PUSH_LIMIT.limit({ key: id })).success) return json(429, { error: "slow down" });
  const body = await readJSON(request, MAX_PAYLOAD + 400);
  if (!body || typeof body.payload !== "string" || !BLOB.test(body.payload)) return json(400, { error: "bad payload" });
  if (body.payload.length > MAX_PAYLOAD) return json(413, { error: "too large" });
  const jwt = await apnsJWT(env);
  if (!jwt) {
    console.log(`APNS_KEY not configured; would push ${body.payload.length} sealed characters`);
    return json(202, { apns: 0 });
  }
  const ttl = Math.max(0, Math.min(Number(body.ttl) || 3600, 24 * 3600));
  const origin = env.APNS_ORIGIN || `https://${device.env === "dev" ? "api.sandbox.push.apple.com" : "api.push.apple.com"}`;
  const res = await fetch(`${origin}/3/device/${device.token}`, {
    method: "POST",
    headers: {
      authorization: `bearer ${jwt}`,
      "apns-topic": env.APNS_TOPIC,
      "apns-push-type": "alert",
      "apns-priority": "10",
      "apns-expiration": String(Math.floor(Date.now() / 1000) + ttl),
      ...(typeof body.collapse === "string" && ID.test(body.collapse) ? { "apns-collapse-id": body.collapse } : {}),
    },
    body: JSON.stringify(sealedNotification(body.payload)),
  });
  if (res.ok) return json(202, { apns: res.status });
  const reason = (await res.json().catch(() => ({})))?.reason || "";
  if (res.status === 410 || reason === "Unregistered" || reason === "BadDeviceToken" || reason === "DeviceTokenNotForTopic") {
    await env.STORE.delete(`dev:${id}`);
    return json(410, { error: "gone" });
  }
  console.log(`apns error ${res.status} ${reason}`);
  return json(502, { error: "apns", status: res.status, reason });
}

async function leavePairing(request, env, rid) {
  if (!(await ownedDevice(request, env, request.headers.get("X-Redde-Device")))) return json(401, { error: "register first" });
  const body = await readJSON(request, MAX_PAIRING);
  if (!body || !BLOB.test(body.pub || "") || !BLOB.test(body.box || "")) return json(400, { error: "bad pairing" });
  await env.STORE.put(`pair:${rid}`, JSON.stringify({ pub: body.pub, box: body.box }), { expirationTtl: 600 });
  return json(204);
}

async function takePairing(env, rid) {
  const found = await env.STORE.get(`pair:${rid}`);
  if (!found) return json(404, { error: "nothing yet" });
  await env.STORE.delete(`pair:${rid}`);
  return json(200, JSON.parse(found));
}

async function handleV1(request, env, path) {
  const [, , resource, id, action] = path.split("/");
  const method = request.method;
  if (resource === "devices") {
    if (!id && method === "POST") return registerDevice(request, env);
    if (id && !action && method === "PUT") return updateDevice(request, env, id);
    if (id && !action && method === "DELETE") return removeDevice(request, env, id);
    if (id && action === "push" && method === "POST") return pushToDevice(request, env, id);
  }
  if (resource === "pairings" && /^[0-9a-f]{32}$/.test(id || "") && !action) {
    if (method === "PUT") return leavePairing(request, env, id);
    if (method === "GET") return takePairing(env, id);
  }
  return json(404, { error: "not found" });
}

export default {
  async fetch(request, env, ctx) {
    const url = new URL(request.url);
    if (url.pathname.startsWith("/v1/")) return handleV1(request, env, url.pathname);
    if (url.pathname === "/hermes" && request.method === "POST") return handleHermes(request, env, ctx);
    if (url.pathname === "/register" && request.method === "POST") return handleRegister(request, env, false);
    if (url.pathname === "/register" && request.method === "DELETE") return handleRegister(request, env, true);
    return new Response("redde push relay", { status: url.pathname === "/" ? 200 : 404 });
  },
};
