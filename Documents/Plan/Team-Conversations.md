# Team conversations: push, fan-in and report

Status: **design only** — nothing in this file is implemented. Written
against `main` at `9861e3f` (0.4.5); every file named below is as it is
there. The first thing to build is W1, and each work package can ship on its
own.

## What the owner reported

> 派生会话已经工作完成，反馈给主会话，主会话还要等自己的任务完成后才能收到
> 派生会话的反馈。无法像团队一样能进行实时的沟通和调整。主会话不会将各个
> 派生会话的内容进行总结，汇总和汇报。

Three symptoms, one cause: delegated conversations today are **a mailbox and
a poll**. There is no team — nothing pushes, nothing joins the results, and
nobody is charged with reporting.

## Why it behaves that way (each symptom in today's code)

**Lag.** A message to another conversation is an ordinary
`AgentPromptRequest` with `fromSessionID`; the host rewrites it
(`AgentConversationRules.childPrompt`, `Apelind/Session/Agent/
AgentConversationRules.swift`) and keeps only the text and `delivery`.
`delivery` is the sender's own choice (`AgentToolName.conversationSend`,
`Tools/ToolRunner.swift`):
`queue` waits for the target's active run to succeed and starts a new one
after it, `steer` is taken at the target's next model request
(`AgentSession.prompt`, `Packages/ApelinAgent/Sources/ApelinAgent/Session/
AgentSession.swift`). A report sent with `queue` therefore lands *after* the
opener's whole turn — and `queue` is what the tool description and
`Prompts/50-conversations.md` offer first. The mechanism for the lag-free
path exists; the policy points the other way.

**No teamwork.** The host does not turn "that conversation's turn ended" into
an event. `AgentHostRun` (`Apelind/Session/Agent/AgentHostRun.swift`) tracks
only which sessions a message has reached. The opener's only way to learn
anything is `apelin_conversation_read`: `ChannelHostBackend+
Conversations.swift` reads the target's whole log, then **long-polls
`agentAttach` in a synchronous tool call** until `ConversationReader` settles
or `ConversationReadToolRequest.maximumWaitSeconds` (180 s) runs out. While
that call runs the opener does nothing else — it cannot read, decide or
answer. There is no way for a child to ask its opener a question and get an
answer in the same breath, and siblings cannot see each other at all.

**No summary.** Nothing is charged with it. A child's last answer is just an
answer; the host forwards nothing. There is no one-call view of a team
(`apelin_conversation_list` gives titles and `parentSessionID`, not what each
one concluded), and in the app a delegated chat is merely a row in the
sidebar's "Delegated Chats" group (`Apelin/Interface/Root/
SidebarSessionsController.swift`); the opener's own page shows nothing about
its children. So the user's only account of a team's work is whatever the
opener happened to write.

## What the design is

**The opener fans out, goes idle, and is woken when the team settles.** The
host, not the model, guarantees that each child's result reaches the opener
and that the user can see what every child did. The model still writes every
sentence the user reads; the host only makes sure it has the facts.

Three principles:

1. **Push, never poll.** A child's end of turn is an event the host acts on.
   `apelin_conversation_read` stays as a drill-down, not as the way to wait.
2. **Facts by the host, prose by the model.** The relay and the digest carry
   text the children wrote; the summary is the opener's to write. A summary
   the model never writes must not erase the facts from the user's view.
3. **State to the user, events to the agent.** A child's live progress is
   shown in the app and never pushed into the opener's context; only what the
   opener must act on (a finished turn, a question, a waiting approval) is
   delivered as a message.

### 1. Final-answer relay

A delegated conversation's final answer *is* its report, and the host hands
it to the conversation that opened it. The child does not have to remember
`apelin_conversation_send`; that tool stays for questions and corrections
during the work.

- **Trigger.** The child's task emits `finished` for a turn (or `error`). The
  watcher (W2) reads that turn's last `message` event, bounded to
  `maximumReportBytes` (16 KiB) with a tail marker naming
  `apelin_conversation_read` for the rest.
- **Target.** `AgentSessionLineage.Record.parentSessionID`
  (`Apelind/Session/Agent/AgentApprovals.swift`), one level only: a
  grandchild reports to its own opener, which decides whether the opener's
  opener needs to hear it.
- **Wire.** `AgentPromptRequest` gains `origin: AgentMessageOrigin?` —
  `.report` here — beside the existing `fromSessionID`, which stays the
  child's session. The worker records it on the `prompt` event as `origin`,
  and tells the model in `<system-state>` that this is that conversation's
  report of a finished turn, not a new instruction. The app keeps the
  existing "From <title>" line over the bubble
  (`ChatTranscript.senderLine`); `.report` may later add a chip.
- **No duplicates.** The host remembers `relayedThrough: EventSeq` per child
  so a host restart, a replayed log or a second attach cannot relay the same
  turn twice. It is stored beside the lineage record (a sibling
  `agent-sessions/<id>.team.json`, or a second field in `Record` with a
  version), never in mobile's `session.json`.
- **The opener is not running.** `AgentHandler.deliver` hands a prompt only to
  a running worker (`"This chat is no longer running."` otherwise). A report
  for a conversation whose task has ended is **kept**, not dropped: it is
  delivered with the next digest when that conversation is opened again, and
  the app can show it as an unread report until then.
- **Another project.** The open there was approved; the report back along the
  same lineage is the reverse of that approved step and needs no second
  approval. It is still recorded as `.report` from the child's session.

### 2. Settle watcher and the fan-in barrier

A new actor, `AgentTeam` (`Apelind/Session/Agent/AgentTeam.swift`), owns the
children of every conversation the host opened.

- **Watching.** On a successful `agentOpen` the handler registers the child
  and starts a task that attaches its task with `waitMilliseconds` (30 s per
  call, looping while the task lives). `TaskRegistry.attach` is a
  continuation-based long poll, not a spin: it costs nothing while idle. The
  watcher reacts to `finished`, `error`, `approvalRequested`, and to the task
  becoming terminal.
- **Barrier.** When every child of a conversation is settled and at least one
  is undigested, the team waits `quietMilliseconds` (2 s) for a straggler or
  a new open, then composes **one** digest. Without the barrier each child's
  end starts its own turn in the opener — the "N partial replies" failure.
- **Digest.** For each child, at most `AgentConversations.maximumOpenChildren`
  (6): title, `apelin://conversation/<id>` link, state
  (`idle`/`waitingForApproval`/`ended`), its report bounded to 2 KiB, and its
  error if it ended in one. Then one paragraph of instruction: account for
  every conversation, say what is still missing, and answer the user.
- **Delivery.** Always `delivery: .steer`: taken at the opener's next model
  request if a run is going, queued (and so a new turn) if it is idle. The
  digest is the host's own message: `origin = .team`, `fromSessionID = nil`,
  and `<system-state>` says it is Apelin's summary of the delegated
  conversations — never the user speaking.
- **Epochs.** A digest clears the undigested set; children opened afterwards
  form the next one. `AgentConversations.maximumDepth` (2) still bounds the
  tree, and each level barriers on its own.
- **Host restart.** The team table is in memory; what a restart must not lose
  is the `relayedThrough` marks and the undigested set. Either is rebuilt
  from the lineage files plus each child's log (`finished` after
  `relayedThrough`), so a restarted host relays and digests what it missed
  instead of forgetting it.

### 3. `apelin_conversation_digest`

One call returns what section 2 would otherwise make the opener assemble by
hand:

```
{ conversations: [ { session_id, title, state, last_seq,
                     last_message, error, opened_by_this } ],
  truncated: bool }
```

Served by a new host operation (`agentDigest`) rather than N attaches in the
worker: the host has the registry and the team table, so it reads each
child's tail cheaply and knows the lineage. Bounded to 32 KiB. It is what an
opener calls when it deliberately wants to look, and what the app calls for
the team view below.

### 4. Prompt contract

`Packages/ApelinAgent/Prompts/50-conversations.md` is the source of truth
(`SystemPromptText.swift` is generated by
`Packages/ApelinAgent/Scripts/sync-prompts.sh`; edit the `.md` only). Two
additions:

- To the opener: a delegated conversation's final answer is relayed to you
  when its turn ends, and a digest follows when the whole team settles. Do
  not end a turn pretending the team is done while children are running: say
  which are still working. When the digest arrives, summarize each
  conversation for the user — what it did, what it verified, what is left —
  and say plainly if one failed.
- To the child: your last answer of a turn is sent to the conversation that
  opened you; write it for that reader — done, which files (paths), what you
  verified and what you did not, what is left. Do not also send a copy with
  `apelin_conversation_send`; use that for a question or a correction while
  you work.

### 5. The app

- The opener's page grows a compact **team strip** above the transcript when
  the chat has children: one line each, live state, last line of its
  activity, tap opens it (`RootInterfaceController.open(_:picked:)`). It is
  rebuilt from `conversationOpened` plus the children's task events the
  transcript already follows.
- The digest turn is a normal turn whose first row is a **team report** card:
  the same table, collapsible, built from the digest payload. The model's
  summary follows it as ordinary prose. The card is what guarantees the user
  sees each child's result even when the prose is thin.
- Sidebar: "Delegated Chats" already groups them; it gains the live state it
  is missing today.
- New strings go into all 13 languages of `Localizable.xcstrings` (see the
  note in `AGENTS.md` about editing it in place).

## A turn, after this

1. The user asks. The opener opens three conversations and answers at once:
   "分了三块：A 查协议、B 改构建、C 写测试；我先动 A 依赖的那部分。"
2. A finishes while the opener is still working. The relay is steered in, so
   the opener reads it inside this same turn and adjusts B before B finishes.
3. B asks a question with `conversation_send`; the opener answers with
   `steer`; B carries on without losing its run.
4. The opener ends its turn: "A 完成，B、C 还在跑，完事我汇总。"
5. C ends. All three settled, 2 s quiet, one digest, a new turn: the team
   report card, then a summary naming each one. The user never refreshed
   anything and never saw a spinner waiting for a child.

## Alternatives considered

- **Keep polling, raise `wait_seconds`.** Worse: the opener stalls longer and
  the user still sees nothing.
- **Make the opener's turn block until children finish.** Cannot: the model
  decides when its turn ends; the host cannot extend it.
- **Let the app write the summary.** It cannot write the opener's prose, and
  it should not pretend to. The host shows facts, the model writes the
  summary.
- **A dedicated orchestrator conversation.** Another chat to watch, another
  context to pay for; the bus in phase 2 is the cheaper step in that
  direction.
- **Relay only when the child calls `conversation_send` with
  `delivery: steer`,** plus the prompt contract. Much smaller (no watcher, no
  barrier) and worth doing if W1 fails; it fails exactly where models forget,
  which is the current bug.

## Phase 2 — the team bus (not in this design's first slice)

Relay and digest are hub-and-spoke: a child hears its opener, not its
siblings. When the work needs siblings to trade findings, add one seq-ordered
thread per opener — `apelin_team_post` appends, every member receives the
delta at its next model request as a `<team>` block, with its own budget.
That is a new protocol surface and a new context cost; it should wait until
relay and the barrier are in use.

## Work packages

- **W1 — relay.** `AgentPromptRequest.origin` + `AgentMessageOrigin`
  (`ApelinProtocol/Operations/Agent.swift`), `childPrompt` untouched,
  `AgentHandler` relaying on `finished` with `relayedThrough` persisted beside
  `AgentSessionLineage`, worker `<system-state>` line, `prompt` payload
  carrying `origin`. Tests: relay once per turn, restart, closed opener,
  empty answer, 16 KiB cut.
- **W2 — `AgentTeam`.** Watcher, barrier, quiet window, digest compose and
  delivery (`.steer`), epoch bookkeeping, rebuild after restart. Tests with a
  fixture registry: two children settle 1 s apart → one digest; one still
  running → none; a new child inside the quiet window → next epoch;
  `waitingForApproval` is reported.
- **W3 — `agentDigest`.** Host operation, worker tool
  (`AgentToolName.conversationDigest`, `ToolCatalog`, `ToolRunner`,
  `ChannelHostBackend+Conversations`), 32 KiB bound, refusal when the session
  is not the caller's child.
- **W4 — prompts.** `Packages/ApelinAgent/Prompts/50-conversations.md` then
  `Packages/ApelinAgent/Scripts/sync-prompts.sh`; `make check` must see the
  regenerated Swift.
- **W5 — app.** Team strip, team report card, sidebar live state, strings in
  13 languages.
- **W6 — checks.** `Tests/SessionHost/` for W1–W3, a
  `Tests/ChatTranscript/` check for the report row, and a real-device pass
  through `Scripts/test-session-host.sh` where it applies.

## Limits this design does not remove

- A `steer` lands at a model request, never inside an executing tool. An
  opener in a ten-minute build hears nothing for ten minutes. The rule stays:
  fan out before long local work.
- Six children per project remain (`maximumOpenChildren`), depth 2 remains
  (`maximumDepth`).
- Approvals are still the user's alone. The team can report that a child
  waits; it cannot decide for it.
- A digest is one extra model turn per team. It should be a setting
  (Settings ▸ Agent), on by default, and off means relay only.

## Open questions for the owner

1. Digest on by default, and is a second turn in the opener acceptable?
2. Fixed headings in a child's report, or free prose as today?
3. Should the opener be *told* (in `<system-state>`) how many of its children
   are still running on every message, so it cannot forget the team exists?
4. Phase 2: is sibling-to-sibling traffic needed, or does hub-and-spoke carry
   the work?
