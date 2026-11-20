import LurosAgentWorker

// luros-agent: one agent session (KWWKAgent) per process, or — as the
// `credential-import` instance — the console's credential inbox and the
// provider sign-ins Settings ▸ Model Providers starts.
//
// Runs as mobile, spawned by lurosd's session host with its socketpair as
// descriptor 3; WorkerMain does the assignment and the privilege check.
// Links LurosCore, LurosProtocol, LurosProject and Packages/LurosAgent's
// LurosAgentWorker — see AGENTS.md ▸ Decisions ▸ Process layout. The logic
// lives in LurosAgentWorker so `make harness` tests it on the Mac.

AgentWorker.main()
