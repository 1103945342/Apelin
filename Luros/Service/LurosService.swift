import LurosCore
import LurosProtocol
import Foundation

/// The app's binding of `LurosService`, the one surface the console, the UI
/// and (from luros-agent, over its channel) the agent's tools call. The
/// methods are in Packages/LurosKit/Sources/LurosProtocol/Operations; this
/// only says how the app reaches lurosd.
extension LurosService {
    /// The account list read against the models this device keeps, so a custom
    /// endpoint's model is named and measured like one of the provider's own.
    /// The list the chat and the model pages are built from.
    func agentAccountsWithKnownModels() async throws -> [AgentAccount] {
        try await agentAccountList(extraModels: EnabledModels.knownModelIDs()).accounts
    }
}

extension LurosService {
    /// Through lurosd over XPC.
    static let app = LurosService(transport: DaemonClient.shared)
}

extension DataFolder {
    /// `~/Documents/com.fluoxetine.luros` as the package made it and the workers
    /// keep it: in mobile's home as the session host reckons it, off the
    /// bundle's own path (`RoothideRoot.mobileHome`). Never in
    /// `NSHomeDirectory()`: on roothide that is the system's `/var/mobile`,
    /// and on rootless uicache gives the app a data container and makes
    /// that its home, where the app kept a folder nothing else read (#37).
    static let app = DataFolder(home: RoothideRoot.mobileHome(for: Bundle.main.bundlePath))

    /// Where 0.3.5 and earlier kept it on rootless, in the app's own home
    /// (`ContainerDataFolder`); nil on roothide, where the app never did.
    static var container: DataFolder? {
        RoothideRoot.containing(Bundle.main.bundlePath) == nil ? DataFolder(home: NSHomeDirectory()) : nil
    }
}
