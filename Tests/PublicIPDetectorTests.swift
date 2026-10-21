import Foundation

extension StudioFeaturesTests {
    static func publicIP() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        let session = URLSession(configuration: config, delegate: NoRedirects(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        StubURLProtocol.install { request in
            guard ["https://checkip.amazonaws.com", "https://api.ipify.org", "https://4.ident.me"].contains(request.url?.absoluteString ?? ""), request.httpMethod == "GET",
                  request.value(forHTTPHeaderField: "Authorization") == nil else { throw HomeLinkError.message("unexpected address query/credential") }
            return (200, [:], Data("8.8.4.4\n".utf8))
        }
        let normal = PublicIPDetector(session: session, dnsQuery: { "8.8.4.4" }, networkIdentity: { "external-v2:home" })
        let result = try await normal.observe()
        try expect(result.address == "8.8.4.4" && result.network == "external-v2:home", "HTTPS and DNS agreement")
        try expect(result.sources.contains("Amazon") && result.sources.contains("OpenDNS"), "actual sources shown")
        let mismatch = PublicIPDetector(session: session, dnsQuery: { "9.9.9.9" }, networkIdentity: { "external-v2:home" })
        do { _ = try await mismatch.observe(); throw Unexpected.accepted }
        catch Unexpected.accepted { throw HomeLinkError.message("TEST FAILED: IP mismatch accepted") }
        catch { try expect(error.localizedDescription.contains("不一致"), "mismatch stops update") }
        let changing = TestIPNetwork()
        let changed = PublicIPDetector(session: session, dnsQuery: { "8.8.4.4" }, networkIdentity: { await changing.next() })
        do { _ = try await changed.observe(); throw Unexpected.accepted }
        catch Unexpected.accepted { throw HomeLinkError.message("TEST FAILED: network change accepted") }
        catch { try expect(error.localizedDescription.contains("网络发生变化"), "network change stops update") }
        let dnsFailure = PublicIPDetector(session: session, dnsQuery: { throw HomeLinkError.message("dns-test-failed") }, networkIdentity: { "home" })
        let fallback = try await dnsFailure.observe()
        try expect(fallback.sources.contains("ipify") && fallback.sources.contains("ident.me"), "DNS failure uses agreeing HTTPS backups")
        StubURLProtocol.install { request in
            if request.url?.host == "checkip.amazonaws.com" { return (503, [:], Data()) }
            return (200, [:], Data("8.8.4.4".utf8))
        }
        let backupsOnly = try await dnsFailure.observe()
        try expect(!backupsOnly.sources.contains("Amazon") && !backupsOnly.sources.contains("OpenDNS"), "actual fallback sources reported")
        StubURLProtocol.install { request in
            if request.url?.host == "4.ident.me" { return (200, [:], Data("9.9.9.9".utf8)) }
            return (200, [:], Data("8.8.4.4".utf8))
        }
        do { _ = try await dnsFailure.observe(); throw Unexpected.accepted }
        catch Unexpected.accepted { throw HomeLinkError.message("TEST FAILED: backup conflict accepted") }
        catch { try expect(error.localizedDescription.contains("不一致"), "backup conflict rejects even a two-source majority") }
        StubURLProtocol.install { request in
            if request.url?.host == "checkip.amazonaws.com" { return (200, [:], Data("8.8.4.4".utf8)) }
            return (200, [:], Data("198.18.0.1".utf8))
        }
        do { _ = try await dnsFailure.observe(); throw Unexpected.accepted }
        catch Unexpected.accepted { throw HomeLinkError.message("TEST FAILED: single source accepted") }
        catch { try expect(error.localizedDescription.contains("不足两个"), "invalid backup addresses cannot provide quorum") }
        let task = Task { try await normal.observe() }; task.cancel()
        do { _ = try await task.value; throw Unexpected.accepted }
        catch Unexpected.accepted { throw HomeLinkError.message("TEST FAILED: cancelled observation accepted") }
        catch is CancellationError { }
        for invalid in ["", "192.168.0.1", "198.18.0.1", "100.64.0.1", "8.8.4.4\n9.9.9.9", ";; timed out", "myip.opendns.com.\n8.8.4.4"] {
            try failure { _ = try PublicIPDetector.parseDNS(invalid) }
        }
        try expect(try PublicIPDetector.parseDNS("8.8.4.4\n") == "8.8.4.4", "single public DNS result")
        try expect(DDNSNetworkIdentity.canonicalMAC("a:b:c:d:e:f") == "0a:0b:0c:0d:0e:0f", "gateway MAC canonicalization")
        try expect(DDNSNetworkIdentity.canonicalMAC("(incomplete)") == nil, "incomplete ARP rejected")
        try expect(DDNSNetworkIdentity.gatewayMAC(in: ["ARPResolvedIPAddress": "192.168.0.2", "ARPResolvedHardwareAddress": "a:b:c:d:e:f"], router: "192.168.0.1") == nil, "wrong router identity rejected")
        try expect(try await DDNSCommandOutput.read("/usr/bin/printf", arguments: ["8.8.4.4\\n"], timeout: 2) == "8.8.4.4\n", "system utility capture without shell")
        do {
            _ = try await DDNSCommandOutput.read("/usr/bin/printf", arguments: [String(repeating: "x", count: 5000)], timeout: 2)
            throw Unexpected.accepted
        } catch Unexpected.accepted { throw HomeLinkError.message("TEST FAILED: oversized utility output accepted") }
        catch { }
        StubURLProtocol.install { _ in (503, [:], Data()) }
        do { _ = try await normal.observe(); throw Unexpected.accepted }
        catch Unexpected.accepted { throw HomeLinkError.message("TEST FAILED: HTTP failure accepted") }
        catch { try expect(error.localizedDescription.contains("不足两个"), "insufficient sources fail safely") }
        print("Public IP: primary agreement, HTTPS backups, conflicting backups, no single-source fallback, network binding, cancellation, DNS validation, gateway identity and bounded utility output passed.")
    }
}

private actor TestIPNetwork {
    var calls = 0
    func next() -> String { calls += 1; return calls == 1 ? "home" : "office" }
}
