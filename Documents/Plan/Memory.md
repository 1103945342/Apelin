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

## 6. Phase D: the small one, done

`ChatRuntime`'s attachment cache was a dictionary that only ever grew, holding up to
32 MB per attachment for the life of the app. It is now a 48 MB LRU, oldest let go
first; an attachment is re-readable from its file, so nothing the reader sees changes.

`TraceBody`'s key was left alone: its cache holds the blocks' own text anyway, so
keying by a digest would save one copy of at most a few megabytes — not worth
touching a page that draws every trace step.

## 7. What this branch does not do yet, and why

**C (the app's 190 MB) needs the storage split, and the split needs a compiler.**
A fact found while writing it: the app deletes a conversation it judges untouched,
and "untouched" is `record.events.isEmpty` (`ChatRuntime.swift:243`). A record whose
events are only *not read yet* looks exactly like one with no history at all, so
reading them lazily without splitting the file would delete conversations. The safe
shape is the one in §3: a head that carries how many events the chat has, and an
append-only `Chats/<id>.events.jsonl` beside it, migrated once. That changes the
on-disk format and touches the transcript, the rail, forks and edits, so it has to be
done where the app can be built and the UI exercised — there is no `xcodebuild` on
this device.

**B (agent task budgets) no longer buys memory.** A stopped the host from reading
finished logs at all, so a budget would now bound disk, not memory: 237 MB of agent
task logs that duplicate `sessions/`. Worth doing for disk, later, together with the
app's reading of the trim marker.

## 8. C, first half: the split (done, verified on the device)

`Chats/<id>.json` is now a head — summary, draft, pending sends, and `eventCount` —
and `Chats/<id>.events.jsonl` holds the events, appended. A record written before
this is moved out once, at launch: the events file first, then the record, so a
launch cut off between the two finds the old record whole and migrates again. A save
appends what the conversation gained and writes the head; a history that went
backwards — a compaction, a rewind, an edit — is written out whole. A record found
without its events stays where it is rather than opening with no history.

`Scripts/test-chat-store.sh --device` compiles the store with the packages it reads
and runs 16 checks on the device: the migration, an appended save, a rewritten
shorter history, an empty chat writing no events file, a broken line setting the
record aside with its events kept, and a delete removing both files. All 16 pass.

What has **not** changed yet: `ChatRuntime.load` still reads every conversation's
events at launch, so the app's 190 MB is where it was. The second half reads one
conversation's events when it is opened or followed, takes its count from the head —
which is what `isUntouched` needs, so a chat whose events are merely unread is never
mistaken for an empty one — and lets them go when nothing follows it. That is in the
app target, which has no build here.

## 9. C, second half: the runtime reads a conversation when it needs one

`ChatRuntime.load` now asks the store for heads (`load(readingEvents: false)`),
keeps `eventCounts` from each head and marks the conversation `unloadedEvents`; no
event is decoded at launch. `loadEvents(id)` reads that conversation's events the
first time something needs them — the transcript, the rail, the history fold, the
composer's dropped-message return, following a run — and drops it from the unloaded
set. Three rules make that safe:

- `isUntouched` counts with `eventCounts` (the head's number), never with an empty
  event list, so a chat that merely has not been read is not taken for an empty one
  and deleted.
- A save of an unread conversation writes its head alone, with the count it was
  given (`writesEvents: false, eventCount:`): writing the empty list it holds would
  write the history away.
- Following a run loads first (it appends what it takes), and the count follows every
  append and every write.

`Tests/ChatStore/Check.swift` grew six checks for this: a head-only launch reads no
events and knows how many there are, a head-only save leaves the events file
byte-for-byte as it was and keeps its count, and the history is still there after.
`Scripts/test-chat-store.sh --device` passes 22/22 on the device.

Still outside this branch: nothing reads a conversation's events back out of memory
when the reader leaves it, so each chat opened in a session stays read. That is the
next economy, and it needs the page to say which chat it is showing.

## 10. Why the launch still cost 350 MB: restoring lineage read every history

Measured on the device on 2026-11-19 with the head-only launch already in place:
Apelin was 428.9 MB footprint / 241.4 MB resident running, and 420.2 / 349.2 MB six
seconds after a cold start. The heads are a few hundred bytes each, so the events
were coming back some other way. They were: `ChatRuntime.load` ends with
`restoreLineage()`, which passed no sessions, and with no sessions the host's list
cannot narrow the search for a conversation that opened another — so it called
`loadEvents` for **every** chat and scanned their events for `conversationOpened`.
That ran on every launch, before `isLoaded`.

A bare process reading the same folder (`ChatEventsFile.read` over the 166 files,
194 MB, 596 435 events) holds **244.7 MB** footprint: that is the 350 MB, and the
events were never the problem the split did not fix.

What changed:

- `ChatEventsFile.scan(_:for:in:)` reads one file line by line and decodes only the
  lines that mention the kind asked for, so restoring lineage costs a pass over the
  bytes instead of an event in memory each. On this folder it finds 54 opened events
  in 18 chats in **2.3 s** (`-O`; 17.2 s with `-Onone`, which is why the numbers
  here are only worth comparing to each other).
- `ChatRuntime.scanLineage()` runs that pass in `Task.detached(priority: .utility)`
  over the chats whose history is not in memory and keeps the few events it finds
  (`lineageOpened`). It is started **after** `isLoaded`, so the list comes up from
  the heads and an edge restored from a file appears a moment later.
- `restoreLineage` no longer calls `loadEvents`; it hands `ChatAdoption.restoreLineage`
  the scanned events for chats that are still unloaded. A chat whose history is in
  memory keeps supplying its own events, as before.

Saves got cheaper with it: an edge restored at launch used to leave that chat loaded,
so its next save wrote the whole history back; now it stays unloaded and the save is
the head alone.

The edge itself still persists in the head (`parentChatID`), so a chat that was ever
restored keeps its parent without any scan; the scan only finds edges a record lost.

Verified on the device: `Scripts/test-chat-store.sh --device` **25/25** (the scan
finds only the opened events, keeps them whole, drops a line a write cut short), and
a one-off harness of the real `ChatAdoption.restoreLineage` + `ChatEventsFile.scan`
**8/8** (an edge restores from the scan alone, none from an empty scan). The app
target is not built here, so the drop in Apelin's own footprint is still to be
measured on a CI build.
