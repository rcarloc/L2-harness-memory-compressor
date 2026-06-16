# L2 Harness Memory Compressor

External compression tool for long OpenAI Codex session rollouts.

It turns a large Codex JSONL rollout into a validated compressed handoff bundle and a small 3-record rollout:

1. `session_meta`
2. `compacted`
3. `turn_context`

The `compacted.payload.replacement_history` field carries a raw Codex `ResponseItem` message. That is the important resume anchor.

## Why This Matters

Long Codex sessions can keep feeding large prior context into every new turn. That raises per-turn input-token cost even when the user only asks a small follow-up question.

In one controlled local test, this compressor preserved answer quality while cutting per-turn input roughly in half:

| Variant | Rollout | Quality score | Input tokens across 3 prompts | Uncached input tokens | Notes |
|---|---:|---:|---:|---:|---|
| Raw control | 10.56 MB | `15/15` | `398,997` | `384,021` | Existing long Codex session with 8 native compacted events |
| External compressed | 292 KB | `15/15` | `198,102` | `183,126` | Generated handoff context plus compressed rollout |

Compression pipeline time was about `177s`. The output/reasoning cost was effectively the same; the savings came from carrying less old context into each future turn.

Measurement note: use Codex `last_token_usage` for per-prompt cost. Cumulative historical session totals are useful for accounting, but they do not answer how much one new prompt cost.

## Quickstart

```powershell
git clone https://github.com/rcarloc/L2-harness-memory-compressor.git
cd L2-harness-memory-compressor
Copy-Item .env.example .env
notepad .env

powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Compress-CodexSession.ps1 `
  -SourcePath .\examples\sample-rollout.jsonl `
  -OutRoot .\runs `
  -Provider codex `
  -CodexModel gpt-5.3-codex-spark `
  -UseDigest `
  -DryRun
```

Remove `-DryRun` when ready to spend Codex tokens. MiniMax and MiMo keys are not required for the default Codex-native path.

## Official Conservative Workflow

`compress-session` is the supported manual skill/SOP for this package. It creates a run evidence folder and `compressed-rollout.jsonl` from a source Codex rollout without touching live session files.

- `codex` is the default standalone provider.
- `minimax` is an optional accelerator/control when configured.
- `mimo` is an optional fallback when configured.
- Live rollout swaps are manual/advanced and require explicit approval outside the public entrypoint.
- Next-turn token monitoring is planned as a separate tool.

## Inputs

- `-SourcePath`: path to a Codex JSONL rollout.
- `-OutRoot`: output folder for run evidence. Defaults to `.\runs`.
- `-Provider`: `codex` by default. `minimax` and `mimo` are optional external providers.
- `-CodexModel`: Codex model for native summarization. Defaults to `gpt-5.3-codex-spark`.
- `-CodexReasoningEffort`: `low` by default for extraction-style summarization. Some Codex profiles reject `minimal` when tools such as web search are enabled.
- `-RetryFailedChunks`: reruns missing or invalid chunk summaries while skipping valid summaries.
- `-EnvPath`: `.env` file with optional external provider keys.

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

## Done Definition

A compression run is usable only when:

- source rollout SHA is recorded before and after the run;
- `run-manifest.json` exists;
- `context.json` exists;
- `compression_context_quality.json` exists and passes;
- `compressed-rollout.jsonl` validates as exactly `session_meta`, `compacted`, `turn_context`;
- the final report states session id, source size, provider/model, duration, chunk count, validation result, evidence folder, whether live rollout was touched, and next recommended action.

## Token Monitoring

Use `Measure-CodexSessionTokens.ps1` to inspect latest and next-turn token usage from local Codex JSONL rollout files. It is local-file based only: no paid observability service, billing API, proxy, or network dependency is required.

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Measure-CodexSessionTokens.ps1 `
  -SourcePath .\examples\sample-rollout.jsonl
```

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Measure-CodexSessionTokens.ps1 `
  -SessionId <session-id> `
  -SessionRoot $env:USERPROFILE\.codex\sessions
```

Watch for the next unique token event after steering an agent:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Measure-CodexSessionTokens.ps1 `
  -SessionId <session-id> `
  -Watch `
  -Minutes 30 `
  -IntervalSeconds 5 `
  -Live `
  -OutRoot .\runs\token-monitor
```

The monitor reports latest input, cached input, calculated uncached input, output, reasoning output, context-window pressure, rollout size, compacted-record count, recent large tool outputs, and a simple recommendation. Use `-Live` with `-Watch` for a console readout every poll while still saving JSON evidence. Repeated identical `token_count` events are de-duped so rate-limit/status re-emissions do not look like new turns.

Thresholds:

- `strong`: under `35,000` input tokens
- `pass`: `35,000-59,999`
- `warn`: `60,000-100,000`
- `fail`: over `100,000`

## Hook-Based Monitoring

For ongoing work, use `Invoke-CodexTokenMonitorHook.ps1` as a Codex `Stop` hook. This records token usage after each completed turn without running a polling loop.

The hook is intentionally small and non-blocking:

- reads Codex hook JSON from stdin;
- uses `transcript_path` to parse the local rollout;
- appends one observation to `runs/token-monitor/hooks/events.jsonl`;
- updates `runs/token-monitor/hooks/current.json` for dashboard-style reads;
- logs hook failures to `runs/token-monitor/hooks/hook-errors.jsonl`;
- stores a byte offset in `current.json` so later turns read only appended rollout records;
- always returns valid JSON with `continue=true`.

The first hook run for a session uses a full parse to establish baseline state. Later runs use incremental reads when the transcript path and byte offset still match, which keeps the hook much lighter than polling large rollouts.

Windows hook command example:

```json
{
  "Stop": [
    {
      "type": "command",
      "command": "powershell.exe -NoProfile -ExecutionPolicy Bypass -File C:\\Users\\rcarl\\L2-harness-memory-compressor\\Invoke-CodexTokenMonitorHook.ps1"
    }
  ]
}
```

WSL hook command example when PowerShell is installed inside WSL and the repo is available there:

```json
{
  "Stop": [
    {
      "type": "command",
      "command": "pwsh -NoProfile -ExecutionPolicy Bypass -File /home/rcarl/L2-harness-memory-compressor/Invoke-CodexTokenMonitorHook.ps1"
    }
  ]
}
```

Install the hook separately in each Codex environment that runs sessions. A Windows Codex session and a desktop WSL Codex session do not share the same hook process or local transcript path.

References: [OpenAI Codex hooks](https://developers.openai.com/codex/hooks) and [JSON Lines](https://jsonlines.org/).

## Providers

`codex` is the default standalone provider. It uses `codex exec` for chunk summarization, merge, and validation, so users do not need external provider credentials.

`minimax` remains available as an optional accelerator/control where `MINIMAX_API_KEY` is configured.

`mimo` remains available as a fallback path where credentials are configured. Other provider support should be added as explicit provider profiles with tests.

To resume only failed Codex chunks:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Compress-CodexSession.ps1 `
  -SourcePath <rollout.jsonl> `
  -Provider codex `
  -RetryFailedChunks
```

## Tests

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\Run-All.ps1
```

Tests cover provider JSON extraction, Codex dry-run provider flow, dry-run external provider config, chunk/final digest behavior, compressed rollout shape, no-BOM output, and the public entrypoint.

## Benchmark Details

Recent local benchmark, recorded as documentation only:

- Source session: 10.56 MB.
- Raw and compressed both scored `15/15`.
- Raw control input tokens across 3 prompts: `398,997`.
- External compressed input tokens across 3 prompts: `198,102`.
- Raw control uncached input tokens: `384,021`.
- External compressed uncached input tokens: `183,126`.
- Pipeline time: about `177s`.

Source report: `docs/benchmark-019e09f5.md`.
