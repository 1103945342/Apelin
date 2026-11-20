/// The XPC side of the wire between the app and lurosd. The operations,
/// their request and response types and the envelope are in
/// `Packages/LurosKit/Sources/LurosProtocol` (`AppOperation`, `Wire`), so
/// the workers and the Mac tests share them; this is what only the two XPC
/// peers need.
enum AppProtocol {
    static let serviceName = "com.fluoxetine.luros.service"
    static let clientEntitlement = "com.fluoxetine.luros.client"
    /// Executables allowed to connect, relative to the install root. The app
    /// is the only public peer: workers reach the session host through the
    /// socketpair it made for them, never through this service.
    static let clientPaths = ["/Applications/Luros.app/Luros"]
}
