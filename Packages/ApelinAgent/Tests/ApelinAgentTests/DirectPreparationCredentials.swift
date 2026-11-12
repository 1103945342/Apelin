import ApelinAgent
import KWWKAI

/// Hold preparation after its durable direct reservation, before credentials
/// fail. Registered faux models need no credentials when the session opens.
actor DirectPreparationCredentials: CredentialSource {
    let barrier: PendingResumeBarrier

    init(barrier: PendingResumeBarrier) { self.barrier = barrier }

    func providerIds() -> [String] { [] }
    func credentials(for providerId: String) async -> OAuthCredentials? {
        await barrier.enter()
        return nil
    }
    func store(_ credentials: OAuthCredentials, for providerID: String) {}
    func remove(_ providerID: String) {}
}
