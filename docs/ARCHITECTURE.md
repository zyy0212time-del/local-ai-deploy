# Architecture — LocalAIDeploy v0.1

## Design principles

1. **Reliable installation beats fast installation.** The parameter planner
   always prefers a configuration that loads.
2. **Pinned, verifiable artifacts.** Models: revision + size + SHA-256.
   Runtime: pinned build tag + exact asset size. Nothing implicit.
3. **Ownership everywhere.** Downloads carry a singleton lock; the server
   carries a PID+path ownership record. Nothing is killed or deleted that
   cannot be proven ours.
4. **Backend-agnostic core.** Only v0.1's default runtime is llama.cpp; the
   installer, profiles, manifests and downloader do not know about it.

## Repository layout

```
local-ai.ps1                  CLI entry (install/start/stop/status/doctor/models/profile/update)
Install-LocalAI.ps1           one-click wrapper
src/
  core/
    Config.psm1               install root + paths + JSON state helpers
    Log.psm1                  timestamped local logs
    Manifests.psm1            model/profile/runtime manifest loading + schema validation
    Hardware.psm1             OS/GPU/VRAM/RAM/disk detection
    Profiles.psm1             profile matching + parameter planner + disk preflight
    Download.psm1             resumable, singleton, integrity-gated downloader
    Process.psm1              server state, ownership checks, port selection
  runtime/
    Runtime.psm1              runtime registry (interface)
    LlamaCpp.psm1             llama.cpp implementation (v0.1 only)
  commands/doctor.ps1         diagnostics command
models/*.json                 curated model manifests (pinned)
profiles/*.json               hardware profiles + planner defaults
runtimes/llama-cpp-b10375.json pinned runtime manifest
tests/                        unit tests + bounded real E2E
docs/                         this file + SCOPE.md
```

## Install root

Default `%LOCALAPPDATA%\LocalAIDeploy`, overridable with `LOCALAI_HOME`.
Layout: `runtime\`, `models\`, `config\`, `logs\`, `state\`, `downloads\`.
No dependency on any pre-existing user model layout; no admin rights.

## Data flow (install)

```
hardware detect ──► profile match ──► model manifest (schema-gated)
      │                                     │
      ▼                                     ▼
disk preflight ◄── runtime manifest ◄── planner defaults
      │
      ▼
runtime download ─► size gate ─► extract ─► llama-server.exe present?
      │
      ▼
model download ─► size gate ─► SHA256 gate ─► atomic rename
      │
      ▼
config.json ─► llama-server start (localhost) ─► health gate ─► READY
```

## Downloader guarantees

- **Singleton**: `downloads\<artifact>.lock` carries PID + machine + timestamp.
  A second writer is refused while the owner lives. A stale lock is reclaimed
  only when the owning process is provably dead. A foreign lock is never
  removed by us.
- **Resume**: HTTP Range where supported; per-artifact `.part` + `.part.state`
  (url, expected size/sha, bytes, pid). A partial without matching state is
  never resumed. A partial larger than expected is never silently deleted.
- **Integrity gate**: exact size AND SHA-256 (models) → atomic `Move-Item`.
  Runtime assets have no upstream checksum → size gate only, explicitly
  marked `sha_verified=false` in download results and manifests.
- **Retry**: bounded attempts with exponential backoff; a rejected Range
  (416/501/403) restarts from zero over the lock-owned partial.

## Runtime abstraction

`Runtime.psm1` is a registry. A backend module implements:

```
<id>.Test-Installed   <id>.Install-   <id>.Get-CommandArguments
<id>.Start-Server     <id>.Get-HealthUrl   <id>.Get-Version
```

The CLI, profiles, manifests and downloader call only the registry. A v0.2
FreeToken module plugs in without touching anything else.

## Server ownership

`state\server.json` records pid, exe path, model, port, start time, root.
`stop` acts only when PID matches AND the process executable lives inside
this install root. A dead pid → stale state cleared. A live foreign pid →
refused. Port conflicts are resolved by picking another free port — never
by killing the occupier.

## Health gate

1. process alive (ownership-checked)
2. `/health` reachable
3. `/v1/models` contains the configured alias
4. one minimal chat completion returns non-empty content

Failure ⇒ the owned process is stopped and the failure is reported with log
paths. The server is never left half-alive.

## Platform notes

- PowerShell 5.1-compatible (no Python dependency). PS7-safe.
- llama.cpp `b10375` was chosen because Reasoning Budget Arena's frozen
  Formal C runs used it — benchmark evidence maps 1:1 to this runtime.
- CUDA variant selection: modern GPUs (RTX 40/50) → `cuda-13.3`; older →
  `cuda-12.4`. Conservative default when detection is inconclusive.
