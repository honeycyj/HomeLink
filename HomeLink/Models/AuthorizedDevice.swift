nonisolated struct AuthorizedDevice: Identifiable, Equatable, Sendable {
    let key: SSHPublicKey
    var name: String
    var id: String { key.identity }
}
