# L2 Harness Memory Compressor

External compression tool for long OpenAI Codex session rollouts.

It turns a large Codex JSONL rollout into a validated compressed handoff bundle and a small 3-record rollout:

1. `session_meta`
2. `compacted`
3. `turn_context`

The `compacted.payload.replacement_history` field carries a raw Codex `ResponseItem` message. That is the important resume anchor.

## Quickstart

```powershell
git clone https://github.com/rcarloc/L2-harness-memory-compressor.git
cd L2-harness-memory-compressor
Copy-Item .env.example .env
notepad .env

powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Compress-CodexSession.ps1 `
  -SourcePath .\examples\sample-rollout.jsonl `
  -OutRoot .\runs `
  -Provider minimax `
  -EnvPath .\.env `
  -DryRun
```

Remove `-DryRun` after setting `MINIMAX_API_KEY`.

## Inputs

- `-SourcePath`: path to a Codex JSONL rollout.
- `-OutRoot`: output folder for run evidence. Defaults to `.\runs`.
- `-Provider`: `minimax` by default. `mimo` is available as fallback.
- `-EnvPath`: `.env` file with provider keys.

## Outputs

Each run writes:

- `run-manifest.json`: source SHA, provider, output paths, validation result.
- `session-handoff/session/compressed/context.json`: merged durable context.
- `session-handoff/session/compressed/compression_context_quality.json`: quality gate.
- `compressed-rollout.jsonl`: 3-record Codex-compatible compressed rollout.

## Safety Model

- Raw rollout remains canonical source of truth.
- Default command never mutates live Codex session files.
- Source SHA is recorded and checked again after compression.
- Live A/B rollout swaps are intentionally not part of the default path.
- Native Codex `/compact` is separate and interactive; this tool is external evidence-first compression.

## Providers

MiniMax is the default tested summarizer.

MiMo support remains available as a fallback path where credentials are configured. Other provider support should be added as explicit provider profiles with tests.

## Tests

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\Run-All.ps1
```

Tests cover provider JSON extraction, dry-run provider config, chunk/final digest behavior, compressed rollout shape, no-BOM output, and the public entrypoint.

## Benchmark Note

Recent local benchmark, recorded as documentation only:

- Source session: 10.56 MB.
- Raw and compressed both scored `15/15`.
- Raw control input tokens across 3 prompts: `398,997`.
- External compressed input tokens across 3 prompts: `198,102`.
- Pipeline time: about `177s`.

Use `last_token_usage` for per-prompt cost. Cumulative session totals are not the right measure for one answer.
