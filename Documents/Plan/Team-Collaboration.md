# Team collaboration: implementation contract

Status: **implementation in progress, not released**. Requirements confirmed by
owner on 2026-11-17. Baseline: `203520a`. This replaces the withdrawn
`Team-Conversations.md`; neither an old checklist nor an unconnected source
file is evidence that a feature works.

## 1. The result the user must see

The opener is accountable for the whole assignment. Children own bounded
pieces of work, not independent promises of success.

1. A child finishes or becomes blocked; the opener receives the facts without
   polling and can keep working meanwhile.
2. The opener reports useful partial results and ultimately gives one complete
   account: every assignment, its artifacts, checks, missing checks, blockers
   and remaining work. A quiet period is NOT evidence that the team is done.
3. The opener corrects a child at the next input boundary. An executing tool
   is not interrupted and a user's approval is never fabricated.
4. A delegated plan is enforced: no out-of-step writes, self-issued permission,
   silent scope expansion or self-certified checked step. Wrong plans can be
   explicitly revised; blocked work is reported, not routed around.

All four are release requirements. Implementing transport alone is a milestone,
not delivery of this feature.

## 2. Non-negotiable rules

- The create tool supplies a structured brief; prompt prose is never parsed
  into authority. Free-form messages can explain a change, not grant it.
- Policy refusal is a tool error naming the step and violated rule. Evaluate
  it BEFORE approval handling. An approval cannot override a scope refusal.
- A gate is an unchanged step pointer. A finished current step authorizes no
  more writes; reads and reports remain available. No new pause/resume mode.
- Approval mode, run mode and screen consent remain the user's decisions.
  An opener can advance an authorized plan, never approve a child's build-mode
  switch or a screen action on the user's behalf.
- No numeric wave budget, debounce or read cursor may silently suppress results.
  Reading a tool response is not proof the model incorporated it.

## 3. Three records, three different meanings

| Record | Authority and lifetime |
| --- | --- |
| Turn report | Host-observed end of one run; immutable source task + closing sequence |
| Assignment | Host ledger of one delegation; survives several turns, retries and reports |
| Brief revision | Host-owned objective, acceptance and current step permissions |

A `finished(completed)` event closes a turn, NOT an assignment. Assignment
acceptance needs the required checks plus the opener's explicit disposition.
The child can request review or report a blocker; it cannot mark its own
assignment accepted.

Logical host storage stays under the existing state directory, relative to
that directory; never persist a resolved bootstrap root. One versioned record
per opener holds assignments and the delivery outbox. One versioned brief
record per child holds the revision, cursor, step states and check receipts.
All writes are atomic, failures retain the previous in-memory state, and an
unreadable record fails closed while preserving the original bytes.

## 4. Reports: capture once, retry the same message

Use the existing ordered host event feed after `TaskRegistry.append`. Capture
locally; never await worker RPC or a model in that feed. The registry currently
has best-effort disk writes, so a returned event is NOT a durable-write receipt.
The outbox must confirm its own persistence before sending anything.

- Track turn start, opener inputs taken, final assistant text, and closing
  outcome. Opening delegation counts as an opener input. Exclude historical
  replay; errors within a retried run are not separate final reports.
- Return delegated work only. A direct user-only turn in the child is not an
  assignment report. Mixed-source turns require explicit attribution; do not
  promise privacy merely because one input was from the opener.
- Register the delegation before the worker can finish, or replay its stored
  tail after registration using the same reducer. Duplicate sources are no-ops.
- Persist source cursor, open-turn reconstruction data and pending report
  together. Worker exit and host recovery close an outstanding delegated turn
  as interrupted; they do not invent success from historical replay.
- Each delivery envelope gets one UUID persisted BEFORE delivery. A retry,
  including after acceptance followed by host crash, uses that same UUID.
  Remove exactly that envelope only after durable receiver acceptance.
- Stop provenance is tied to task/turn and the successful stop request, not a
  timeout heuristic. User-stopped work is not automatically re-delegated.

Reports carry child/session/task identity, title, closing sequence, outcome,
stop provenance, answered opener message IDs, text and truncation. Bound each
body to 4 KiB of valid UTF-8 and each envelope to 16 KiB. Split an oversized
batch without omitting children. Keep undelivered reports; disk pressure is a
visible delivery failure, never a success cursor followed by dropped text.

## 5. Delivery and receiver

The host supplies report metadata and `fromSessionID`. Both app and agent
request entry points strip caller-supplied report metadata. Reverse delivery
is allowed ONLY along the verified creation lineage, including a General Chat
opener. It does not grant access to siblings or other projects.

Deliver promptly using `steer`. Coalesce reports already waiting, without
waiting for all children or introducing a fixed quiet delay. The receiver
acknowledges after durable enqueue, without waiting for a tool or for the
model to take the steer. Duplicate message IDs do not create another run.

| Recipient | Behavior |
| --- | --- |
| Running | Available at the next input boundary; no mid-tool interruption |
| Idle, unpaused worker | Existing source queue can start a run |
| Stopped / failed / recovered-paused | Store without implicit resume |
| Awaiting approval | Store without bypassing approval |
| No worker / closed | Keep outbox until reader-authorized reopening |
| Deleted | Retire delivery in deletion transaction; never recreate |

Retiring is a step of the deletion, not of an idle close: `agentClose` from
Delete (and each conversation a project's Delete closes) cancels the member's
assignment with its reason, drops the turn being read and the reports still
waiting about that child, and marks an opener's own outbox retired, so nothing
is ever delivered to it again. The outbox file stays as the record of what was
owed; no conversation is recreated for it, and a frozen wave already composed
before the deletion keeps what it named.

Queued/taken/replayed events preserve report metadata. A report is cooperating
agent content, not a new reader command, and must not title the opener.
Retry transient delivery with bounded backoff; a closed opener's disk outbox
must not keep the on-demand host running indefinitely.

## 6. Assignment ledger and final account

At delegation, record assignment ID, child, originating opener request,
objective, brief revision and acceptance. States are `working`, `blocked`,
`readyForReview`, `accepted`, `cancelled`, `failed`; runtime running/idle state
is separate. A successful turn alone never changes `readyForReview` to
`accepted`. The opener reviews actual artifacts and check receipts before
acceptance; unverified work stays labelled unverified.

Each report supplies a compact ledger snapshot (including still-running and
blocked members), not just the child that happened to finish. The opener's
contract is to account for the snapshot, distinguish claims from evidence,
and say what is left. No all-children barrier holds useful partial results.

A work group records its expected assignment IDs. New delegations increment its
revision; the opener seals the group when no more tasks are being assigned.
When every member is accepted/cancelled/failed, persist one final-account event
keyed by group ID and revision. Deliver it through the SAME outbox, not a second
reporting channel. Cancellation/failure is reported, never painted as success.
If membership changes during delivery, the older summary is labelled outdated;
the new revision owes a fresh account. No arbitrary two-second timer decides
membership or completion.

The user's raw reports and ledger remain inspectable even if the model's prose
is incomplete. Transport tests cannot certify summary quality; that takes a
real two-child run with a blocked member and a later correction.

## 7. Brief and step contract

`conversation_create` receives a structured `brief` with objective, acceptance,
ordered steps and `gates: each | end`. Each step has stable ID, title, exact
project-relative write roots, typed capabilities and an optional check ID.
Use exact paths plus subtree roots rather than ambiguous arbitrary globs.

Host state: `revision`, `currentStepID`, step states, evidence receipts. Updates
require `expectedRevision`; stale changes are rejected. Only the verified
opener can revise or advance; an app action remains subject to user intent.
A child's status report cannot edit titles, reorder steps or widen permissions.

- `working` allows only the current step's declared operations.
- `blocked` allows reads and reports, not continued mutation.
- A passing check yields `awaitingReview` for `gates: each`; the pointer stays.
- For `gates: end`, a passing check advances to the next step automatically;
  final assignment acceptance still belongs to the opener.
- Without a check, the child may request review, never self-verify. The opener
  can accept explicitly as unverified; this remains visible in the ledger.
- A failing check keeps the step open for correction. A receipt from an older
  revision cannot advance a newer plan.
- A revision during an in-flight operation takes effect before the next tool
  starts. The existing operation finishes under its admitted revision and its
  evidence retains that revision; do not pretend an amendment undoes writes.

The current brief is rendered at each model input boundary and after compaction
without rebuilding the cached system prompt. `steer` is used for questions and
corrections; permissions change only through the host's revision transaction.

## 8. Enforcement coverage, not a command-name allowlist

A list of argv[0] values is NOT containment: `python`, `sh`, an editable test
script, a compiler plugin or a build hook can write anywhere their process can.
Neither a source path prefix check nor a successful check proves confinement.

Implementation must inventory every mutation tool and fail closed on unclassified
ones. File edits use canonical roots and resolved parent/target descriptors,
reject symlink escapes and revalidate at commit. File creation, replacement,
delete, move, repository operations, configuration, package actions, subdelegation
and extension tools all require a typed permission for the current revision.
A child cannot escape by creating an unrestricted grandchild.

For constrained children, arbitrary shell text, interpreter execution, root
commands and opaque tool extensions are refused until a process-level write
boundary exists. Structured argv is not exempt. Build/test execution is enabled
only through a reviewed execution adapter with explicit effects and isolation;
otherwise return a step-scoped unsupported-operation error. Do not advertise a
full write sandbox while allowing a command to bypass it.

Checks run through host-selected adapters as mobile, with output/time bounds,
normal approval rules and a recorded revision. Never execute an arbitrary check
string as root or mistake a project's editable script for host policy. An
unsupported check blocks visibly; the opener must revise the task, not silently
mark it passed. This deliberately trades early command coverage for an honest
constraint boundary.

## 9. Implementation slices and evidence

| Slice | Deliverable | Exit test |
| --- | --- | --- |
| 1 | Report protocol, durable outbox, host feed and worker intake | duplicate/restart/Stop/forgery/early-finish/failed-write tests |
| 2 | Structured brief model and transition rules | revision, path-root, stale receipt, gate and no-check tests |
| 3 | Create/revise/check operations and complete tool admission | every mutation has a tested allow/deny decision; no shell bypass |
| 4 | Assignment ledger, group revision and final account | blocked member, new member during summary, cancellation and final dedupe |
| 5 | Read-only team strip and end-to-end validation | real children, correction, approval, reconnect and final account |

Slices 1 and 2 can be implemented in parallel; they do not claim slices 3–5.
New files alone are not integration. Record exactly which call sites use them
and which tests have actually run. No feature is complete before its exit test.

The team strip derives direct-child membership from the host, subscribes only
while visible and opens links through `RootInterfaceController.open(_:picked:)`.
All new UI strings need all 13 languages and accessibility semantics.

On this device there is no `make`/`xcodebuild`: run signed isolated model tests
and available Python checks; full `make check`, Xcode integration, live model
behavior and UI remain owed to CI/a compatible build environment. Never replace
these missing checks with an unchecked "implemented" label.
