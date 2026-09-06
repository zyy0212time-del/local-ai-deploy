# RELEASE-READINESS — LocalAIDeploy v0.1.0

Audit date: 2026-09-06. Status: **FUNCTIONALLY READY — NEEDS FINAL MODEL
MANIFEST CONFIRMATION** (see gate P1-3 below).

## Validation evidence

| gate | result |
|---|---|
| deterministic unit tests | 48 passed / 0 failed |
| real end-to-end (isolated root, tiny GGUF, port 18100) | PASS — runtime download 140 MB, extract, launch, 4-stage health, owned stop, exit confirm |
| dry-run install (this machine: RTX 5060 Laptop 8 GB / 31.4 GB RAM) | PASS — correct profile, model, params, disk preflight, planned command |
| privacy scan | PASS after cleanup (no usernames, no private paths, no credentials, no private project names) |
| manifest schema gate | PASS — invalid manifests rejected with named problems |

## P0 gates (must be zero)

| # | gate | status |
|---|---|---|
| P0-1 | destructive file behavior (partial overwrite, verified-model overwrite) | PASS — size/SHA mismatch refuses with reason; partials owned by lock only |
| P0-2 | killing unrelated processes | PASS — stop refuses without PID+exe-path ownership proof; dead pid → stale-state clear only |
| P0-3 | multiple download writers | PASS — singleton lock, live-owner refusal, stale reclaim only on proven death |
| P0-4 | bad SHA accepted | PASS — size gate + SHA gate before atomic finalize; runtime assets size-only and explicitly marked sha_verified=false |
| P0-5 | privacy leak | PASS — cleaned (private project names and local ports removed from comments) |
| P0-6 | exposed server by default | PASS — 127.0.0.1 bind asserted in generated args; unit-tested |
| P0-7 | command injection | PASS — args generated from manifests/internal state; quoted; no shell interpolation of user input |
| P0-8 | modification of unrelated local assets | PASS — install root isolated; e2e used temp root only |

## P1 gates (must be zero)

| # | gate | status |
|---|---|---|
| P1-1 | broken resume | PASS — range probe + state file + 416/501/403 fallback restart (found and fixed in e2e) |
| P1-2 | wrong profile selection | PASS — unit-tested across 8/12/16 GB + AMD rejection |
| P1-3 | model manifests fully verified | **OPEN** — FAST candidate SHA-256 rests on Arena's frozen record, not locally recomputed (no local copy); acceptable but must be re-verified on first real download by the SHA gate |
| P1-4 | invalid runtime command | PASS — e2e launched real server; startup deadlock (pipe buffer) found and fixed |
| P1-5 | doctor gives wrong result | PASS on this machine; WARN paths covered |
| P1-6 | README install path doesn't work | PASS — Install-LocalAI.ps1 → local-ai.ps1 install verified via dry-run + e2e path |

## Known limitations (documented, not gates)

- Runtime archives: upstream publishes no per-asset checksum → size gate +
  post-install version probe only; recorded as `sha_verified=false`.
- q8_0 KV cache requires head_dim % 32 == 0 (documented in profiles; curated
  models satisfy it).
- The full 20 GB model download path is exercised by the same code as the
  tiny model (single code path), but a real 20 GB install has not been run.
