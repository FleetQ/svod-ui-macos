# Retrieval eval harness, embedder prefixes, weighted fusion (2026-08-20)

## Overview

SHIPPED in **engine v1.19.0** (contract 0.28.0). PRs #14 (harness) + #16 (reranker + fixes) merged.
Suite 361 → 407 tests. Docs: `docs/{design,architecture,test-plan}-retrieval-quality.md`, Units 3–4.

An eval harness was built to measure retrieval; it then found four defects, three of them silent,
one of them in the harness itself. **The harness is the deliverable — the fixes are what it caught.**

## Key patterns — what is TRUE (real vault: 3384 notes, 79k chunks, 45 hand-labelled queries)

Production search path, `bge-m3` via Ollama, in the order the fixes landed:

| | nDCG@10 | note |
|---|---|---|
| before (e5 prefixes on bge-m3, equal RRF legs) | 0.390 | what v1.18.1 shipped |
| + prefix fix | 0.460 | +18% |
| + semantic weight 3.0 | **0.515** | now above its own SEMANTIC leg (0.490) |

- **Cross-lingual is a DEFAULT-MODEL problem.** On `multilingual-e5-small` it is a HARD ZERO —
  across 13 cross-language queries not one relevant note reaches the top 10. `bge-m3` gives
  bg→en 0.174 / en→bg 0.372. A reranker **cannot** fix this: it only reorders the candidate window,
  and the note was never in it. **Fix the first stage, then rerank.**
- **Reranker ships DISABLED.** Quality earns it (+0.09 nDCG on a good first stage); latency does
  not — top-50 at realistic passage length costs ~11 s locally and **2.3–7.5 s on a RunPod GPU**
  (`bge-reranker-v2-m3`). A GPU did not rescue it; the ceiling is model size + round trip.
- Absolute leg-V numbers are a LOWER BOUND (1–2 labelled notes per query out of 3384; search often
  returns a different-but-reasonable note). Comparisons are trustworthy; levels are not.

## Constraints — the four defects, and why each was invisible

1. **e5 prefixes fed to every model.** `OllamaEmbedder` hardcoded `"query: "`/`"passage: "`;
   bge-m3's own README says it needs none. Silent — retrieval just gets worse. Now `ModelPrefixes`
   derives them from the model name, defaulting to NONE for unknown models.
   `passagePrefix` joined `IndexMeta`'s compatibility key, so affected vaults re-embed once.
2. **`knownDim() == 0` does NOT mean "no vectors".** A remote embedder reports 0 until its first
   successful embed and `saveMeta` persists it, so a fully-populated Ollama vault routinely stores
   `embeddingDim: 0`. A guard reading 0 as "lexical-only" skipped the migration for two live vaults
   and then wrote a prefix they were not built with — a **self-sealing** mismatch that could never
   correct itself. Only `embeddingModel == "none"` means vector-less.
   **Caught only by deploying. 407 tests did not see it.**
3. **Remote rerank 413'd on every call.** TEI caps a request at 32 texts, `rerankTopK` is 50;
   `maybeRerank` logged and degraded to the fused order, so the eval printed a full, plausible set
   of "reranking doesn't help" numbers. Now batched client-side, with leg V asserting the reranked
   pass actually moved a result.
4. **The hermetic CI gate could not measure retrieval.** Leg P's embedder hashed the whole string —
   its "semantic" leg was noise, so its fusion floors measured BM25-fused-with-noise and would fail
   ANY change that trusted semantics more, regardless of merit. Replaced with `BagOfWordsEmbedder`;
   floors re-baselined UP. **I nearly lowered that gate to make my own change pass.**

## F2 — SOLVED, and the earlier refutation was WRONG

Previous version of this memory said "weighting refuted, cause unknown". **That refutation was
measured on the 27-note synthetic corpus, where both legs are strong and every relevant note is in
the candidate window by construction — a corpus that structurally cannot exhibit F2.** On the real
vault, where legs are unequal (semantic 0.49 vs keyword 0.18), weighting is decisive.

`Rrf.DEFAULT_SEMANTIC_WEIGHT = 3.0`, from the LOW end of a flat 2–10 plateau, because the constant
assumes semantic > keyword and **amplifies the damage where that is false** (leg P: −0.027).

Also refuted, this time correctly and by measurement: the RRF `k` constant. No value rescues fusion
(k=0 → 0.435, best k=20 → 0.476, k=60 → 0.463, all under SEMANTIC's 0.520).

**A wrong refutation is worse than a wrong number: it closes the question permanently.**
Before believing one, ask whether the data could have shown the effect at all.

## Engineering gotchas worth keeping

- **DJL 0.30.0 `CrossEncoderTranslator` is unusable** — tensors reach ORT as `uint32`. Hand-write
  the translator with explicit int64, NAMED arrays (ONNX binds by name), `getBatchifier()` → null.
- **Read the ONNX graph's inputs, never infer.** mmarco has no `token_type_ids`; e5-small's export
  needs it; e5-base's does not (`OnnxConfig.includeTokenTypes`).
- **HF quantized exports are architecture-specific** (`qint8_arm64`, `quint8_avx2`). Pin fp32.
- **Cloudflare-fronted hosts (RunPod) 403 the JDK's default `Java-http-client/NN` agent** —
  "error code: 1010". Both remote clients send a conventional `User-Agent`.
- **Server batch caps are the client's problem.** TEI's default is 32 for BOTH `/rerank` and
  `/v1/embeddings`. `IndexService` already capped embeds at 32; the reranker did not.
- **The contract version has FOUR homes** — `VersionConsistencyTest` catches drift; trust it.
- **Injected dependencies are not owned.** `VaultContext` creates the embedder/reranker, so it
  closes them; closing in `IndexService.close()` double-closed the ONNX session.
- Env: `curl` and `ls -la` are intercepted — use python `urllib` / node `fetch` and `/bin/ls`.
  Two concurrent `./gradlew test` runs corrupt `build/test-results`; never read results mid-run.
- The reranker latency gate **flakes under load** (20 s vs a 4 s ceiling while a re-embed runs).
  Not fixed — a latency test failing on a loaded machine is arguably correct. CI on an idle runner
  is the arbiter. Left as a known flake, deliberately.

## File locations

- `engine/src/main/kotlin/dev/svod/engine/index/` — `Rrf.kt`, `Embedder.kt` (`ModelPrefixes`),
  `IndexMeta.kt`, `OllamaEmbedder.kt`, `OpenAiEmbedder.kt`, `RemoteReranker.kt`, `OnnxLocalReranker.kt`
- `engine/src/test/.../index/` — `RetrievalEval*.kt` (legs P/S/V), `FusionWeightSweepTest.kt`
  (k + weight sweeps, real vault), `ModelPrefixTest.kt`, `GoldenCorpus.kt`
- Golden set OUTSIDE git: `~/.svod-eval/personal-golden.jsonl` (private notes)

## Eval harness usage

```
./gradlew test --tests "*RetrievalEvalTest" \
  -Dsvod.eval.vault=~/Svod/personal \
  -Dsvod.eval.golden=~/.svod-eval/personal-golden.jsonl \
  -Dsvod.eval.embedder=ollama:bge-m3 \        # or openai:<endpoint>::<model>
  -Dsvod.eval.indexDir=<existing>             # skips a ~60 min re-embed
# add -Dsvod.eval.sweep=1 for the k / weight sweeps (FusionWeightSweepTest)
# -Dsvod.eval.diag is REQUIRED for the rank diagnostic — it opens the index with the DEFAULT
#   embedder, which wipes and re-embeds an index built by any other model. It destroyed every
#   cached bge-m3 eval index on this machine before it was gated.
```

`# Section ...` comments in the golden set become reporting groups — that split is what exposed
the cross-lingual collapse the aggregate hid.

## Last Updated

2026-08-20 — v1.19.0 released. Supersedes the 2026-08-19 revision, whose F2 conclusion was wrong.

See also [[svod-engine-deploy-launchd]] (the v1.19.0 cut + two release-process defects),
[[svod-graphrag-tuning-and-ux]], and the standing lessons on wrong-subject numbers and negative
test verification — both fired repeatedly here.
