# ApelinWeChat

The iLink bot protocol for WeChat ClawBot, as a standalone Swift package:
Foundation and URLSession, nothing else. No Node and no onebots at run time.

- `IlinkConfiguration` — the API base, the client version, the long-poll
  timeout, the backoff and the trust policy.
- `IlinkTrustPolicy` — HTTPS only, the default port, `ilinkai.weixin.qq.com`
  and the hosts under `weixin.qq.com` the server hands back. A token never
  goes to any other address, and a redirect is judged one hop at a time.
- `IlinkTransport` / `URLSessionIlinkTransport` — the injectable HTTP layer.
  `IlinkHTTPRequest`'s descriptions never print a header value or a body.
- `IlinkClient` — an actor: QR login (`beginLogin`, `pollLogin`,
  `cancelLogin`), the `getupdates` long poll (`startUpdates`, `updates`,
  `stop`), `send`, `sendTyping`, `contextToken(for:)`, `restoreSession`,
  `discardSession`.
- `IlinkInboundFilter` — direction, the bot's own echo copies and a bounded
  window of stable message IDs.
- `IlinkSessionStore` / `IlinkFileSessionStore` — one 0600 file, written
  atomically; a file that does not read is reported, never emptied.
- `IlinkBackoff` — 2 s doubling to 60 s.

The cursor in the session file only moves after the events of a batch were
handed to the stream and the file was written. `stop()` moves the lifecycle
generation, so a poll or login call from before it cannot revive.

Checks: `swift test` on a Mac, or on the device
`bash Scripts/test-wechat.sh --device build/Tool.entitlements`. The checks
never touch the network.
