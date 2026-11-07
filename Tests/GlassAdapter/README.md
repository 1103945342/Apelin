# LiquidGlassKit adapter checks

Run from the repository root in Apelin's prepared device shell:

```sh
sh Scripts/test-glass-adapter-device.sh
```

The script signs and executes the production `GlassSurfaceStyle` policy against
all 64 combinations of native availability, rounded shape, Reduce Transparency,
Low Power Mode, active visibility and Metal availability. It then typechecks
`GlassSurfaceView` against explicitly test-only API and iOS 26 SDK stand-ins.
The two signatures in the API stand-in match the pinned public effect/view
initializers. They contain no renderer and are never linked into the app.

This test neither builds LiquidGlassKit nor resolves its package, compiles its
Metal shaders, validates Apple's iOS 26 API, opens a window or reads the screen.
It does not validate the composer or Git screens. Build products stay in the
ignored `build/GlassAdapter/` folder. `Tests/Glass/` and
`Scripts/test-glass-device.sh` belong to the previous custom renderer; their
results are not evidence about this integration.

## Full validation

Use the repository's required Xcode/SDK and Swift tools 6.2 or later. Resolve
packages with the fork pinned in the project, letting Xcode refresh the lock
file's resolution metadata; run `make check`, `make harness` and the normal app
build. Do not add the stand-ins or their compilation define to any app target.
Keep the existing Collect Licenses phase; dependency notices need their actual
license text and review before distribution.

Inspect the built LiquidGlassKit resource bundle and load its default Metal
library on a device. Confirm it contains `fullscreenQuad` and
`liquidGlassEffect`: the pinned library force-unwraps these resources, so an
adapter typecheck says nothing about first-use success.

After a successful app build, check these separately:

- iOS 16–25: sidebar search/footer, chat ruler, composer, choices sheet and Git
  tabs/rounded dialogs show a live background without black panels, duplicate
  foreground text or misaligned corners. Flat panels intentionally use a
  system material rather than the legacy shader.
- Scroll a long chat, open/close the keyboard, resize/rotate and switch between
  Git tabs. Verify control taps, selection, text entry and VoiceOver remain
  available above the decorative background.
- Toggle appearance, Reduce Transparency and Low Power Mode; close/reopen a
  surface and background/foreground the app. Verify the material transitions,
  resumed rendering and absence of continuing offscreen Metal work.
- iOS 26: verify the real native effect and the interactive composer. The
  policy chooses native glass even in Low Power Mode; Reduce Transparency
  takes priority and uses the opaque background.

The screen automation tools cannot drive Apelin itself. App page acceptance
therefore requires the user's interaction (and a separately consented screenshot
if a visual capture is needed), not a claim based on these local tests.
