# Team conversations: push, fan-in, report and guide

Status: **design only** — nothing in this file is implemented. Written
against `main` at `9861e3f` (0.4.5); every file named below is as it is
there. The report half is W1–W6 (sections 1–5); the guidance and constraint
half is W7–W13 (sections 6–7). Each work package can ship on its own; the
order that works is given with them.

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

Four principles:

1. **Push, never poll.** A child's end of turn is an event the host acts on.
   `apelin_conversation_read` stays as a drill-down, not as the way to wait.
2. **Facts by the host, prose by the model.** The relay and the digest carry
   text the children wrote; the summary is the opener's to write. A summary
   the model never writes must not erase the facts from the user's view.
3. **State to the user, events to the agent.** A child's live progress is
   shown in the app and never pushed into the opener's context; only what the
   opener must act on (a finished turn, a question, a waiting approval, a
   drift) is delivered as a message.
4. **Constraint is a wall, not a sentence.** A plan that lives in the prompt
   is advice. What holds is the tool layer refusing a call: the repository
   already does this for plan runs (`ToolRunner.planVerdict`), and a delegated
   plan goes on the same wall (section 7). Guidance and constraint are two
   halves of one thing — the brief: the opener edits it, the wall enforces it.

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

### 6. Live guidance

The opener does not only hand out work and wait: it watches, and it corrects.
What it must not do is what `delivery: steer` does today — put another user
message into the child's stream and hope the child keeps its thread.

**Why today's steer loses the plot.** A steered message arrives as a
`UserMessage` with `ConversationSender.prefix` in front of it — `[Message from
conversation “…” (id), another agent working in this project, not from the
user]` (`Packages/ApelinAgent/Sources/ApelinAgent/Session/
ConversationSender.swift`) — so it is attributed. But it sits in the same
stream as the user's instructions, and nothing in the conversation says what
the task is *now*. After three steers the model has to infer the current
truth from interleaved messages, and a steer that says "use Y instead of X"
is the same kind of event as one that says "stop, do Z". The first should
amend a plan; the second must replace it.

**The brief.** Every delegated conversation carries one record the host
writes, the worker holds, and the child reads — the task brief. It is the
authority; messages are commentary.

```
AgentBrief {
  objective: String                     // one paragraph, the opener's words
  acceptance: [String]                  // what counts as done, checkable
  steps: [BriefStep]                    // the plan, and it is the opener's
  current: String                       // the step the child may work in
  gates: .each | .none                  // section 7.4
}
BriefStep { id, title, write: [String], commands: [String], check: String? }
```

`write` is project-relative folders or files; empty means nothing may be
written, which is the shape of an investigation. `commands` adds to the
read-only presets and never replaces them; a step without it runs nothing
else. `check` is a command (section 7.5).

**Where a brief comes from.** Nothing is parsed out of prose:
`apelin_conversation_create` grows these as optional fields beside `prompt`,
so a delegation that names none behaves as today — relayed, reported,
unconstrained — and one that fills them gets the wall. `prompt` stays the
human sentence the child reads first. `AgentPromptRequest.brief` then carries
the brief on every message, as `promptInjection` does, and `<system-state>`
renders it at about 150 tokens at the start of every turn and again after a
compaction — the one place a summary would otherwise drop it:

```
<brief revision="3">
objective  把构建脚本改成读 apelin-project.json 的 buildScript
acceptance apelin_project_build 成功；Scripts/check-build.sh 退出 0
current    step 2 of 4 — 改 build.sh
write      Scripts/**  Makefile
commands   read-only presets + Scripts/check-build.sh
changed    step 1 done; write adds Makefile
</brief>
```

**Two intensities, two different acts.** `apelin_conversation_amend` carries
one of them:

- `amend` — the constraints move, the plan does not. "Use Y not X", "do step
  2 before 3", "`Packages/` is off limits now". The child reads the new brief
  and carries on in the same run, at its next model request, with its plan
  and its tool state untouched.
- `redirect` — the objective changes. The child is told: make no new tool
  call for the old objective, end the turn with one line on where you stopped,
  and plan the new objective from there. A redirect is a task boundary, so the
  partial work is reported like any turn; it is never dressed up as a detail.

Neither acts inside an executing tool: both land at the model request after
it. That is the honest meaning of "real time" here — seconds to one step,
never mid-command.

**What lets the opener see.** Three surfaces, none of them a poll:

- **The plan is the todo list.** A delegated conversation's `todo_write` is
  the brief's steps and nothing else (section 7.2), and `TodoStore` keeps it
  per session in one file (`Packages/ApelinKit/Sources/ApelinCore/
  TodoStore.swift`). "Which step, which one blocked" needs no new artifact.
- **A team line in every message.** When the opener has children,
  `<system-state>` carries one line per child — state, step, minutes on it,
  whether it waits for an approval — written as a delta: expanded when
  something changed, one line when nothing did.
- **Drift, pushed.** The host reads each child's events and raises one line
  the opener must act on, never the whole log: the same command failing three
  times, a step marked `blocked`, a check that failed, a compaction
  (direction drifts after one), a turn past its budget, a write the wall
  refused. Delivered by the digest's rule — `steer` while the opener runs,
  `queue` when it is idle — at most one per child per `driftInterval`
  (5 min).

**The escape hatch.** `blocked` and "this conflicts with step 3" are
first-class outcomes, never failures. A child that cannot proceed reports and
stops; the opener amends. Without that valve a walled-in child will wander to
look productive, which is worse than the drift the wall was for.

**Guarding the guard.** At most `maximumAmendmentsPerTurn` (3) per child per
turn, each naming the step it changes and why; a child that cannot reconcile
an amendment answers with a conflict instead of silent compliance. An opener
that keeps amending is thrashing, and its team line says so.

### 7. Strong constraint: put the plan on the wall

A plan written in a prompt is advice. The repository already has the pattern
for turning advice into a wall: `ToolRunner.planVerdict`
(`Packages/ApelinAgent/Sources/ApelinAgent/Tools/ToolRunner.swift`), whose
own comment is *"The model is told so in `<system-state>`, and this is the
wall behind the words"* — a plan run refuses every write and every command
before the approval gate, whatever the mode says. A delegated plan goes on the
same wall, in five layers from cheapest to strongest.

**7.1 Plan first.** A delegated conversation opens in `runMode: .plan`.
`planVerdict` then allows reads and `todo_write` only — exactly what writing a
plan needs — and refuses every mutation without asking. The opener reads the
plan, approves or amends it, and its next message flips the child to
`.build`. Two fields are missing today: `AgentOpenRequest` has no `runMode`,
and `AgentConversationRules.childPrompt` builds its request with text,
`fromSessionID` and `delivery` only, dropping `runMode` — while the worker
already applies it (`AgentWorker` calls `session.setRunMode(prompt.runMode)`).
Only `.plan` and `.build` may be set by an agent; `.auto` stays the reader's
own setting.

**7.2 The plan belongs to the opener.** In a delegated conversation
`todo_write` accepts a status change and nothing else: the ids and titles must
be the brief's steps, and adding, removing, renaming or reordering is refused
with *"the plan belongs to the conversation that opened you; report what you
would change"*. Enforced in the same `.todoWrite` branch the plan wall uses,
from the brief the worker holds. A child cannot quietly redefine success.

**7.3 The wall moves with the step.** `current` names one step, and only its
`write` and `commands` are allowed. Every write goes through
`ScopedRoot.resolveForWrite` (`Tools/ProjectFileTools.swift`), one point where
the step's paths are checked; `shell_run` is checked where the host already
authorises it (`AgentApprovals.authorize`) and by the preset match beside
`planVerdict`. **A refusal is never an approval card** — asking the user would
mean the plan never constrained anything. It is a tool error that names the
step and the way out: *"step 2 (`改构建脚本`) does not include `Packages/**`;
amend the brief, or report it"*.

**7.4 The gate is the pointer.** Because the wall follows `current`, moving to
the next step is not something the child can do to itself: with `gates: .each`
the pointer advances only when the opener says so, so a child that finished
step 2 can read, report and stop, but cannot start step 3. With `gates: .none`
it advances when the step's `check` passes, or when the child marks it done
where there is no check. No new run-control machinery is needed: the child
ends its turn as usual, its report is relayed (section 1), and the opener's
next message carries the new `current`.

**7.5 Done is decided by a check, not by the child.** A step may carry
`check`: a command the host runs itself, as the child's identity and only that
command, recording the exit status. A step with a check cannot be marked
completed by `todo_write`; the host marks it, and only on exit 0. The cheapest
useful checks are the ones a project already has — `apelin_project_build`
succeeding, or its own test script exiting 0.

**What the walls cannot do.** They constrain what the child *may* do, never
whether it is doing the right thing: inside its scope it can still solve the
wrong problem. Only the gate, the checks and the opener reading a report catch
that. And a brief that is wrong enforces the wrong work at full strength,
which is why `amend` is part of the design and not a courtesy.

## A turn, after this

1. The user asks. The opener writes three briefs — objective, steps, write
   scope, a check on the last step — and opens three conversations with them.
2. Each child's first turn is a plan (7.1). B's plan would edit
   `Package.swift`, which its brief's `write` does not include; the wall
   refuses, B reports it, and the opener amends the brief instead of letting
   it through.
3. The opener flips the three to `.build` and answers the user: "分了三块：
   A 查协议、B 改构建、C 写测试；我先动 A 依赖的那部分。"
4. A finishes step 1; `gates: .each` stops it there with a report, and the
   relay reaches the opener inside its own turn.
5. B drifts — the same command fails three times — and the drift line reaches
   the opener, which sends an `amend` ("use the workspace's swiftc, not
   xcrun"); B carries on in the same run, plan intact.
6. The opener ends its turn: "A 完成一步在等我放行，B 改道中，C 还在跑，完事
   我汇总。"
7. C ends. All three settled, 2 s quiet, one digest, a new turn: the team
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
- **Keep `steer` and add nothing but the attribution it already has.** That is
  today: the message is marked as another conversation's, and it still
  competes with the conversation's own instructions because nothing states
  what the task is now. Rejected in section 6.
- **Parse the brief out of the opening prompt.** Rejected: prose is ambiguous,
  and the wall would then enforce a guess. The brief is filled in as fields,
  or there is no brief and no wall.
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

The guidance half:

- **W7 — the brief.** `AgentBrief` / `BriefStep` / `AgentMessageOrigin` in
  `ApelinProtocol/Operations/Agent.swift`; `AgentPromptRequest.brief` beside
  `promptInjection`; the optional fields on `apelin_conversation_create`; the
  host's `agentAmend` (lineage-checked, the quota, one step named); the worker
  holds it in `AgentSession` and renders `<brief>` in `<system-state>` at each
  turn's start and after a compaction; the `prompt` payload carries `origin`.
  Tests: `amend` keeps the plan, `redirect` ends the turn with a report, the
  quota refuses the fourth, the brief survives a compaction.
- **W8 — plan first.** `AgentOpenRequest.runMode`; `childOpen` sets `.plan`;
  `childPrompt` keeps `runMode` for `.plan` and `.build` and refuses `.auto`
  from an agent. Tests: a delegated session's first write is refused before
  any approval card; `.auto` is refused.
- **W9 — plan ownership and the scope wall.** The `.todoWrite` branch that
  takes statuses only; `briefVerdict` beside `planVerdict`; the step's paths
  inside `ScopedRoot`; refusals that name the step and never become an
  approval. Tests: a structural change is refused; a step-3 path is refused
  while `current` is 2; a refusal asks the user nothing.
- **W10 — gates and checks.** Pointer advancement for `.each` and `.none`; the
  host running a step's `check` and recording the exit code; `todo_write`
  unable to complete a checked step. Tests: the pointer holds under `.each`;
  a failing check leaves the step open; a passing one completes it.
- **W11 — drift and the team line.** The signals, the rate limit, the
  delivery rule; the `<system-state>` team line as a delta, thrashing
  included. Tests: three failures → one line; a second inside the interval →
  none; the line expands only when something changed.
- **W12 — app.** The child's page shows its brief and its amendments; the team
  strip shows each child's step and whether a gate holds it; drift lines are
  rows; strings in 13 languages.
- **W13 — prompts.** `50-conversations.md`: plan first, the brief is the
  authority, todos are statuses only, a refusal is reported and never routed
  around, `blocked` is a way out. Then `sync-prompts.sh`; `make check` must see
  the regenerated Swift. W4 and W13 edit the same file, so one run of the
  generator covers both.

Order: W1–W3 first — they end the polling on their own. Then W7 → W8 → W9 →
W10, in that order, because the brief is what the wall enforces and the
pointer is what the gate moves. W11 and W12 ride along once W7 exists.

## Limits this design does not remove

- A `steer` lands at a model request, never inside an executing tool. An
  opener in a ten-minute build hears nothing for ten minutes. The rule stays:
  fan out before long local work.
- A wall constrains what a child *may* do, not whether it is doing the right
  thing: inside its scope it can still solve the wrong problem (section 7). A
  brief that is wrong is enforced at full strength.
- A child held at a gate looks idle. It must read as "waiting for the opener"
  on the team line and in the app, or a forgotten gate looks like a hang.
- The brief is roughly 150 tokens per turn per child — the price of the wall,
  paid where the context is least tight.
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
5. Plan-first for every delegation, or only for work that touches several
   files? It costs one round trip per child (section 7.1).
6. `gates: .each` by default, or only for delegations that build, install or
   touch more than one file?
7. Who writes the brief's steps — the opener's model, or a form the delegation
   tool makes it fill in (objective, steps, scope, check) so a delegation
   cannot be vague by accident?
