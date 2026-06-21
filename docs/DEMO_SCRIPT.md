# OpenHive — 2.5 Min Demo Script

## Setup

- Python engine running: `cd python && python engine.py`
- Nook built in Xcode, AI sidebar open (right side)
- Green dot in OpenHive panel = connected

## Script

| Time | Show | Say |
|------|------|-----|
| 0:00 | OpenHive browser, clean tab | "Browser Use takes 68 seconds and 15k tokens every run. We built something different." |
| 0:15 | Browse Google Flights manually | "Watch — no record button. It just observes." |
| 0:20 | OpenHive panel: step count rising | "Every click becomes training data." |
| 2:20 | Chat: `save this as book cheapest flight` | "One sentence. Workflow compiled locally." |
| 2:25 | New tab, chat: `run book cheapest flight` | "Same task. Different cities. Zero thinking." |
| 2:28 | Metrics strip: 0 tokens, T1 | "Policy executor. No LLM calls." |
| 2:43 | Done on checkout page | "Fifteen seconds. Zero tokens." |
| 2:45 | Cmd+Shift+T tokens panel | "Every number measured live — not estimated." |

## Backup

If live execution fails: show pre-recorded Run 2 video and tokens JSON from `~/Library/Application Support/OpenHive/metrics/`.

## Honesty note

Run 1 token counts are measured from harvest files. Browser Use 68s/15k figures are third-party published benchmarks.
