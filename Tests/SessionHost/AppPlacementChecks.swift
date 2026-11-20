import Foundation

/// What an `.ipa` install does at the path its bundle asks for: install,
/// replace an app of the same identifier, or stop. The decision is a value,
/// so it is checked here without a device or a daemon.
func appPlacementChecks() {
    for existing in [AppPlacement.Existing.free, .sameBundle] {
        check(
            AppPlacement.plan(destinationName: "Mow", bundleID: "local.luros.mow", existing: existing, ours: false)
                != .refuse(""),
            "\(existing) is not a refusal"
        )
    }
    check(
        AppPlacement.plan(destinationName: "Mow", bundleID: "local.luros.mow", existing: .free, ours: false) == .install,
        "an empty path takes the bundle"
    )
    check(
        AppPlacement.plan(destinationName: "Mow", bundleID: "local.luros.mow", existing: .sameBundle, ours: true)
            == .replace(adopt: false),
        "our own record's app is replaced in place"
    )
    check(
        AppPlacement.plan(destinationName: "Mow", bundleID: "local.luros.mow", existing: .sameBundle, ours: false)
            == .replace(adopt: true),
        "an app no record of ours holds is taken over"
    )
    check(
        AppPlacement.plan(destinationName: "Mow", bundleID: "local.luros.mow", existing: .free, ours: true) == .install,
        "a record whose app is gone does not make the path occupied"
    )

    // Another app at the folder: refused, and the message names both.
    if case let .refuse(why) = AppPlacement.plan(
        destinationName: "Mow",
        bundleID: "local.luros.mow",
        existing: .otherBundle("com.example.other"),
        ours: false
    ) {
        check(why.contains("Mow.app") && why.contains("com.example.other"), "another app at the path is named (\(why))")
    } else {
        check(false, "another app at the path is refused")
    }

    // A folder with nothing readable in it.
    if case let .refuse(why) = AppPlacement.plan(
        destinationName: "Mow",
        bundleID: "local.luros.mow",
        existing: .unreadable,
        ours: false
    ) {
        check(why.contains("Mow.app"), "an unreadable folder is named (\(why))")
    } else {
        check(false, "an unreadable folder is refused")
    }

    // A package's app: still refused, and it says which package.
    if case let .refuse(why) = AppPlacement.plan(
        destinationName: "Mow",
        bundleID: "local.luros.mow",
        existing: .ownedByPackage("local.luros.mow.pkg"),
        ours: true
    ) {
        check(why.contains("local.luros.mow.pkg"), "the package that lists the app is named (\(why))")
    } else {
        check(false, "a package's app is never replaced")
    }

    // A system bundle ID is refused whatever holds the path.
    for existing: AppPlacement.Existing in [.free, .sameBundle, .otherBundle("com.apple.Maps"), .unreadable, .ownedByPackage("x")] {
        if case .refuse = AppPlacement.plan(
            destinationName: "Maps",
            bundleID: "com.apple.Maps",
            existing: existing,
            ours: true
        ) {
            check(true, "com.apple.* is refused over \(existing)")
        } else {
            check(false, "com.apple.* is refused over \(existing)")
        }
    }
}
