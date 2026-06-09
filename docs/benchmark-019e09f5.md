# Benchmark 019e09f5

This is documentation only. It is not test fixture data.

- Source session: `019e09f5-3db3-7891-a3f1-febb7f42b052`
- Source size: 10.56 MB
- Quality: raw and compressed both scored `15/15`
- Raw per-turn input across 3 prompts: `398,997`
- External compressed per-turn input across 3 prompts: `198,102`
- Raw uncached input: `384,021`
- External uncached input: `183,126`
- Compression pipeline time: about `177s`

Measurement rule: use Codex `last_token_usage` for per-prompt cost. Do not compare cumulative historical totals when answering whether compression saves tokens for a new turn.
