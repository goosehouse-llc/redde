// The relay on this machine, for trying the whole path without Cloudflare or Apple:
//
//   node companion/push-relay/test/local.mjs [port] [apple]
//
// `apple` is where notifications go instead of Apple (default http://127.0.0.1:18990, where
// scripts/hermes-lab/fake_apns.py hands them to a simulator). Devices live in memory.
import { createServer } from "node:http";
import worker from "../src/index.js";
import { MemoryKV } from "./kv.mjs";

const port = Number(process.argv[2] || 18980);
const env = { STORE: new MemoryKV(), APNS_TOPIC: "com.goosehouse.echo", APNS_ORIGIN: process.argv[3] || "http://127.0.0.1:18990" };

createServer(async (req, res) => {
  const chunks = [];
  for await (const chunk of req) chunks.push(chunk);
  const body = Buffer.concat(chunks);
  const request = new Request(`http://127.0.0.1:${port}${req.url}`, {
    method: req.method,
    headers: req.headers,
    body: ["GET", "HEAD"].includes(req.method) || !body.length ? undefined : body,
  });
  let response;
  try {
    response = await worker.fetch(request, env, { waitUntil() {} });
  } catch (error) {
    response = new Response(String(error), { status: 500 });
  }
  console.log(`${req.method} ${req.url.replace(/\/v1\/(devices|pairings)\/[^/]+/, "/v1/$1/…")} -> ${response.status}`);
  res.writeHead(response.status, Object.fromEntries(response.headers));
  res.end(Buffer.from(await response.arrayBuffer()));
}).listen(port, "127.0.0.1", () => console.log(`relay on http://127.0.0.1:${port}, Apple is ${env.APNS_ORIGIN}`));
