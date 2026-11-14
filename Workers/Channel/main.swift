import ApelinChannel

// apelin-channel: one channel, as mobile, spawned by apelind's session host
// with its socketpair as descriptor 3. WorkerMain does the assignment and the
// privilege check; the loop lives in ApelinChannel so the harness can test it.

ChannelWorker.main()
