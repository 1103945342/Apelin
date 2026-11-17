# Memory: keep the history on disk, not in two processes

Status: **implementation in progress, not released**. Branch `feature/memory-budget`,
cut from `feature/team-collaboration` at `417ee52`. Owner asked for the audit on
2026-11-17 and to optimise without changing what the app does or shows.

## 1. What was measured on the device (2026-11-17, iPhone15,5, iOS 17.3.1)

Read with `proc_pid_rusage` (`RUSAGE_INFO_V4`), as root for the daemon.

| process | physical footprint | resident | lifetime peak |
|---|---|---|---|
| Apelin (app) | 490–506 MB | 329 MB | 622 MB |
| apelind (session host, pid 70027) | 463.5 MB | 60 MB | 701 MB |
| apelind (launchd proxy, pid 70026) | 2.5 MB | 8 MB | 35 MB |
| apelin-agent (one worker) | 24–28 MB | 6–30 MB | 205 MB |

On disk, the same event stream is kept three times:

| where | size | who loads it |
|---|---|---|
| `Chats/*.json` (170 conversations) | 190 MB | the app, at launch, whole |
| `/var/lib/apelin/tasks/*.events.jsonl` (1748 tasks) | 245 MB | the host, at launch, whole |
| `sessions/*/events.jsonl` (288 sessions) | 1.8 GB | one worker, on open, only its own |

Composition: `agent` tasks are 237.6 MB of the host's 245 MB (266 tasks) and hold
no budget at all; only `.terminal` logs are bounded (`TaskRegistry.terminalHistory`).
The largest single chat record is 18.6 MB / 59,114 events — `toolResult` 9.3 MB,
`thinking` 3.3 MB, `received` 1.9 MB, `toolCall` 2.0 MB.

This is not a leak (no retain cycle, no unbounded timer; the thumbnail `NSCache`
is capped at 128 entries / 32 MB). It is "everything resident" by design, in both
processes:

- `ChatRecord.events` (`Apelin/Interface/Chats/ChatStore.swift:17`) only ever grows
  (`take`), and `ChatRuntime.load` (`ChatRuntime.swift:99`) reads every `Chats/*.json`
  at launch.
- `TaskRegistry.load()` (`Apelind/Session/TaskRegistry.swift:105`) reads and decodes
  every task's whole log at startup and keeps it in `events[id]` for the life of the
  process, finished tasks included.
- Every save re-encodes the whole record (`ChatRuntime.swift:1082`,
  `ChatStore.save`): up to 18 MB per write, throttled to 3 s while a run streams.

## 2. What must not change

These are the release conditions. A change that breaks one is not an optimisation.

1. **The history is whole.** Every message, tool call and result stays visible and
   scrollable; paging up reaches all of it. Dropping events from the file is out of
   scope — only *where they are read from* changes.
2. **Offline.** Opening, scrolling, search and forks never need the network; every
   byte is local.
3. **The sidebar and the page show what they show today**: title, preview, unread,
   "working", the rail, the quiet-run rules, `ChatHistory.turns` paging.
4. **Crash safety.** Append-only writes, atomic replacement, a torn last line
   dropped, a file that does not decode set aside, never replaced by an empty state.
5. **Old files open.** A `Chats/*.json` written before this work is migrated once;
   if the migration cannot be written, that conversation opens the old way, read-only
   in memory, rather than being emptied.
6. **One writer per log**, and every path canonicalised before a decision
   (`AGENTS.md`).

## 3. Direction

Two independent moves, each one keeps only what is being looked at:

**A. The host stops replaying finished tasks at start.** `load()` reads the record of
every task (small) and, for a finished one, only its log's tail: the last decodable
line's `seq`, whether its final `state` line is there, and the floor the record
already carries. A log is decoded in full on demand — the first `attach`/`lastEvent`
that needs it — and a resident cap keeps at most a few logs in memory. That is the
245 MB, of which 237.6 MB is agent tasks.

**B. Agent task logs get a history budget.** They are append-only streams exactly
like a terminal's, and the app keeps its own copy of the same events. They take the
same `HistoryBudget`/floor machinery, with the trim marker the app already reads for
terminals, so a reader that is behind is told what it lost instead of getting a
silently short history.

**C. The app keeps summaries resident and reads a conversation's events on demand.**
`Chats/<id>.json` holds the summary, draft, `sending`, `sessionID` and a prompt index
(a few hundred bytes each, all read at launch — the sidebar, preview and unread come
from it, unchanged). `Chats/<id>.events.jsonl` holds the events, append-only, one
JSON object per line, as a session log does. Opening a conversation reads its last
`ChatHistory.turns` turns by byte offset; paging up reads the previous page; the rail
and `showHistory(from:)` seek through the index. Saves append a batch instead of
re-encoding 18 MB.

**D. Small wins, no behaviour change.** `ChatRuntime.attachmentCache` gets a byte cap
and LRU eviction (an attachment is re-readable from disk); `TraceBody`'s cache key
becomes a content digest instead of a second copy of the whole source text.

## 4. Order and verification

1. A, then its checks. Isolated in `TaskRegistry`; no protocol or app change.
2. D, landable at any time.
3. C, with the migration and its read-only fallback.
4. B last: with C in place the app no longer depends on the task log for its history.

Each step: `Scripts`/`Tests` coverage where the harness exists (`Tests/SessionHost`,
`Tests/ChatTranscript`, the terminal trimming checks), `swiftc -parse` and the Python
checks locally, `make check` and the Xcode build in CI. Numbers are measured again on
the device with the same `proc_pid_rusage` reading, before and after.

Expected result: the app resident falls from 329 MB to the summaries plus one open
conversation's tail (order 40–60 MB); the host's footprint from 464 MB to the
unfinished tasks (order 60–80 MB). Disk use is unchanged.

## 5. Phase A measured (this branch, on the device)

A harness built from `ApelinProtocol` + `ApelinCore` + `TaskRegistry` and run on the
device, loading a copy of the real `/var/lib/apelin/tasks` (258 MB, 1748 tasks),
reading its own footprint with `proc_pid_rusage` after `load()`:

| implementation | finish | time | footprint | resident |
|---|---|---|---|---|
| before (`417ee52`) | 2 unfinished | 51.5 s | 706.8 MB | 449.0 MB |
| after (this branch) | 2 unfinished | 3.8 s | 33.1 MB | 39.4 MB |

`Tests/SessionHost/TaskRegistryStartupChecks.swift` — written 2026-11-09 but never
called by the harness — is wired into `Tests/SessionHost/main.swift` and passes 17/17
on the device. Two of its checks failed before this work and are fixed with it: a log
that cannot be read is no longer taken for a log missing its closing `state`, so
neither its record nor its numbering is rewritten.
