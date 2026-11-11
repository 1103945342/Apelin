# 上下文与运行状态：诊断与重新设计

修订日期：2026-11-12。代码基线：0.4.1 (137)，分支 `feature/chat-tool-calls-inline`。
适用的既有计划：[Session-Storage-Refactor.md](Session-Storage-Refactor.md) 的「第一窗口」条目
（终态吞掉、消息中断）。本文只处理这两条，并把它们做成两条不变式。

## 现场证据（本机数据，0.4.1 (137)，已含 0d0dd6a）

### 一、模型上下文整段消失

`sessions/801b18da-…`（05:47「帮我看看自动对话压缩实现」）：

| 时刻 | 日志 |
| --- | --- |
| 05:47:13 | 新会话，`transcript read: 0 message(s)`，正常（第一次打开） |
| 05:47:19–25 | 一轮在跑：两条工具调用完成，回复尚未结束 |
| 05:48:03 | 进程被杀；重开同一会话，**`transcript read: 0 message(s)`** |
| 05:48:26 | `Run 1 started … messages=0`：模型在空上下文里回答 |
| 05:49:35 | `Run 2 started … messages=0`：仍然为空 |

用户在 05:49:35 问「我问了什么？你回了什么？」，模型答「这是本会话的第一条消息」。
当时的 `transcript.json` 最后只剩 6 条，且以这句提问开头。

机制：模型上下文只在「整轮结束」（`runEnded`）和少数几个 `messageEnd` 上整份写盘。
kwwk 的工具结果进入 `state.messages` 时**不产生** `messageEnd`，因此工具调用之后的
那个完整边界从未被写；会话第一轮被杀，就等于一个字都没有。0d0dd6a 的按边界写入
依赖事件种类，正好漏在这里。

### 二、压缩把历史整份替换

`sessions/ed767243-…`（「你好」）：

| 时刻 | 日志 |
| --- | --- |
| 05:41:20 | `Run 3 ended … completed`，此前的 run 有 625 条消息 |
| 05:46 | 日志里 `compactionStarted` / `compactionFinished` |
| 05:50:20 | 重开：**`transcript read: 37 message(s)`** |

`compactionEnded` 用压缩后的 37 条整体替换 `transcript.json`，被压掉的历史只留在
`forks/objects/` 里——「读得回来」的地方是 fork，不是恢复路径。读者看到的就是上下文
突然没了。

### 三、运行状态是推出来的，事件流一冻结就永远「执行中」

`Chats/*.json` 里 `C307143C`、`23F38C41`、`23ECF63F`、`2A44493C` 四条的 `replay` 字段
一直挂着。`SessionReplay` 只有在「不属于重放的事件」到达时才清除；任务结束后不再有
任何事件，重放就永远不结束。于是：

- `cursor` 停在重放里，后续事件被当成重放跳掉，界面停在旧状态；
- 而「是否在运行」既由 `ChatTranscript.isWorking`（看有没有终态事件）推，又由
  `summary.isWorking` 推，两者会各说各话，于是轮次头部永远「执行中」，
  按停止只把 `summary.isWorking` 置假，画面不变——「无法停止、假死」。

`stop` 的 `.notFound` 分支已经承认了这件事：「the row must not keep saying it is」，
但它只改 summary，不改画面。

## 两条不变式

### 1. 模型历史是追加式的，不落后于日志，也不静默变短

- **文件**：`sessions/<id>/messages.jsonl`，一行一条记录，只追加、从不改写：
  `{"kind":"snapshot","messages":[…]}` 是整体重写后的会话（压缩、修复、读者编辑各
  开一段），`{"kind":"append","messages":[…]}` 是此后完成的每条消息。会话 = 最后一
  个 snapshot 加上它之后的 append。
- **完整即写**：每收到一条 kwwk 事件就比一次消息数，多了就把新增的那几条追加进去。
  触发点不是某几种事件种类——kwwk 把工具结果放进会话时不发 `messageEnd`，按种类等
  就是会话第一轮被杀时一个字都没写。
- **不许静默变短**：追加只在变长时发生；压缩、修复、编辑各自写 snapshot 开新段，被
  替换的历史留在文件里。内存里的会话比磁盘短，就在下一次提问前从磁盘恢复。
- **打开时对账**：恢复出来的上下文必须包含日志里记录过的最后一条用户消息。恢复不出
  来时先用最近保存的边界补，再不行就写一条 `error` 事件说明本轮无法恢复，绝不从空
  上下文开始回答。
- **兼容**：`transcript.json` 在每轮结束时仍写一份，给不认识 `messages.jsonl` 的旧
  构建读；旧会话第一次打开时用它播种一段 snapshot，之后只走新文件。

### 1.1 分支会话

`agentFork` 不再读「那一轮结束时拍的快照」，而是读 `messages.jsonl` 里**包含该消息
的那一段**，截到该消息为止。压缩把旧前缀换掉了，旧前缀仍在文件里，所以任何一轮都还
能分支；分支写出的新会话也以一个 snapshot 开头。旧会话、或文件里找不到的消息，退回
到原来的 `forks/<message-id>.json` 快照（只读）。

由此不再需要每轮结束时为每条用户消息编码整个会话进对象库：那次写入已删除，manifest
只在旧格式会话需要时读。

### 2. 运行状态由 runtime 持有，不从事件流推断

- `ChatRecord` 记录一轮的显式状态：`running(task:)` / `stopping` / `ended(at:)`。
- 轮次头部与停止按钮读它；`ChatTranscript` 的 `isWorking` 只作为事件流的表现，
  不再决定「能否停止」。
- 任务结束（`batch.finished`）时无条件丢弃残留的 `SessionReplay`：那个任务已经不可能
  再补完重放了。
- `stop` 在宿主报告没有运行时立即把本地轮次结束在当下（`ended(at: now)`）；
  宿主报告有运行时进入 `stopping`，收到终态再结束。
- 回到前台再与 `agentList` 对账一次，不必重启 App 才能把假死状态收敛掉。

## 实施顺序

1. 本文档（证据与不变式）。
2. `SessionEventLog+Conversation`：`messages.jsonl` 的读写、分段、按消息取段（fork）。
3. `AgentSession`：打开时用日志、旧会话播种、每条事件后追加、压缩/修复/编辑开新段、
   提问前从磁盘恢复、轮末写兼容副本。
4. 分支改读日志（`forkedContext`），旧快照只读；每轮结束时的对象库写入删除。
5. App 侧运行状态：`ChatRecord.run`、`ChatTranscript` 的结束标记、`SessionReplay` 的
   清除、`stop`/前台对账。
6. 测试与真机验证（运行中杀 App → 重开 → 停止可用、上下文完整；压缩后仍能分支）。

## 不做的事

- 不改 kwwk revision，不重写事件日志格式（`events.jsonl` 原样），不引入数据库。
- 不删除旧的 `forks/<message-id>.json` 机器：它仍是旧格式会话的分支来源，也是已经
  存在的分支的读路径；只是不再为新的一轮生产。
- 不重建 `messages.jsonl`（它只追加）：要收回空间，只能在确认旧段不再被分支之后另行
  设计，本轮不做。
- 不自动重跑工具，不猜副作用结果。
