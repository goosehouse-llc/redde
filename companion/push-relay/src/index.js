// Redde push relay: receives hermes outbound webhooks (HMAC-signed, GitHub-style),
// maps the events worth a banner into APNs alerts, and fans them out to every
// registered device token. Tokens register from the app with a bearer secret.
//
// Routes:
//   POST   /register  {token, env: "dev"|"prod"}   Authorization: Bearer <REGISTER_SECRET>
//   DELETE /register  {token}                      same auth
//   POST   /hermes    hermes outbound webhook      X-Hermes-Signature-256 verified
//
// Without APNS_KEY configured, webhook handling still verifies/dedupes and logs
// what it would send — so the pipeline can be wired end to end before the key exists.

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

export default {
  async fetch(request, env, ctx) {
    const url = new URL(request.url);
    if (url.pathname === "/hermes" && request.method === "POST") return handleHermes(request, env, ctx);
    if (url.pathname === "/register" && request.method === "POST") return handleRegister(request, env, false);
    if (url.pathname === "/register" && request.method === "DELETE") return handleRegister(request, env, true);
    return new Response("redde push relay", { status: url.pathname === "/" ? 200 : 404 });
  },
};
