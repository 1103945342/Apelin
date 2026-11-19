import Foundation

/// Whether an `.ipa`'s app may go where its bundle asks, and what replacing
/// what is already there means.
///
/// The answer is a value so it can be tested without a device: `InstallBridge`
/// reads what holds the destination path — the bundle there, the package
/// database's file lists, the installation records — and this type decides.
///
/// An app of the same bundle identifier is replaced in place: the bundle ID is
/// the app's identity, its container and preferences are keyed by it, and a
/// rebuild that had to be removed first lost both. Cross-project is the same
/// case: the identifier, not the project, is what the device knows.
enum AppPlacement: Equatable, Sendable {
    /// What the destination path holds now.
    enum Existing: Equatable, Sendable {
        /// Nothing at the path.
        case free
        /// A bundle of the incoming app's own identifier.
        case sameBundle
        /// A bundle of another identifier: the folder is another app's.
        case otherBundle(String)
        /// Something is there that no app can be read from.
        case unreadable
        /// A bundle a dpkg package lists in its file list.
        case ownedByPackage(String)
    }

    /// What the install will do.
    enum Plan: Equatable, Sendable {
        /// Nothing at the path: the bundle goes in.
        case install
        /// A bundle of the same identifier is replaced. `adopt` is true when
        /// no installation record of ours held it: something else put that app
        /// there, and Apelin takes it over.
        case replace(adopt: Bool)
        /// The install stops, and this says why.
        case refuse(String)
    }

    /// The plan for a bundle asking for `destinationName`.app, given what is
    /// at that path (`existing`) and whether an installation record of ours
    /// holds the app there (`ours`).
    static func plan(
        destinationName: String,
        bundleID: String,
        existing: Existing,
        ours: Bool
    ) -> Plan {
        // A system bundle is never an .ipa's, whatever the path holds.
        guard !bundleID.hasPrefix("com.apple.") else {
            return .refuse("an .ipa cannot claim \(bundleID), a system bundle ID")
        }
        switch existing {
        case .free:
            return .install
        case .sameBundle:
            return .replace(adopt: !ours)
        case let .otherBundle(other):
            return .refuse(
                "\(destinationName).app holds \(other), another app. Apelin replaces an app of the same bundle identifier only; "
                    + "remove that one first, or give this build its own identifier."
            )
        case .unreadable:
            return .refuse(
                "\(destinationName).app is on the device but holds no app that can be read. Remove it first, then install again."
            )
        case let .ownedByPackage(package):
            return .refuse(
                "\(destinationName).app belongs to the package \(package). Update or remove that package; "
                    + "a build cannot take over a package's files."
            )
        }
    }
}
