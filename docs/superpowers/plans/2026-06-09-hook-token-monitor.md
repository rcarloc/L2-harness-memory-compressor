# Hook-Based Next-Turn Token Monitor Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use `superpowers:test-driven-development` while implementing. Follow red-green-refactor for every production change.

**Goal:** Add a low-maintenance Codex `Stop` hook that records next-turn token usage automatically after each Codex turn.

**Architecture:** Keep the existing local parser as the source of truth. Add a tiny hook script that reads Codex hook JSON from stdin, parses the `transcript_path`, appends one JSONL observation, updates `current.json`, and always lets Codex continue.

**Tech Stack:** PowerShell 5.1-compatible scripts, Codex hooks, local JSONL files, existing repo tests.

---

## Summary

The polling monitor remains useful for manual checks. The durable path is hook-based collection: Codex `Stop` hooks run after a turn and provide transcript metadata that can be turned into a small local event stream for a future dashboard.

Design sources:

- OpenAI Codex hooks docs: https://developers.openai.com/codex/hooks
- JSON Lines format: https://jsonlines.org/

This plan creates the stable event stream only. Dashboard UI is out of scope.

## Implementation Tasks

- [x] Add a failing hook test that invokes `Invoke-CodexTokenMonitorHook.ps1` with a fake `Stop` payload.
- [x] Implement the hook script so it reads stdin, returns `{ "continue": true }`, and never blocks Codex.
- [x] Append one observation per valid `Stop` event to `runs/token-monitor/hooks/events.jsonl`.
- [x] Update `runs/token-monitor/hooks/current.json` with latest state by session id while preserving other sessions.
- [x] Log malformed JSON, missing transcript paths, and unreadable transcripts to `hook-errors.jsonl`.
- [x] Ignore non-`Stop` events without appending token observations.
- [x] Add the hook test to `tests/Run-All.ps1`.
- [x] Update README hook setup docs.

## Test Plan

Run:

```powershell
cd C:\Users\rcarl\L2-harness-memory-compressor
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\token-monitor-hook.tests.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\Run-All.ps1
```

Expected:

- Hook tests pass.
- Full suite passes.
- Hook stdout remains valid JSON with `continue=true`.
- `events.jsonl`, `current.json`, and `hook-errors.jsonl` are created only under the configured hook output folder.

## Assumptions

- Hook monitoring is the durable default; polling remains a fallback/manual tool.
- Dashboard work comes later and reads `events.jsonl` plus `current.json`.
- The hook does not prove answer quality; it only records token behavior.
- Codex transcript parsing stays centralized in `src/Read-CodexTokenUsage.ps1`.
- No paid observability service, cron job, external database, or provider key is introduced.
