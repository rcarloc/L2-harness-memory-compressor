---
description: Manually compress a Codex session into validated handoff context
argument-hint: [session-id|current] [--ab-test]
allowed-tools: [Read, Glob, Grep, Bash, Write, Edit]
---

# Compress Session

The user invoked this command with: `$ARGUMENTS`

## Status

This file is a slash-command spec/staging artifact. It is not currently installed as a built-in Codex CLI command and the examples below are for future slash-command wiring.

Known distinction:

- Built-in Codex CLI interactive command: `/compact`
- This manual external workflow: `compress-session`

Use this file to wire a future slash command, or invoke the official natural-language skill directly by asking Codex to "use compress-session."

## Instructions

1. Run the public entrypoint from the repository root:
   `.\Compress-CodexSession.ps1 -SourcePath <rollout.jsonl> -OutRoot .\runs -Provider codex -CodexModel gpt-5.3-codex-spark -UseDigest`

2. Keep the default conservative behavior.

3. Default behavior is conservative:
   - create evidence;
   - run compression on a copied transcript;
   - validate `context.json`;
   - build compressed rollout evidence;
   - do not live-swap unless the user supplied `--ab-test` or explicitly confirms.

   Provider policy:
   - `codex` = default standalone provider.
   - `minimax` = optional accelerator/control when credentials are configured.
   - `mimo` = optional fallback when credentials are configured.

4. If the argument is `current`, identify the current session id and live rollout path before proceeding.

5. If the session is under ~1 MB, recommend skipping compression unless the user confirms.

6. Final response must include:
   - session id;
   - size;
   - compression duration;
   - chunk count;
   - validation pass/fail;
   - evidence folder;
   - whether live rollout was touched;
   - restore SHA status if live rollout was touched.

## Examples

```text
/compress-session current
/compress-session 019e09f5-3db3-7891-a3f1-febb7f42b052
/compress-session 019e09f5-3db3-7891-a3f1-febb7f42b052 --ab-test
```
