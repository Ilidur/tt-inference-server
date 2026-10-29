# Qwen3.6/3.8-27B on T3K: serving image test results (2026-10-29)

Image `localhost/qwen36-35b-a3b-t3k:7bbd71239ae7-28f15e52d746` ("slots" design: GDN state in model-owned
per-slot buffers, one KV group, block_size 64, no prefix caching), built by `build_qwen36_35b_t3k_image.sh`.

| Component | Commit |
|---|---|
| tt-metal | `7bbd71239ae` on `qwen36-t3k-slots`: `f72d23b792d` + conv1d use-after-free fix (`22e5f5d7d63`), the same fix in `_posterior_device` (`fe127130378`), demo matrix |
| vllm-tt-plugin | `28f15e52d746` (upstream main, 2026-09-30), unmodified |
| tt-inference-server | this branch (`qwen36-t3k-serving`); the exact SHA is in the image label `org.qwen36.tt-inference-server-commit` |

Served as `Qwen/Qwen3.8-27B`, `--max-model-len 131072 --max-num-seqs 2`, KV pool 262144 tokens
(`scripts/qwen36_t3k/serve.sh`; sizes come from the catalog entry for the model). Warm-cache boot to /health: ~3 min.

| Suite (`scripts/qwen36_t3k/test_long_context.py`) | Result |
|---|---|
| a. Hermes 17k-token tool-call replay x3 | 3/3 return tool_calls |
| b. needle recall 32k/64k/100k/125k (125k at depth .05 and .95) | 5/5 |
| c. padded tool calls at ~74k prompt | 2/2 |
| c. target 120000 | 2 x HTTP 400: test overshoots the 131072 limit (prompt >= 129573 + 1500 output); not a server fault, covered by e and soak below |
| d. two concurrent 60k requests | 2/2 |
| e. tool calls at 115k and 128k prompts (x2 each), 125k needles x3 | 7/7 |
| f. temperature-0 determinism, 300/800/1500/3000/6000 tokens, 6 runs each | 1 unique output each (the use-after-free regression check) |
| g. streaming: reasoning stays in `reasoning`, no `<think>` leak, tool calls structured | PASS |
| soak: 10 back-to-back ~125k-token tool-call prefills | 10/10, no engine death |

No `TT_THROW`/`TT_FATAL`/timeout/traceback lines in the container log after the whole run.

Caveats
- The intermittent fabric/all_gather hang seen earlier (roughly 1 in 3-7 long prefills) did not occur in
  these 10 soak requests plus the ~20 other long prefills, but it was never root-caused, so a clean run is not proof it is gone.
- Soak latency varied 93-175 s for identical requests.
- "Qwen3.6-35B-A3B" and "Qwen3.5-0.8B" catalog entries are in `llm.yaml` but were not served in this run.
- Prefix caching is not part of this design; every turn re-prefills.
