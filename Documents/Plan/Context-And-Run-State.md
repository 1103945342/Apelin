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

### 1. 模型上下文不能落后于日志，也不能静默变短

- **完整即写**：每当 `state.messages` 变成一个完整边界（`hasCompleteToolResults`），
  并且自上次写盘后确实变了，就写盘。触发点是**每一条 kwwk 事件**，不是某几种事件
  种类；流式增量期间 `messages` 不变，因此不写。
- **不许静默变短**：checkpoint 拒绝写出比磁盘上更短的上下文（压缩与历史编辑走显式
  写盘，不受此限），失败写 `error` 事件而不是悄悄替换。
- **打开时对账**：恢复出来的上下文必须包含日志里记录过的最后一条用户消息。恢复不出
  来时，先用该消息的 fork 快照补，再不行就写一条 `error` 事件说明本轮无法恢复，
  绝不从空上下文开始回答。

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
2. `AgentSession`：完整即写（每条事件触发的变化检测）、不许静默变短、打开时对账。
3. `SessionEventLog`：扫描时记下最后一条用户消息（供恢复用）。
4. App 侧运行状态：`ChatRecord` 的显式状态、`ChatTranscript` 的结束标记、
   `SessionReplay` 的清除、`stop`/前台对账。
5. 测试与真机验证（运行中杀 App → 重开 → 停止可用、上下文完整）。

## 不做的事

- 不改 kwwk revision，不重写事件日志格式，不引入数据库。
- 不把 `transcript.json` 换成新权威格式：`messages.jsonl` 之类的追加式历史留给
  「第二窗口」，本轮先把现有文件写到该有的时机，并把恢复路径补全。
- 不自动重跑工具，不猜副作用结果。
