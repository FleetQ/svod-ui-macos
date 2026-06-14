#!/usr/bin/env node
// On-demand RunPod embedding for Svod.
//
//   node tooling/runpod-embed.mjs run     # create pod → embed vault → delete pod
//   node tooling/runpod-embed.mjs up      # just create+wait, print endpoint
//   node tooling/runpod-embed.mjs down    # delete the tracked pod
//   node tooling/runpod-embed.mjs status  # pod + embedding status
//
// Spins up a HuggingFace TEI pod serving BAAI/bge-m3 (OpenAI-compatible
// /v1/embeddings), points the local Svod engine at it, runs the background
// re-embed, then DELETES the pod so it stops costing money. The pod has no
// persistent volume — stopped = zero cost; deleted = gone (re-created next run).
//
// Needs: RunPod API key at ~/.config/svod/runpod-api.key (0600), and the Svod
// engine running on 127.0.0.1:7619.
import { readFileSync, writeFileSync, existsSync } from "node:fs";

const KEY = readFileSync(process.env.HOME + "/.config/svod/runpod-api.key", "utf8").trim();
const ENGINE = "http://127.0.0.1:7619/api/v1";
const VAULT = process.env.SVOD_VAULT || "personal";
const POD_FILE = "/tmp/svod-pod-id";
const RP = "https://rest.runpod.io/v1";
const H = { Authorization: "Bearer " + KEY, "Content-Type": "application/json" };
const log = (m) => console.log(`${new Date().toISOString()} ${m}`);
const sleep = (s) => new Promise((r) => setTimeout(r, s * 1000));
const proxy = (id) => `https://${id}-80.proxy.runpod.net`;

const CREATE = {
  name: "svod-bge-m3",
  imageName: "ghcr.io/huggingface/text-embeddings-inference:1.8",
  // cheap 16-24GB fallbacks (bge-m3 is small); RunPod picks the first available
  gpuTypeIds: ["NVIDIA RTX A4000", "NVIDIA RTX 2000 Ada Generation", "NVIDIA RTX A4500",
               "NVIDIA RTX 4000 Ada Generation", "NVIDIA RTX A5000", "NVIDIA GeForce RTX 3090"],
  gpuCount: 1, containerDiskInGb: 25, volumeInGb: 0, ports: ["80/http"],
  dockerStartCmd: ["--model-id", "BAAI/bge-m3", "--auto-truncate", "--max-client-batch-size", "256"],
  cloudType: "SECURE",
};

async function rp(method, path, body) {
  const r = await fetch(RP + path, { method, headers: H, body: body ? JSON.stringify(body) : undefined });
  const t = await r.text(); let b; try { b = JSON.parse(t); } catch { b = t; }
  return { status: r.status, body: b };
}
async function eng(method, path, body) {
  const r = await fetch(ENGINE + path, { method, headers: { "Content-Type": "application/json" }, body: body ? JSON.stringify(body) : undefined });
  const t = await r.text(); let b; try { b = JSON.parse(t); } catch { b = t; }
  return { status: r.status, body: b };
}

async function up() {
  const c = await rp("POST", "/pods", CREATE);
  if (c.status !== 201 || !c.body.id) throw new Error(`create failed ${c.status}: ${JSON.stringify(c.body).slice(0, 200)}`);
  const id = c.body.id;
  writeFileSync(POD_FILE, id);
  log(`pod ${id} created ($${c.body.costPerHr}/hr) — waiting for TEI…`);
  for (let i = 0; i < 48; i++) {
    try { if ((await fetch(proxy(id) + "/health", { signal: AbortSignal.timeout(8000) })).status === 200) { log(`TEI healthy: ${proxy(id)}`); return id; } } catch {}
    await sleep(10);
  }
  throw new Error("TEI did not become healthy in ~8min");
}

async function down(id) {
  id = id || (existsSync(POD_FILE) && readFileSync(POD_FILE, "utf8").trim());
  if (!id) { log("no pod id to delete"); return; }
  for (let i = 0; i < 5; i++) {
    const r = await rp("DELETE", `/pods/${id}`);
    if (r.status >= 200 && r.status < 300) { log(`pod ${id} deleted`); return; }
    log(`delete ${id} → ${r.status} (retry)`); await sleep(5);
  }
  log(`FAILED to delete ${id} — delete it manually in the RunPod console!`);
}

async function embed(id) {
  const ep = proxy(id);
  const put = await eng("PUT", `/embedder?vault=${VAULT}`, { provider: "remote-openai", model: "BAAI/bge-m3", endpoint: ep, maxThreads: 3 });
  if (put.status !== 200) throw new Error(`engine PUT /embedder ${put.status}: ${JSON.stringify(put.body).slice(0, 200)}`);
  log(`engine pointed at ${ep}; re-embedding…`);
  let last = -1, stalls = 0;
  while (true) {
    const e = (await eng("GET", `/index/status?vault=${VAULT}`)).body.embedding || {};
    const done = e.done || 0, total = e.total || 0;
    if (total > 0 && done >= total) { log(`done ${done}/${total}`); return; }
    if (e.state === "error") throw new Error(`embed error: ${e.error}`);
    if (e.state === "idle" && last >= 0) { log(`idle ${done}/${total}`); return; }
    stalls = done === last ? stalls + 1 : 0;
    if (stalls >= 18) throw new Error(`stalled at ${done}/${total}`);
    if (done !== last) log(`progress ${done}/${total} (${e.state})`);
    last = done; await sleep(10);
  }
}

const cmd = process.argv[2] || "run";
try {
  if (cmd === "up") { await up(); }
  else if (cmd === "down") { await down(process.argv[3]); }
  else if (cmd === "status") {
    const id = existsSync(POD_FILE) && readFileSync(POD_FILE, "utf8").trim();
    if (id) { const p = await rp("GET", `/pods/${id}`); log(`pod ${id}: ${p.body.desiredStatus}`); }
    log("embedding: " + JSON.stringify((await eng("GET", `/index/status?vault=${VAULT}`)).body.embedding));
  } else { // run
    const id = await up();
    try { await embed(id); } finally { await down(id); }
    log("RUN COMPLETE");
  }
} catch (e) {
  log("ERROR: " + e.message);
  if (cmd === "run") await down();   // never leave a pod running on failure
  process.exit(1);
}
