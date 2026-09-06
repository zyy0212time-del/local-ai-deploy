# LocalAIDeploy

**Benchmark-driven local AI deployment for consumer NVIDIA PCs.**

From hardware detection to a verified local model and an OpenAI-compatible
API — without manually choosing GGUFs, runtimes, or launch parameters.

Model recommendations are grounded in real local evaluation from
[Reasoning Budget Arena](https://github.com/zyy0212time-del/reasoning-budget-arena):
Arena answers *"which model is worth deploying?"*; this project answers
*"how does a normal user actually get it running?"*.

> Status: **v0.1.0 — prototype, Windows + NVIDIA + llama.cpp only.**
> See [docs/SCOPE.md](docs/SCOPE.md) for exactly what is and is not supported.

---

## What this does

One command:

```powershell
powershell -ExecutionPolicy Bypass -File .\Install-LocalAI.ps1
```

does all of the following:

1. detects your hardware (GPU, VRAM, RAM, disk, CPU)
2. checks it against the supported range
3. recommends a curated deployment profile
4. downloads a pinned llama.cpp build (verified Windows CUDA asset)
5. downloads a pinned, checksum-verified GGUF (resumable, single-writer)
6. generates the runtime configuration for your hardware class
7. launches `llama-server` on **localhost only**
8. runs a real health gate (process → HTTP → alias → minimal inference)
9. prints your API URL, model alias, and the management commands

You never need to: find a GGUF, guess a quantization, calculate VRAM
fit, hand-write launcher flags, or configure an API endpoint.

## Who this is for

Windows 10/11 users with a consumer NVIDIA GPU (8–16 GB VRAM class) and
24–64 GB of system RAM who want a vetted local model running behind an
OpenAI-compatible API with minimal manual work — especially 8 GB VRAM +
32 GB RAM laptops that cannot hold a 20–35 B-class MoE GGUF fully in
VRAM but can run it well with partial CPU offload.

If you are outside that range, this tool will tell you plainly rather
than pretend.

## Curated profiles

| category | model | Formal C (Arena) | status |
|---|---|---|---|
| BALANCED | Huihui Nex N2 Mini Abliterated Q4_K_M | 669.5 / 800 | READY |
| CYBER / UNCENSORED | Gemma4-26B-A4B-…-HauhauCS-Balanced Q4_K_M | 706.0 / 800 | READY |
| FAST | Qwen3.8-9B-abliterated-25 Q4_K_M | 635.0 / 800 | READY |

Every model manifest pins: source repo, revision, filename, exact size,
SHA-256, license, and links the Arena evidence. Nothing is fetched from
"latest". `local-ai models` prints this list with verification status.

Benchmark evidence lives in Reasoning Budget Arena (frozen Formal C
protocol, blind judge, locked scores). Deployment decisions here are
derived from it, never from vibes.

## Commands

```
.\local-ai.ps1 install          # detect → profile → download → verify → launch → health
.\local-ai.ps1 install --dry-run  # show the full plan without changing anything
.\local-ai.ps1 start            # start the configured server
.\local-ai.ps1 stop             # stop (only the process this install owns)
.\local-ai.ps1 status           # profile / model / runtime / running state
.\local-ai.ps1 doctor           # PASS/WARN/FAIL diagnostics, non-destructive
.\local-ai.ps1 models           # curated manifests + verification status
.\local-ai.ps1 profile          # which profile your hardware matches
```

## Model provenance

Every manifest (`models/*.json`) records where the file came from and how
it was verified:

- Hugging Face repo + pinned revision
- exact byte size + SHA-256 (from frozen Arena records and/or local
  recomputation — the evidence source is named per field)
- license
- mmproj requirement for multimodal models
- Arena benchmark link

Downloads are gated: exact size match **and** SHA-256 match, then an
atomic rename. A partial file is never accepted as a model.

## Privacy & security

- server binds **127.0.0.1** — never exposed to the LAN by default
- no telemetry, no API keys, no credential storage
- pinned runtime and model versions; no silent "latest" fetches
- `stop` refuses to kill any process it cannot prove it owns
- installer never asks you to disable Defender or change global
  execution policy (`-ExecutionPolicy Bypass` is per-process only)

## Limitations (v0.1)

- Windows 10/11 + NVIDIA + llama.cpp only — no AMD/Intel/CPU-only/macOS/Linux
- one curated model per category; this is not a model marketplace
- no GUI, no auto-start-on-boot, no agent/tool-loop evaluation
- performance expectations are stated as hardware classes, not promised t/s
- runtime archives: upstream publishes no per-asset checksum, so runtime
  verification is size + extraction + version probe (documented per field)
- quantized KV cache (`q8_0`) requires head_dim divisible by 32; the
  curated models satisfy this, exotic models may need `f16`

## Roadmap

- **v0.2 candidate — FreeToken optional performance backend**: for
  supported NVIDIA GPUs and MoE-heavy models, traded against maturity.
  Not required for anything in v0.1.
- runtime update flow (download → verify → atomic switch)
- broader hardware profiles, more curated models as Arena evidence grows

## License

Project code: MIT (see [LICENSE](LICENSE)). Third-party runtimes and
models remain under their own licenses — attribution per model is in its
manifest; nothing here relicenses them.
