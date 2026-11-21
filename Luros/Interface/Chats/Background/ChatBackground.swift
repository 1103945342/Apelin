import LurosCore
import UIKit

/// What the chat draws behind its messages.
///
/// Three answers: the app's own background as it always was, one of the
/// papers Luros draws itself, or a picture the reader chose. A drawn paper is
/// opaque — there is no photograph in it to want faded — while a picture is
/// drawn see-through by `opacity`, so whatever the app paints behind it shows
/// through the whole of it.
enum ChatBackground: Equatable {
    /// The app's own background.
    case none
    /// One of the papers Luros draws, in full.
    case paper(Paper)
    /// The reader's own picture, at `opacity`.
    case image

    /// The papers the app draws, in the order the sheet lists them.
    enum Paper: String, CaseIterable {
        case rice
        case ivory
        case kraft
        case slate
        case ruled
        case grid
        case dots

        var title: String {
            switch self {
            case .rice: String(localized: "Rice Paper")
            case .ivory: String(localized: "Ivory")
            case .kraft: String(localized: "Kraft")
            case .slate: String(localized: "Slate")
            case .ruled: String(localized: "Ruled")
            case .grid: String(localized: "Grid")
            case .dots: String(localized: "Dots")
            }
        }
    }

    // MARK: - Storing

    /// A settings change: the chat reloads what it draws behind itself.
    static let changed = Notification.Name("com.fluoxetine.luros.chatBackgroundChanged")

    private static let choiceKey = "chat.background"
    private static let opacityKey = "chat.backgroundOpacity"

    static var current: ChatBackground {
        get {
            let stored = UserDefaults.standard.string(forKey: choiceKey) ?? "none"
            if stored == "image", hasImage {
                return .image
            }
            if stored.hasPrefix("paper:"),
               let paper = Paper(rawValue: String(stored.dropFirst("paper:".count))) {
                return .paper(paper)
            }
            return .none
        }
        set {
            UserDefaults.standard.set(stored(for: newValue), forKey: choiceKey)
            NotificationCenter.default.post(name: changed, object: nil)
        }
    }

    /// How much of the picture shows: 1 is the picture as it is, a lower value
    /// lets the app's colours through. A paper ignores it.
    static var opacity: Double {
        get {
            let stored = UserDefaults.standard.object(forKey: opacityKey) as? Double
            return min(max(stored ?? 0.85, 0.1), 1)
        }
        set {
            UserDefaults.standard.set(min(max(newValue, 0.1), 1), forKey: opacityKey)
            NotificationCenter.default.post(name: changed, object: nil)
        }
    }

    /// The paper drawn, when one is: what the bar's frost fades into.
    var paper: Paper? {
        if case let .paper(paper) = self { return paper }
        return nil
    }

    /// What the reader's picture is stored as: `Background/chat.jpg` in the
    /// app's folder, copied out of the picker's temporary file.
    static var imageURL: URL {
        DataFolder.app.chatBackgroundImage
    }

    /// Whether that file is there and is a regular file, so a choice that
    /// points at a picture the app no longer has falls back to the plain one.
    static var hasImage: Bool {
        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(
            atPath: imageURL.path,
            isDirectory: &isDirectory,
        )
        return exists && !isDirectory.boolValue
    }

    /// Takes the picture away, and any choice that pointed at it with it.
    static func removeImage() throws {
        if hasImage {
            try FileManager.default.removeItem(at: imageURL)
        }
        if current == .image {
            UserDefaults.standard.set("none", forKey: choiceKey)
            NotificationCenter.default.post(name: changed, object: nil)
        }
    }

    private static func stored(for background: ChatBackground) -> String {
        switch background {
        case .none: "none"
        case let .paper(paper): "paper:\(paper.rawValue)"
        case .image: "image"
        }
    }
}
