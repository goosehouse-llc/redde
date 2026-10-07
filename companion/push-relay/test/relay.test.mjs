// node --test companion/push-relay/test/
import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import { test } from "node:test";
import worker from "../src/index.js";
import { MemoryKV } from "./kv.mjs";

const TOKEN = "ab".repeat(32);
const SECRET = "s3cret-send-key-of-this-phone";
const auth = (secret) => createHash("sha256").update(secret).digest("hex");

/** A relay with Apple replaced by `apple(request) -> Response`; `sent` collects what Apple got. */
function relay(apple = () => new Response(null, { status: 200 })) {
  const env = { STORE: new MemoryKV(), APNS_TOPIC: "com.example.app", APNS_ORIGIN: "http://apple.test" };
  const sent = [];
  const realFetch = globalThis.fetch;
  globalThis.fetch = async (url, init) => {
    sent.push({ url: String(url), headers: init.headers, body: JSON.parse(init.body) });
    return apple(url, init);
  };
  const call = async (method, path, body, headers = {}) => {
    const response = await worker.fetch(
      new Request(`https://relay.test${path}`, {
        method,
        headers: { "content-type": "application/json", ...headers },
        body: body === undefined ? undefined : typeof body === "string" ? body : JSON.stringify(body),
      }),
      env,
      { waitUntil() {} },
    );
    const text = await response.text();
    const isJSON = (response.headers.get("content-type") || "").includes("json");
    return { status: response.status, body: text && isJSON ? JSON.parse(text) : text || null };
  };
  return { env, sent, call, restore: () => (globalThis.fetch = realFetch) };
}

const bearer = (secret = SECRET) => ({ Authorization: `Bearer ${secret}` });

async function registered(r) {
  const made = await r.call("POST", "/v1/devices", { token: TOKEN, env: "dev", auth: auth(SECRET) });
  assert.equal(made.status, 201);
  return made.body.id;
}

test("a phone registers and its Hermes pushes a sealed blob through", async () => {
  const r = relay();
  try {
    const id = await registered(r);
    assert.match(id, /^[A-Za-z0-9_-]{22}$/);
    const pushed = await r.call("POST", `/v1/devices/${id}/push`, { payload: "c2VhbGVk", collapse: "abcdef0123456789" }, bearer());
    assert.equal(pushed.status, 202);
    assert.equal(r.sent.length, 1);
    const apple = r.sent[0];
    assert.equal(apple.url, `http://apple.test/3/device/${TOKEN}`);
    assert.equal(apple.headers["apns-topic"], "com.example.app");
    assert.equal(apple.headers["apns-collapse-id"], "abcdef0123456789");
    assert.equal(apple.headers["apns-push-type"], "alert");
    // Apple is handed words that say nothing, the blob, and the flag that lets the phone open it.
    assert.deepEqual(apple.body, {
      aps: { alert: { title: "Redde", body: "Open Redde to see what's new." }, sound: "default", "mutable-content": 1 },
      e: "c2VhbGVk",
    });
  } finally {
    r.restore();
  }
});

test("what the relay keeps is the token, the secret's hash and a date", async () => {
  const r = relay();
  try {
    const id = await registered(r);
    const kept = JSON.parse(await r.env.STORE.get(`dev:${id}`));
    assert.deepEqual(Object.keys(kept).sort(), ["auth", "env", "seen", "token"]);
    assert.equal(kept.auth, auth(SECRET));
    assert.ok(!JSON.stringify(kept).includes(SECRET));
    assert.ok(r.env.STORE.ttl.get(`dev:${id}`) > 0, "a phone that stops checking in is forgotten");
    await r.call("POST", `/v1/devices/${id}/push`, { payload: "c2VhbGVk" }, bearer());
    assert.deepEqual([...r.env.STORE.map.keys()], [`dev:${id}`], "a push leaves nothing behind");
  } finally {
    r.restore();
  }
});

test("only the holder of the secret can push, change or remove a device", async () => {
  const r = relay();
  try {
    const id = await registered(r);
    assert.equal((await r.call("POST", `/v1/devices/${id}/push`, { payload: "c2VhbGVk" }, bearer("wrong"))).status, 410);
    assert.equal((await r.call("POST", `/v1/devices/${id}/push`, { payload: "c2VhbGVk" })).status, 410);
    assert.equal((await r.call("PUT", `/v1/devices/${id}`, { token: "cd".repeat(32), env: "prod" }, bearer("wrong"))).status, 404);
    assert.equal((await r.call("DELETE", `/v1/devices/${id}`, undefined, bearer("wrong"))).status, 404);
    assert.equal(r.sent.length, 0);
    assert.equal(JSON.parse(await r.env.STORE.get(`dev:${id}`)).token, TOKEN);

    assert.equal((await r.call("PUT", `/v1/devices/${id}`, { token: "CD".repeat(32), env: "prod" }, bearer())).status, 204);
    const kept = JSON.parse(await r.env.STORE.get(`dev:${id}`));
    assert.equal(kept.token, "cd".repeat(32));
    assert.equal(kept.env, "prod");
    assert.equal((await r.call("DELETE", `/v1/devices/${id}`, undefined, bearer())).status, 204);
    assert.equal(await r.env.STORE.get(`dev:${id}`), null);
    assert.equal((await r.call("POST", `/v1/devices/${id}/push`, { payload: "c2VhbGVk" }, bearer())).status, 410);
  } finally {
    r.restore();
  }
});

test("a registration or a push that isn't the right shape is refused", async () => {
  const r = relay();
  try {
    assert.equal((await r.call("POST", "/v1/devices", { token: "nope", env: "dev", auth: auth(SECRET) })).status, 400);
    assert.equal((await r.call("POST", "/v1/devices", { token: TOKEN, env: "dev", auth: SECRET })).status, 400, "the secret itself is never sent");
    assert.equal((await r.call("POST", "/v1/devices", "not json")).status, 400);
    const id = await registered(r);
    assert.equal((await r.call("POST", `/v1/devices/${id}/push`, { payload: "has spaces" }, bearer())).status, 400);
    assert.equal((await r.call("POST", `/v1/devices/${id}/push`, {}, bearer())).status, 400);
    assert.equal((await r.call("POST", `/v1/devices/${id}/push`, { payload: "A".repeat(3601) }, bearer())).status, 413);
    assert.equal((await r.call("GET", `/v1/devices/${id}`)).status, 404);
    assert.equal(r.sent.length, 0);
  } finally {
    r.restore();
  }
});

test("a token Apple no longer knows is forgotten, and the sender is told to stop", async () => {
  const r = relay(() => new Response(JSON.stringify({ reason: "Unregistered" }), { status: 410 }));
  try {
    const id = await registered(r);
    assert.equal((await r.call("POST", `/v1/devices/${id}/push`, { payload: "c2VhbGVk" }, bearer())).status, 410);
    assert.equal(await r.env.STORE.get(`dev:${id}`), null);
  } finally {
    r.restore();
  }
});

test("another failure at Apple's end is reported and the device kept", async () => {
  const r = relay(() => new Response(JSON.stringify({ reason: "TooManyRequests" }), { status: 429 }));
  try {
    const id = await registered(r);
    const pushed = await r.call("POST", `/v1/devices/${id}/push`, { payload: "c2VhbGVk" }, bearer());
    assert.equal(pushed.status, 502);
    assert.equal(pushed.body.reason, "TooManyRequests");
    assert.notEqual(await r.env.STORE.get(`dev:${id}`), null);
  } finally {
    r.restore();
  }
});

test("a sender that floods is slowed, when the account has a limiter bound", async () => {
  const r = relay();
  try {
    let allowed = 2;
    r.env.PUSH_LIMIT = { limit: async ({ key }) => ({ success: key && allowed-- > 0 }) };
    const id = await registered(r);
    const statuses = [];
    for (let i = 0; i < 3; i++) statuses.push((await r.call("POST", `/v1/devices/${id}/push`, { payload: "c2VhbGVk" }, bearer())).status);
    assert.deepEqual(statuses, [202, 202, 429]);
  } finally {
    r.restore();
  }
});

test("a pairing is left by a registered phone and taken once", async () => {
  const r = relay();
  try {
    const id = await registered(r);
    const rid = "0123456789abcdef0123456789abcdef";
    const answer = { pub: "cHVibGlj", box: "Ym94" };
    assert.equal((await r.call("GET", `/v1/pairings/${rid}`)).status, 404);
    assert.equal((await r.call("PUT", `/v1/pairings/${rid}`, answer)).status, 401, "not from just anyone");
    assert.equal((await r.call("PUT", `/v1/pairings/${rid}`, answer, { ...bearer("wrong"), "X-Redde-Device": id })).status, 401);
    assert.equal((await r.call("PUT", `/v1/pairings/${rid}`, answer, { ...bearer(), "X-Redde-Device": id })).status, 204);
    assert.equal(r.env.STORE.ttl.get(`pair:${rid}`), 600);
    const taken = await r.call("GET", `/v1/pairings/${rid}`);
    assert.equal(taken.status, 200);
    assert.deepEqual(taken.body, answer);
    assert.equal((await r.call("GET", `/v1/pairings/${rid}`)).status, 404, "read once");
    assert.equal((await r.call("PUT", "/v1/pairings/not-a-slot", answer, { ...bearer(), "X-Redde-Device": id })).status, 404);
  } finally {
    r.restore();
  }
});

test("the household webhook routes are still there", async () => {
  const r = relay();
  try {
    r.env.REGISTER_SECRET = "house";
    assert.equal((await r.call("POST", "/register", { token: TOKEN, env: "dev" }, bearer("house"))).status, 204);
    assert.equal((await r.call("POST", "/register", { token: TOKEN, env: "dev" }, bearer("nope"))).status, 401);
    assert.notEqual(await r.env.STORE.get(`tok:${TOKEN}`), null);
  } finally {
    r.restore();
  }
});
