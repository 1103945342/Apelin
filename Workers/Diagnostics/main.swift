import LurosDiagnosticsWorker

// luros-diagnostics: logs, crash reports, load confirmation, screenshots,
// the UI tree and UI actions, through icli.
//
// Runs as mobile, spawned by lurosd's session host with its socketpair as
// descriptor 3; WorkerMain does the assignment and the privilege check.
// Links LurosCore, LurosProtocol and Packages/LurosDiagnostics'
// LurosDiagnosticsWorker (icli, crash symbolication, ConfirmLoaded) — see
// AGENTS.md ▸ Decisions ▸ Process layout. The logic lives in the package so
// `make harness` tests it on the Mac.

DiagnosticsWorker.main()
