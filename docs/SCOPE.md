# Scope — LocalAIDeploy v0.1

## Supported (v0.1)

| dimension | value |
|---|---|
| OS | Windows 10, Windows 11 (x64) |
| GPU | NVIDIA only |
| VRAM | 8–16 GB target range (6.5–24 GB matching window) |
| System RAM | 24–64 GB target range (16 GB hard floor) |
| Model format | GGUF |
| Runtime | llama.cpp `llama-server` (pinned b10375) |
| API | OpenAI-compatible, localhost only |
| Categories | BALANCED, CYBER/UNCENSORED, FAST (one curated model each) |

## Explicitly NOT supported in v0.1

- FreeToken / Ollama / vLLM backends (FreeToken is the v0.2 candidate)
- AMD, Intel GPU, CPU-only deployment
- macOS, Linux
- Docker-first or Kubernetes deployment
- cloud inference
- model marketplace / arbitrary HuggingFace browser
- integration with any private local agent stack
- agent or tool-loop benchmarking
- auto-start-on-boot
- GUI desktop app
- auto-updating models (pinned revisions are the point)
- exposing the server beyond localhost

## Non-goals (permanent)

- "Run any LLM on any PC." This tool works for one narrow hardware class and
  says no outside it.
- Performance promises. Outputs are described as hardware classes; no t/s
  claims without matching evidence.

## FreeToken roadmap (documented, NOT implemented)

v0.2 candidate: an optional performance backend for supported NVIDIA GPUs
with MoE-heavy models and RAM/VRAM mixed deployment, for users willing to
trade maturity/compatibility for speed. It will be added through the runtime
abstraction; installer, profiles, manifests and downloader will not change.
Nothing in v0.1 depends on it.
