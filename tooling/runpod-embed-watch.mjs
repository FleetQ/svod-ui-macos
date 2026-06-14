// Background watcher: polls the Svod engine's embedding progress; when the vault
// is fully embedded (or it errors/stalls), DELETES the RunPod pod so it stops
// costing money. Reusable: pass POD_ID as argv[2].
import { readFileSync } from "node:fs";

const ENGINE = "http://127.0.0.1:7619/api/v1";
const VAULT = "personal";
const POD_ID = process.argv[2] || readFileSync("/tmp/svod-pod-id", "utf8").trim();
const KEY = readFileSync(process.env.HOME + "/.config/svod/runpod-api.key", "utf8").trim();
const log = (m) => console.log(`${new Date().toISOString()} ${m}`);

async function status() {
  const r = await fetch(`${ENGINE}/index/status?vault=${VAULT}`);
  return (await r.json()).embedding || {};
}
async function deletePod() {
  for (let i = 0; i < 5; i++) {
    try {
      const r = await fetch(`https://rest.runpod.io/v1/pods/${POD_ID}`, {
        method: "DELETE", headers: { Authorization: "Bearer " + KEY },
      });
      if (r.status >= 200 && r.status < 300) return r.status;
      log(`delete attempt ${i + 1} → ${r.status}`);
    } catch (e) { log(`delete err: ${e.message}`); }
    await new Promise((r) => setTimeout(r, 5000));
  }
  return -1;
}

let last = -1, stalls = 0, outcome = "unknown";
log(`watching embed; pod=${POD_ID}`);
while (true) {
  let e;
  try { e = await status(); } catch (x) { await new Promise(r=>setTimeout(r,5000)); continue; }
  const done = e.done || 0, total = e.total || 0;
  if (total > 0 && done >= total) { outcome = `done ${done}/${total}`; break; }
  if (e.state === "error") { outcome = `error: ${e.error || "?"}`; break; }
  if (e.state === "idle" && last >= 0) { outcome = `idle ${done}/${total}`; break; }
  stalls = (done === last) ? stalls + 1 : 0;
  if (stalls >= 18) { outcome = `stalled at ${done}/${total}`; break; }   // ~3min no progress
  if (done !== last) log(`progress ${done}/${total} (${e.state})`);
  last = done;
  await new Promise((r) => setTimeout(r, 10000));
}
log(`EMBED ${outcome} — deleting pod ${POD_ID}`);
const del = await deletePod();
log(`pod delete → ${del === -1 ? "FAILED (delete manually!)" : "OK (" + del + ")"}`);
log("WATCHER DONE");
