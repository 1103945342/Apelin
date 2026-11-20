import GhosttyTerminal
import GhosttyTheme
import UIKit

/// The one ghostty app the terminal pages share, and the surface options each
/// session starts with.
///
/// `TerminalController` is the library's single source of truth for the
/// effective config and owns the ghostty app itself: one per process, shared by
/// every surface. Light and dark both come from the library's default theme
/// (Alabaster and Afterglow), and the platform view switches between them from
/// the trait collection on its own.
@MainActor
final class TerminalAppearance {
    static let shared = TerminalAppearance()

    let controller: TerminalController

    private init() {
        controller = TerminalController(
            configSource: .none,
            theme: Self.theme(named: nil),
            terminalConfiguration: Self.baseConfiguration
        )
    }

    /// A surface, with the terminal's I/O carried by `backend`. The working
    /// directory, command and environment are the host's business — the shell
    /// there is already running — so none of them is set here.
    func surfaceOptions(backend: InMemoryTerminalSession) -> TerminalSurfaceOptions {
        TerminalSurfaceOptions(
            backend: .inMemory(backend),
            fontSize: nil,
            workingDirectory: nil,
            envVars: [:],
            command: nil,
            waitAfterCommand: nil,
            context: .window,
            // A live drag posts sizes faster than a reflowing shell can
            // settle; the surface bounds the stream and lands the last size.
            resizeThrottleMilliseconds: 100
        )
    }

    /// The page ground, so the safe-area strips above and below the grid match
    /// the theme rather than flashing white in the dark.
    var background: UIColor {
        Self.color(controller.backgroundColor)
    }

    static func color(_ color: TerminalColor) -> UIColor {
        UIColor(
            red: CGFloat(color.red) / 255,
            green: CGFloat(color.green) / 255,
            blue: CGFloat(color.blue) / 255,
            alpha: 1
        )
    }

    /// The library's two-variant default, or a GhosttyTheme catalogue entry by
    /// name for both variants when one is asked for.
    private static func theme(named name: String?) -> TerminalTheme {
        guard let name,
              let definition = GhosttyThemeCatalog.theme(named: name)
        else { return .default }
        return definition.toTerminalTheme()
    }

    private static let baseConfiguration = TerminalConfiguration { builder in
        builder.withWindowPaddingX(8)
        builder.withWindowPaddingY(8)
        builder.withCursorStyle(.block)
        builder.withCursorStyleBlink(true)
    }
}
