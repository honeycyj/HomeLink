import CryptoKit
import Darwin
import Foundation

@main struct StudioFeaturesTests {
    static func expect(_ value: Bool, _ message: String) throws {
        if !value { throw HomeLinkError.message("TEST FAILED: " + message) }
    }
    static func key(_ comment: String) throws -> SSHPublicKey {
        let raw = Curve25519.Signing.PrivateKey().publicKey.rawRepresentation
        let wire = Data([0, 0, 0, 11]) + Data("ssh-ed25519".utf8) + Data([0, 0, 0, 32]) + raw
        return try SSHPublicKey(pasted: "ssh-ed25519 \(wire.base64EncodedString()) \(comment)")
    }
    static func failure(_ operation: () throws -> Void) throws {
        do { try operation() } catch { return }
        throw HomeLinkError.message("TEST FAILED: expected rejection")
    }
    static func main() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("HomeLinkStudioTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try authorizedKeys(root)
        try storageCompatibility(root)
        try await localConsent(root)
        try await sharingRefreshLifecycle()
        try await sharingGreetingLatency()
        try plans()
        try addresses()
        try sharingStatuses()
        try await publicIP()
        try await cloudflare()
        try await controller(root)
        print("Studio features: authorization preservation, schedules, address guards, HTTP API, cancellation and storage passed.")
    }

    static func authorizedKeys(_ root: URL) throws {
        let directory = root.appendingPathComponent(".ssh")
        let a = try key("original"), b = try key("new")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        let file = directory.appendingPathComponent("authorized_keys")
        let original = "# Keep this comment\nrestrict,command=\"echo hello world\" \(a.identity) old comment\nunknown-line-preserved\n"
        try Data(original.utf8).write(to: file)
        let duplicate = try SSHPublicKey(pasted: a.identity + " different-comment")
        try expect(try !AuthorizedKeysFile.add(duplicate, directory: directory), "same blob with a different comment/options is not appended")
        try expect(try String(contentsOf: file, encoding: .utf8) == original, "idempotence preserves original bytes and restrictions")
        try expect(try AuthorizedKeysFile.add(b, directory: directory), "new key appended")
        try expect(try String(contentsOf: file, encoding: .utf8).hasPrefix(original), "existing content preserved")
        try expect(try String(contentsOf: directory.appendingPathComponent("authorized_keys.homelink.backup"), encoding: .utf8) == original, "backup precedes write")
        try expect(try AuthorizedKeysFile.read(directory: directory).count == 2, "keys detected with options")
        let permissions = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as! NSNumber
        try expect(permissions.intValue == 0o600, "authorized_keys owner-only")
        try AuthorizedKeysFile.remove(identity: b.identity, directory: directory)
        try expect(try String(contentsOf: file, encoding: .utf8) == original, "revocation preserves every unrelated byte")
        try failure { _ = try SSHPublicKey(pasted: a.text + "\n" + b.text) }
        try failure { _ = try SSHPublicKey(pasted: "-----BEGIN OPENSSH PRIVATE KEY-----") }
        try failure { _ = try SSHPublicKey(pasted: "ssh-ed25519 AAAA invalid") }
        try FileManager.default.removeItem(at: file)
        let protected = root.appendingPathComponent("unrelated")
        try Data("do not change".utf8).write(to: protected)
        try FileManager.default.createSymbolicLink(at: file, withDestinationURL: protected)
        try failure { _ = try AuthorizedKeysFile.add(b, directory: directory) }
        try expect(try String(contentsOf: protected, encoding: .utf8) == "do not change", "no following symlinks")
        let fresh = root.appendingPathComponent("fresh-ssh")
        try expect(try AuthorizedKeysFile.add(b, directory: fresh), "first run creates missing directory and file")
    }

    static func storageCompatibility(_ root: URL) throws {
        let home = root.appendingPathComponent("fake-home")
        let normal = home.appendingPathComponent("Library/Application Support/HomeLink")
        try expect(HomeLinkStorage.directory(home: home).path == normal.path, "new installations use regular application support")
        let legacy = home.appendingPathComponent("Library/Containers/local.homelink.HomeLink/Data/Library/Application Support/HomeLink")
        try FileManager.default.createDirectory(at: legacy, withIntermediateDirectories: true)
        let original = Data("preserve original device file".utf8)
        try original.write(to: legacy.appendingPathComponent("devices.json"))
        try expect(HomeLinkStorage.directory(home: home).path == legacy.path, "upgrades retain legacy data in place")
        try expect(try Data(contentsOf: legacy.appendingPathComponent("devices.json")) == original, "data untouched by location resolution")
        let preferences = home.appendingPathComponent("Library/Containers/local.homelink.HomeLink/Data/Library/Preferences")
        try FileManager.default.createDirectory(at: preferences, withIntermediateDirectories: true)
        let values: [String: Any] = ["localAccess.names": ["public-key": "Studio"], "unusedLegacyValue": true]
        try PropertyListSerialization.data(fromPropertyList: values, format: .binary, options: 0).write(to: preferences.appendingPathComponent("local.homelink.HomeLink.plist"))
        let suite = "HomeLinkStorageTests-\(UUID().uuidString)", defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(false, forKey: "customPreference")
        HomeLinkStorage.importLegacyPreferences(home: home, defaults: defaults)
        try expect(!defaults.bool(forKey: "customPreference") && defaults.object(forKey: "unusedLegacyValue") == nil, "migration imports only supported preferences")
        try expect(defaults.dictionary(forKey: "localAccess.names") as? [String: String] == ["public-key": "Studio"], "device display names preserved")
        try expect(!defaults.bool(forKey: "localAccess.keyManagementConsent.v1"), "preference migration cannot imply consent")
    }

    static func localConsent(_ root: URL) async throws {
        let folder = root.appendingPathComponent("consent-ssh")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        let key = try key("existing"), file = folder.appendingPathComponent("authorized_keys")
        let original = Data((key.text + "\n").utf8)
        try original.write(to: file)
        let suite = "HomeLinkConsentTests-\(UUID().uuidString)", defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let denied = LocalAccessStore(defaults: defaults, directory: folder, confirmation: { false })
        await denied.refresh()
        try expect(denied.needsAuthorization && denied.devices.isEmpty, "keys not loaded before consent")
        try expect(try await !denied.authorize(), "cancel does not grant consent")
        try expect(try Data(contentsOf: file) == original, "cancel preserves authorization file")
        let allowed = LocalAccessStore(defaults: defaults, directory: folder, confirmation: { true })
        try expect(try await allowed.authorize(), "explicit approval accepted")
        try expect(!allowed.needsAuthorization && allowed.devices.count == 1, "approval loads existing keys")
        try expect(try Data(contentsOf: file) == original, "approval reads without rewriting keys")
        let reopened = LocalAccessStore(defaults: defaults, directory: folder, confirmation: { false })
        await reopened.refresh()
        try expect(!reopened.needsAuthorization && reopened.devices.count == 1, "consent persists without repeated confirmation")
    }

    static func sharingRefreshLifecycle() async throws {
        let suite = "HomeLinkSharingRefreshTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let probe = SharingRefreshProbe()
        let store = LocalAccessStore(defaults: defaults, confirmation: { false }, detectSharing: { await probe.detect() })
        let first = Task { await store.refreshSystemStatus() }
        while await probe.calls == 0 { await Task.yield() }
        await store.refreshSystemStatus(force: true)
        try expect(await probe.calls == 1, "overlapping system checks are deduplicated")
        await first.value
        await store.refreshSystemStatus()
        try expect(await probe.calls == 1, "immediate page reopen uses short cache")
        await store.refreshSystemStatus(force: true)
        try expect(await probe.calls == 2, "manual refresh bypasses cache")
        try expect(!store.checkingSystem, "finished checks clear busy state")

        let cancelledProbe = SharingRefreshProbe()
        let cancelledStore = LocalAccessStore(defaults: defaults, confirmation: { false }, detectSharing: { await cancelledProbe.detect() })
        let cancelled = Task { await cancelledStore.refreshSystemStatus() }
        while await cancelledProbe.calls == 0 { await Task.yield() }
        cancelled.cancel()
        await cancelled.value
        try expect(!cancelledStore.checkingSystem && cancelledStore.sharing.ssh.availability == .checking,
                   "cancelled page task cannot publish stale results")
        await cancelledStore.refreshSystemStatus()
        try expect(await cancelledProbe.calls == 2, "cancelled detection does not populate cache")
        print("Local sharing: in-flight deduplication, short cache, explicit refresh and cancellation passed.")
    }

    static func sharingGreetingLatency() async throws {
        for (banner, prefix) in [("SSH-2.0-TestServer\r\n", "SSH-"), ("RFB 003.008\n", "RFB ")] {
            let server = try GreetingTestServer(banner: banner)
            let start = ContinuousClock.now
            try expect(await LocalSharingDetector.greeting(port: server.port, prefix: prefix), "valid greeting detected without waiting for server EOF")
            try expect(start.duration(to: .now) < .seconds(1), "ready local service does not wait for old 4-second timeout")
            try expect(await server.completion.value, "probe closes idle server connection immediately")
        }
        let invalid = try GreetingTestServer(banner: "HTTP/1.1 200 OK\r\n")
        try expect(await !LocalSharingDetector.greeting(port: invalid.port, prefix: "SSH-"), "unrelated listener rejected")
        _ = await invalid.completion.value
        let silent = try GreetingTestServer(banner: "")
        try expect(await !LocalSharingDetector.greeting(port: silent.port, prefix: "SSH-", timeout: 0.08), "silent service respects short deadline")
        try expect(await silent.completion.value, "timeout closes socket")
        let cancelled = try GreetingTestServer(banner: "")
        let task = Task { await LocalSharingDetector.greeting(port: cancelled.port, prefix: "RFB ") }
        try await Task.sleep(for: .milliseconds(30))
        let start = ContinuousClock.now
        task.cancel()
        try expect(await !task.value, "cancelled greeting cannot succeed")
        try expect(start.duration(to: .now) < .milliseconds(300), "cancelled socket exits promptly")
        try expect(await cancelled.completion.value, "cancellation closes socket")
        print("Local sharing sockets: SSH/RFB immediate completion, invalid response, short timeout and cancellation passed.")
    }

    static func plans() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        func date(_ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
            calendar.date(from: DateComponents(year: 2026, month: 10, day: day, hour: hour, minute: minute))!
        }
        var p = DDNSPlan()
        p.intervalMinutes = 15
        try expect(p.next(after: date(21, 10), calendar: calendar) == date(21, 10, 15), "custom interval")
        p.mode = .scheduled; p.times = [CheckTime(hour: 8, minute: 0), CheckTime(hour: 20, minute: 0)]
        try expect(p.next(after: date(21, 10), calendar: calendar) == date(21, 20), "daily multiple times")
        try expect(p.next(after: date(21, 20), calendar: calendar) == date(22, 8), "no replay at exact execution time")
        p.repetition = .weekdays
        try expect(p.next(after: date(23, 21), calendar: calendar) == date(26, 8), "weekend skipped")
        p.repetition = .weekly; p.weekdays = [2, 4, 6]; p.times = [CheckTime(hour: 9, minute: 0)]
        try expect(p.next(after: date(21, 10), calendar: calendar) == date(23, 9), "custom weekdays")
        p.weekdays = []; try failure { try p.validate() }
        p.weekdays = [2]; p.times.append(p.times[0]); try failure { try p.validate() }
        p = DDNSPlan(); p.intervalMinutes = 0; try failure { try p.validate() }
        p.mode = .scheduled; p.times = [CheckTime(hour: 2, minute: 30)]
        calendar.timeZone = TimeZone(identifier: "America/New_York")!
        let spring = calendar.date(from: DateComponents(year: 2026, month: 3, day: 8, hour: 0))!
        let next = p.next(after: spring, calendar: calendar)!
        try expect(calendar.component(.day, from: next) == 8 && calendar.component(.hour, from: next) == 3, "spring DST skipped time moved forward")
    }

    static func addresses() throws {
        try expect(try PublicIPv4.normalize("8.8.4.4\n") == "8.8.4.4", "public IP accepted")
        for ip in ["198.18.0.89", "198.19.1.1", "192.168.1.1", "100.64.0.1", "127.0.0.1", "10.1.1.1", "169.254.2.1", "203.0.113.42", "224.0.0.1", "1.2.3.999", "example.com", "1.2.3.4:22", "::1"] {
            try failure { _ = try PublicIPv4.normalize(ip) }
        }
        try expect(try DDNSConfiguration.normalizedDomain(" Home.Example.COM ") == "home.example.com", "domain normalization")
        for domain in ["https://example.com", "home.example.com:22", "-home.example.com", "example..com", "127.0.0.1"] {
            try failure { _ = try DDNSConfiguration.normalizedDomain(domain) }
        }
    }

    static func sharingStatuses() throws {
        let overrides = "disabled services = {\n \"com.openssh.sshd\" => enabled\n \"com.apple.screensharing\" => disabled\n}"
        try expect(LocalSharingDetector.override(in: overrides, label: "com.openssh.sshd") == true, "SSH override read")
        try expect(LocalSharingDetector.override(in: overrides, label: "com.apple.screensharing") == false, "screen sharing disabled override read")
        try expect(LocalSharingDetector.override(in: "permission denied", label: "com.openssh.sshd") == nil, "permission error is not disabled")
        try expect(LocalSharingDetector.override(in: overrides, label: "missing") == nil, "missing override is not disabled")
        try expect(LocalSharingDetector.validGreeting("SSH-2.0-OpenSSH_10.0\r\n", prefix: "SSH-"), "SSH protocol recognized")
        try expect(LocalSharingDetector.validGreeting("RFB 003.008\n", prefix: "RFB "), "screen sharing protocol recognized")
        try expect(!LocalSharingDetector.validGreeting("HTTP/1.1 200 OK\r\n", prefix: "SSH-"), "open unrelated port is not SSH")
        try expect(!LocalSharingDetector.validGreeting("RFB invalid", prefix: "RFB "), "unrelated RFB prefix is not a service greeting")
        let unknown = LocalSharingStatus.resolve(configured: nil, responding: false, account: .unknown)
        try expect(unknown.availability == .unknown, "failed probe cannot prove service disabled")
        let denied = LocalSharingStatus.resolve(configured: true, responding: true, account: .denied)
        try expect(denied.title == "需要授权", "enabled service does not imply current account authorized")
        let remoteManagement = LocalSharingStatus.resolve(configured: false, responding: true, account: .unknown)
        try expect(remoteManagement.availability == .enabled && remoteManagement.detail.contains("确认"), "RFB via remote management still needs account confirmation")
    }

    static func cloudflare() async throws {
        let zone = String(repeating: "a", count: 32), record = String(repeating: "b", count: 32)
        let recorder = Requests()
        StubURLProtocol.install { request in
            recorder.add(request)
            guard request.url?.host == "api.cloudflare.com", request.value(forHTTPHeaderField: "Authorization") == "Bearer test-only-token" else { throw HomeLinkError.message("unexpected destination/credential") }
            let url = request.url!, query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
            let body: String
            if request.httpMethod == "PATCH" {
                let payload = try JSONSerialization.jsonObject(with: request.httpBody ?? Data()) as! [String: String]
                guard payload == ["content": "8.8.4.4"] else { throw HomeLinkError.message("unexpected mutation") }
                body = "{\"success\":true,\"result\":{\"id\":\"\(record)\",\"name\":\"home.example.com\",\"type\":\"A\",\"content\":\"8.8.4.4\",\"proxied\":false}}"
            } else if url.path.hasSuffix("/zones") {
                let value = query.first { $0.name == "name" }?.value
                body = value == "example.com" ? "{\"success\":true,\"result\":[{\"id\":\"\(zone)\",\"name\":\"example.com\"}]}" : "{\"success\":true,\"result\":[]}"
            } else {
                let item = "{\"id\":\"\(record)\",\"name\":\"home.example.com\",\"type\":\"A\",\"content\":\"1.1.1.1\",\"proxied\":false}"
                body = "{\"success\":true,\"result\":\(url.path.hasSuffix("/dns_records") ? "[" + item + "]" : item)}"
            }
            return (200, [:], Data(body.utf8))
        }
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [StubURLProtocol.self]
        let session = URLSession(configuration: config); defer { session.invalidateAndCancel() }
        let api = CloudflareDNSClient(session: session)
        let result = try await api.validate(domain: "home.example.com", token: "test-only-token")
        try expect(result.zoneID == zone && result.recordID == record, "zone and record discovery")
        try expect(recorder.methods.allSatisfy { $0 == "GET" }, "verification performs no writes")
        var saved = DDNSConfiguration(); saved.domain = result.domain; saved.zoneID = zone; saved.recordID = record
        _ = try await api.current(saved, token: "test-only-token")
        try await api.update(saved, address: "8.8.4.4", token: "test-only-token")
        try expect(recorder.methods.filter { $0 == "PATCH" }.count == 1, "one content-only PATCH")
        StubURLProtocol.install { _ in (429, ["Retry-After": "120"], Data()) }
        do { _ = try await api.current(saved, token: "test-only-token"); throw HomeLinkError.message("expected throttling") }
        catch let error as DDNSHTTP.Failure { try expect(error.retryAfter == 120, "server backoff preserved") }
        StubURLProtocol.install { _ in (200, [:], Data("{\"success\":true,\"result\":{\"id\":\"\(record)\",\"name\":\"home.example.com\",\"type\":\"A\",\"content\":\"1.1.1.1\",\"proxied\":true}}".utf8)) }
        do { _ = try await api.current(saved, token: "test-only-token"); throw Unexpected.accepted }
        catch Unexpected.accepted { throw HomeLinkError.message("TEST FAILED: proxied DNS accepted") }
        catch { }
    }

    static func controller(_ root: URL) async throws {
        let folder = root.appendingPathComponent("ddns")
        let backend = FakeBackend(), tokens = FakeTokens()
        let store = DDNSStore(directory: folder, backend: backend, tokens: tokens, observeLifecycle: false)
        await store.prepare()
        try expect(await backend.writes == 0 && !store.configuration.enabled, "default off")
        let (preview, token) = try await store.preview(domain: "home.example.com", token: "test-only-token")
        try expect(await backend.writes == 0, "preview cannot write")
        try await store.enable(preview: preview, token: token, plan: DDNSPlan())
        await store.waitForCheck()
        try expect(await backend.writes == 1, "confirmed configuration synchronizes")
        store.checkNow(); await store.waitForCheck()
        try expect(await backend.writes == 1, "unchanged IP produces no PATCH")
        await backend.changeNetwork()
        store.checkNow(); await store.waitForCheck()
        try expect(await backend.writes == 1 && store.error != nil, "untrusted network cannot update")
        await store.disable(); await store.shutdown()
        let storage = DDNSConfigurationStorage(directory: folder)
        var enabled = DDNSConfiguration(); enabled.enabled = true
        var disabled = enabled; disabled.enabled = false
        try await storage.save(disabled, revision: 100)
        try await storage.save(enabled, revision: 99)
        try expect(try await !storage.load().enabled, "stale writes cannot re-enable feature")

        let cancelBackend = FakeBackend(), cancelFolder = root.appendingPathComponent("cancel-ddns")
        let cancellation = DDNSStore(directory: cancelFolder, backend: cancelBackend, tokens: tokens, observeLifecycle: false)
        await cancellation.prepare()
        let (p, t) = try await cancellation.preview(domain: "home.example.com", token: "test-only-token")
        try await cancellation.enable(preview: p, token: t, plan: DDNSPlan()); await cancellation.waitForCheck()
        await cancelBackend.delayNextInspection()
        cancellation.checkNow()
        for _ in 0..<1000 { if await cancelBackend.suspended { break }; await Task.yield() }
        try expect(await cancelBackend.suspended, "check actually suspended")
        let writes = await cancelBackend.writes
        await cancellation.disable()
        await cancelBackend.release()
        for _ in 0..<30 { await Task.yield() }
        try expect(await cancelBackend.writes == writes && !cancellation.configuration.enabled, "late check cannot write after disabling")
        await cancellation.shutdown()
        try expect(try await !DDNSConfigurationStorage(directory: cancelFolder).load().enabled, "disabled persisted")

        let enablingBackend = FakeBackend()
        let enabling = DDNSStore(directory: root.appendingPathComponent("enable-race"), backend: enablingBackend, tokens: tokens, observeLifecycle: false)
        await enabling.prepare()
        let (candidate, credential) = try await enabling.preview(domain: "home.example.com", token: "test-only-token")
        await enablingBackend.delayNextInspection()
        let enableTask = Task { try await enabling.enable(preview: candidate, token: credential, plan: DDNSPlan()) }
        for _ in 0..<1000 { if await enablingBackend.suspended { break }; await Task.yield() }
        try expect(await enablingBackend.suspended, "enable inspection suspended")
        await enabling.disable()
        await enablingBackend.release()
        do { try await enableTask.value; throw Unexpected.accepted }
        catch Unexpected.accepted { throw HomeLinkError.message("TEST FAILED: late enabling accepted") }
        catch { }
        try expect(await enablingBackend.writes == 0 && !enabling.configuration.enabled, "disable wins over delayed enable")
        await enabling.shutdown()

        let corruptFolder = root.appendingPathComponent("corrupt-ddns")
        try FileManager.default.createDirectory(at: corruptFolder, withIntermediateDirectories: false)
        let corruptFile = corruptFolder.appendingPathComponent("ddns.json"), original = Data("preserve invalid settings".utf8)
        try original.write(to: corruptFile)
        let corrupt = DDNSStore(directory: corruptFolder, backend: FakeBackend(), tokens: tokens, observeLifecycle: false)
        await corrupt.prepare()
        do { try await corrupt.savePlan(DDNSPlan()); throw Unexpected.accepted }
        catch Unexpected.accepted { throw HomeLinkError.message("TEST FAILED: corrupt configuration overwritten") }
        catch { }
        await corrupt.disable()
        try expect(try Data(contentsOf: corruptFile) == original, "failed configuration load preserves original file")
        await corrupt.shutdown()
    }
    enum Unexpected: Error { case accepted }
}

nonisolated final class Requests: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String] = []
    func add(_ request: URLRequest) { lock.lock(); defer { lock.unlock() }; values.append(request.httpMethod ?? "GET") }
    var methods: [String] { lock.lock(); defer { lock.unlock() }; return values }
}

nonisolated final class StubURLProtocol: URLProtocol, @unchecked Sendable {
    typealias Handler = @Sendable (URLRequest) throws -> (Int, [String: String], Data)
    private static let lock = NSLock()
    nonisolated(unsafe) private static var handler: Handler?
    static func install(_ value: @escaping Handler) { lock.lock(); defer { lock.unlock() }; handler = value }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lock.lock(); let handle = Self.handler; Self.lock.unlock()
        do {
            var request = request
            if request.httpBody == nil, let stream = request.httpBodyStream {
                stream.open(); defer { stream.close() }
                var data = Data(), bytes = [UInt8](repeating: 0, count: 1024)
                while stream.hasBytesAvailable { let count = stream.read(&bytes, maxLength: bytes.count); if count <= 0 { break }; data.append(contentsOf: bytes.prefix(count)) }
                request.httpBody = data
            }
            let (status, headers, data) = try handle!(request)
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data); client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() { }
}

actor FakeTokens: DDNSTokenStorage {
    private var token = "test-only-token"
    func load() -> String { token }
    func save(_ value: String) { token = value }
}

actor FakeBackend: DDNSBackend {
    var writes = 0
    private var address = "1.1.1.1"
    private var network = "home-network"
    private var shouldDelay = false
    private var continuation: CheckedContinuation<Void, Never>?
    var suspended: Bool { continuation != nil }
    func preview(domain: String, token: String) -> DDNSPreview { value() }
    func inspect(_ configuration: DDNSConfiguration, token: String) async -> DDNSPreview {
        let result = value()
        if shouldDelay { shouldDelay = false; await withCheckedContinuation { continuation = $0 } }
        return result
    }
    func update(_ configuration: DDNSConfiguration, address: String, token: String) { writes += 1; self.address = address }
    func changeNetwork() { network = "company-network"; address = "9.9.9.9" }
    func delayNextInspection() { shouldDelay = true }
    func release() { continuation?.resume(); continuation = nil }
    private func value() -> DDNSPreview {
        DDNSPreview(record: DNSRecordContext(zoneID: String(repeating: "a", count: 32), recordID: String(repeating: "b", count: 32), domain: "home.example.com", address: address),
                    observation: PublicIPObservation(address: "8.8.4.4", network: network, sources: "test fixture"))
    }
}

private actor SharingRefreshProbe {
    var calls = 0
    func detect() async -> LocalSharingSnapshot {
        calls += 1
        try? await Task.sleep(for: .milliseconds(50))
        return LocalSharingSnapshot(ssh: .resolve(configured: true, responding: true, account: .allowed),
                                    screenSharing: .resolve(configured: false, responding: false, account: .unknown))
    }
}

nonisolated private final class GreetingTestServer: Sendable {
    let port: UInt16
    let completion: Task<Bool, Never>

    init(banner: String) throws {
        let listener = socket(AF_INET, SOCK_STREAM, 0)
        guard listener >= 0 else { throw HomeLinkError.message("test socket failed") }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(listener, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        var size = socklen_t(MemoryLayout<sockaddr_in>.size)
        let named = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(listener, $0, &size) }
        }
        guard bound == 0, named == 0, listen(listener, 1) == 0 else {
            close(listener); throw HomeLinkError.message("test listener failed")
        }
        port = UInt16(bigEndian: address.sin_port)
        completion = Task {
            (try? await BackgroundExecutor(label: "homelink.test.greeting-server").run {
                defer { close(listener) }
                var event = pollfd(fd: listener, events: Int16(POLLIN), revents: 0)
                guard poll(&event, 1, 2000) > 0 else { return false }
                let client = accept(listener, nil, nil)
                guard client >= 0 else { return false }
                defer { close(client) }
                var noSignal: Int32 = 1
                _ = setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))
                if !banner.isEmpty { _ = banner.withCString { send(client, $0, strlen($0), 0) } }
                // Keep the connection alive until the probe closes it; do not supply EOF ourselves.
                var input = pollfd(fd: client, events: Int16(POLLIN), revents: 0)
                guard poll(&input, 1, 1500) > 0 else { return false }
                var byte: UInt8 = 0
                return recv(client, &byte, 1, 0) == 0
            }) ?? false
        }
    }
}
