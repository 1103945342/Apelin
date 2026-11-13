import AlertController
import ApelinCore
import ApelinProtocol
import UIKit

/// Actions for the project behind the current chat. Folder names are stable
/// identities; links are made from their canonical path, never an install prefix.
@MainActor
enum ProjectActions {
    /// Where a folder action opens: the directory to show, and the project
    /// whose root it sits under — nil for a conversation's temporary folder,
    /// which belongs to no project and is not in any project's folder.
    struct FolderTarget {
        let directory: String
        let projectRoot: String?
    }

    /// `chatActions` form the first group;
    /// `distributionBlocker` says why a project with no build description
    /// or script (`ProjectBuildMethod`), which has nothing to package,
    /// cannot be distributed.
    /// `onPrepareDistribution` sends the distribution page's request to the
    /// project's conversation.
    static func menu(
        projectName: String,
        from presenter: UIViewController,
        anchor: UIBarButtonItem,
        distributionBlocker: String? = nil,
        chatActions: [UIKit.UIAction] = [],
        onPrepareDistribution: ((String) -> Void)? = nil,
    ) -> UIMenu {
        let folders = folderActions(from: presenter, failureTitle: "Unable to Open Project") {
            let path = try directory(named: projectName)
            return FolderTarget(directory: path, projectRoot: path)
        }
        let renameAction = UIAction(
            title: String(localized: "Rename…"),
            image: UIImage(systemName: "pencil"),
        ) { [weak presenter] _ in
            guard let presenter else { return }
            rename(projectName, from: presenter)
        }
        let export = UIAction(
            title: String(localized: "Export…"),
            image: UIImage(systemName: "square.and.arrow.up"),
        ) { [weak presenter, weak anchor] _ in
            guard let presenter, let anchor else { return }
            TransferExporter.confirmAndExport(
                kind: .project,
                id: projectName,
                name: projectName,
                from: presenter,
                anchor: anchor,
            )
        }
        let distribute = UIAction(
            title: String(localized: "Distribute…"),
            subtitle: distributionBlocker,
            image: UIImage(systemName: "shippingbox"),
            attributes: distributionBlocker == nil ? [] : .disabled,
        ) { [weak presenter] _ in
            presenter?.presentPageAsFormSheet(
                ProjectDistributionController(projectName: projectName, onPrepare: onPrepareDistribution),
            )
        }
        return UIMenu(children: [
            UIMenu(options: .displayInline, children: chatActions),
            UIMenu(options: .displayInline, children: folders),
            UIMenu(title: String(localized: "Project"), options: .displayInline, children: [renameAction, export, distribute]),
        ])
    }

    /// Open Terminal and Browse Files, for the folder `folder` answers when
    /// one is picked; a folder it cannot answer is `failureTitle`'s notice.
    /// Both pages are Apelin's own — the terminal (`TerminalPresenter`) and
    /// the file browser (`FileBrowserPresenter`) — so neither action needs
    /// another app installed. `UIKit.UIAction` is spelled out in types here:
    /// ApelinProtocol has a `UIAction` of its own, the wire's.
    static func folderActions(
        from presenter: UIViewController,
        failureTitle: String.LocalizationValue,
        folder: @escaping () throws -> FolderTarget,
    ) -> [UIKit.UIAction] {
        let resolve = { [weak presenter] (open: (URL, URL?, UIViewController) -> Void) in
            guard let presenter else { return }
            do {
                let target = try folder()
                open(
                    URL(fileURLWithPath: target.directory, isDirectory: true),
                    target.projectRoot.map { URL(fileURLWithPath: $0, isDirectory: true) },
                    presenter,
                )
            } catch {
                presenter.presentNotice(title: failureTitle, message: error.readableMessage)
            }
        }
        return [
            UIAction(title: String(localized: "Open Terminal"), image: UIImage(systemName: "terminal")) { _ in
                resolve { directory, root, from in
                    TerminalPresenter.open(directory: directory, projectRoot: root, from: from)
                }
            },
            UIAction(title: String(localized: "Browse Files"), image: UIImage(systemName: "folder")) { _ in
                resolve { directory, root, from in
                    FileBrowserPresenter.open(directory: directory, projectRoot: root, from: from)
                }
            },
        ]
    }

    static func rename(_ projectName: String, from presenter: UIViewController) {
        Task { [weak presenter] in
            guard let presenter else { return }
            let current = try? await ProjectSummary.load().first { $0.name == projectName }
            presenter.present(AlertInputViewController(
                title: "Rename Project",
                message: "Choose a display name. The project folder and build settings stay the same.",
                placeholder: "Project Name",
                text: current?.displayTitle ?? projectName,
                doneButtonText: "Rename",
                onConfirm: { [weak presenter] name in
                    Task { [weak presenter] in
                        do {
                            _ = try await ApelinService.app.projectRename(.init(
                                projectID: current?.projectID ?? projectName,
                                displayName: name,
                            ))
                            NotificationCenter.default.post(name: .apelinProjectsChanged, object: nil)
                        } catch {
                            presenter?.presentNotice(title: "Unable to Rename Project", message: error.readableMessage)
                        }
                    }
                },
            ), animated: true)
        }
    }

    static func directory(named name: String) throws -> String {
        guard let folder = DataFolder.app.project(named: name),
              let projects = CanonicalPath.resolve(DataFolder.app.projects.path),
              let path = CanonicalPath.resolve(folder.path),
              path == projects + "/" + name
        else {
            throw ApelinError(.notFound, String(localized: "The project folder is no longer available."))
        }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw ApelinError(.notFound, String(localized: "The project folder is no longer available."))
        }
        return path
    }

    /// A temporary conversation's working folder, `Temporary/<id>/`, made
    /// when it is not there yet: what a General Chat opens in the terminal
    /// and the file browser. Made level by level as `ChatRuntime` makes it,
    /// never through a link, and the one real directory directly inside
    /// `Temporary/` — never the user's home, which General Chat has no
    /// project folder to stand for.
    static func temporaryDirectory(of id: UUID) throws -> String {
        let folder = DataFolder.app.root.appendingPathComponent("Temporary/" + id.uuidString)
        guard (try? DataFolder.app.makeLevels(to: folder)) != nil,
              let root = CanonicalPath.resolve(DataFolder.app.root.path),
              let path = CanonicalPath.resolve(folder.path),
              path == root + "/Temporary/" + id.uuidString
        else {
            throw ApelinError(.notFound, String(localized: "The chat’s folder is not available."))
        }
        return path
    }
}
