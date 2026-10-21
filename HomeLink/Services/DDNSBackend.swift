import Foundation

nonisolated protocol DDNSBackend: Sendable {
    func preview(domain: String, token: String) async throws -> DDNSPreview
    func inspect(_ configuration: DDNSConfiguration, token: String) async throws -> DDNSPreview
    func update(_ configuration: DDNSConfiguration, address: String, token: String) async throws
}

nonisolated struct LiveDDNSBackend: DDNSBackend {
    let dns = CloudflareDNSClient()
    let detector = PublicIPDetector()
    func preview(domain: String, token: String) async throws -> DDNSPreview {
        async let record = dns.validate(domain: domain, token: token)
        async let observation = detector.observe()
        return try await DDNSPreview(record: record, observation: observation)
    }
    func inspect(_ configuration: DDNSConfiguration, token: String) async throws -> DDNSPreview {
        async let record = dns.current(configuration, token: token)
        async let observation = detector.observe()
        return try await DDNSPreview(record: record, observation: observation)
    }
    func update(_ configuration: DDNSConfiguration, address: String, token: String) async throws {
        try await dns.update(configuration, address: address, token: token)
    }
}

