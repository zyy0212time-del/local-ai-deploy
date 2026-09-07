# RELEASE-READINESS — LocalAIDeploy v0.1.0

Audit date: 2026-09-07. Status: **PUBLISHED — v0.1.0**
(this document describes the final public v0.1.0 release state: all P0 = 0,
all P1 = 0; full-size real-install evidence loop completed — see
"Full-size evidence loop" below).

## Validation evidence

| gate | result |
|---|---|
| deterministic unit tests | 85 passed / 0 failed |
| adversarial wrapper-injection tests | 17 passed / 0 failed |
| real CLI invocations | 12 passed / 0 failed |
| real end-to-end (isolated root, tiny GGUF, port 18100) | PASS — runtime download 140 MB, extract, launch, 4-stage health, owned stop, exit confirm |
| dry-run install (this machine: RTX 5060 Laptop 8 GB / 31.4 GB RAM) | PASS — correct profile, model, params, disk preflight, planned command |
| privacy scan | PASS (0 hits after cleanup; re-scanned after every round) |
| manifest schema gate | PASS — invalid manifests rejected with named problems |

## Full-size evidence loop (2026-09-06)

1. **Runtime asset SHA256 pinned**: `cuda-13.3` asset re-downloaded in full
   (146,639,481 bytes, size-gate pass) and hashed locally:
   `5e352df7d32abe99427160d26069e8eedab79ae08fbfe737616c6cd62837975a`.
   The install path now enforces it via the SHA gate. The `cuda-12.4` fallback
   variant (250,753,377 bytes) was pinned the same way on 2026-09-07:
   `dd840b604c508b2f57f2ed467f70c711d1840c07b0d09a3bba8f6dfbd8b3da84`, and is
   now VERIFIED/selectable. A generic fail-closed gate additionally prevents
   any unpinned runtime variant from being selected or installed (F-01).
2. **Model manifests re-verified**:
   - BALANCED Huihui: SHA-256 recomputed locally over the full
     21,166,757,888-byte file during the real install — matched the pinned
     `8e38d2a0…` (three-way: local / Arena / HF pinned revision).
   - CYBER Gemma: SHA-256 recomputed locally over the full 16,796,015,520-byte
     file — matched the Arena frozen record `3c131334…` exactly.
   - FAST Qwen: no local copy; SHA rests on the Arena frozen record plus an
     exact HF `x-linked-size` cross-check. First real download will be
     enforced by the SHA gate regardless.
3. **Real full-size install** (isolated `%LOCALAPPDATA%` root): model present
   → SHA256 gate (21 GB hash) → mmproj SHA gate → config → launch →
   process/HTTP/alias/**real inference** all PASS.
   Honest note: the 20 GB model bytes were seeded from the locally verified
   copy instead of re-downloaded, because direct HF throughput measured
   ~0.02 MB/s at validation time (≈58 h for 20 GB). Every byte was still
   verified by the same SHA gate a download would pass; the network transfer
   path itself is proven by the 140 MB runtime + 1.2 MB tiny-model downloads.
4. **Interrupted-download / resume exercise**: an active install was killed
   mid-download. Findings fixed on the spot:
   - the `.part.state` was only written after a completed read loop → an
     interrupted download left an "orphan" partial (refused to resume);
     state is now written up-front and refreshed every 64 MB;
   - a lock-owned partial without state is now safely restarted from zero
     (ownership proven by the lock), instead of failing the install;
   - a Range-rejected retry (416/501/403) restarts from zero over the
     owned partial.
   The singleton lock was additionally proven live: a second installer was
   refused with `another installer process (pid N) owns this artifact`.
5. **Real load + inference**: 35B-class MoE loaded (partial CPU offload);
   OpenAI-compatible chat completion returned a correct answer ("Canberra")
   through `http://127.0.0.1:18100/v1`.
6. **stop / restart / doctor**: stop released the port; restart relaunched;
   doctor 14/15 PASS with the single FAIL being a true positive (low disk).
   Found and fixed: `start`'s variable collided with the typed CLI parameter
   (`$Model`) and the built-in `$PROFILE`; health used an unguarded property
   under StrictMode.
7. **Clean uninstall**: default uninstall removes runtime/config/logs/
   downloads and keeps models. Found and fixed: with a lost state file the
   owned server could not be stopped — a path-ownership fallback
   (executable under `<root>\runtime\`) now stops it; it also cleaned up
   five orphaned llama-server instances from the restart attempts.
   `uninstall -RemoveModels` removed 20.78 GB and emptied the install root;
   `C:` free went 4.7 GB → 48.3 GB. Unrelated models under the user's
   separate model directory were untouched.

## P0 gates (must be zero)

| # | gate | status |
|---|---|---|
| P0-1 | destructive file behavior (partial overwrite, verified-model overwrite) | PASS — size/SHA mismatch refuses with reason; partials owned by lock only |
| P0-2 | killing unrelated processes | PASS — PID+exe ownership, plus path-ownership fallback strictly scoped to `<root>\runtime\` |
| P0-3 | multiple download writers | PASS — singleton lock proven live (second installer refused) |
| P0-4 | bad SHA accepted | PASS — model SHA gate exercised on 21 GB real bytes; runtime SHA now pinned and enforced |
| P0-5 | privacy leak | PASS — 0 hits on final scan |
| P0-6 | exposed server by default | PASS — 127.0.0.1 only, unit-tested |
| P0-7 | command injection | PASS — wrapper args travel as typed JSON → UTF-8 Base64 inert data → project-owned decode → PowerShell splatting, so user data cannot mint extra switches; `llama-server` args still come from manifests/internal state and are quoted. 17/17 adversarial injection tests passed. |
| P0-8 | modification of unrelated local assets | PASS — unrelated model directory verified untouched after uninstall |

## P1 gates (must be zero)

| # | gate | status |
|---|---|---|
| P1-1 | broken resume | PASS — interrupted-download exercise; two resume defects found and fixed |
| P1-2 | wrong profile selection | PASS — unit-tested |
| P1-3 | model manifests fully verified | PASS — Huihui + Gemma recomputed locally; Qwen rests on Arena frozen record + HF size cross-check, SHA-gate enforced on first download |
| P1-4 | invalid runtime command | PASS — real launches (tiny + full-size model) |
| P1-5 | doctor gives wrong result | PASS — 14/15 with true-positive disk FAIL |
| P1-6 | README install path doesn't work | PASS |

## Known limitations (documented, not gates)

- Both runtime variants are now integrity-pinned (cuda-13.3 and cuda-12.4,
  SHA-256 computed locally over the complete official assets). A generic
  fail-closed gate in `LlamaCpp.Test-VariantEligible` / `Select-Variant` /
  the install path means a variant with a missing, malformed or non-VERIFIED
  sha256 can be neither selected nor installed: install would fail with
  `Runtime variant '<id>' is not integrity-pinned and cannot be installed.`
  Size-only runtime success is no longer possible.
- Quantized KV cache (q8_0) requires head_dim divisible by 32 (documented).
- Full 20 GB network download itself was not completed end-to-end due to
  measured HF throughput; integrity path proven by the SHA gate + the 140 MB
  and 1.2 MB real downloads sharing the same code path.
