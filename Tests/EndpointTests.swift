import Foundation

@main
struct EndpointTests {
    static func main() throws {
        let plain = try Endpoint(address: "studio.local")
        precondition(plain.host == "studio.local" && plain.port == 22)
        let custom = try Endpoint(address: " home.example.com:2222 ", fallbackPort: "2200")
        precondition(custom.host == "home.example.com" && custom.port == 2222)
        let advanced = try Endpoint(address: "192.168.1.2", fallbackPort: "2200")
        precondition(advanced.port == 2200)
        let ipv6 = try Endpoint(address: "[2001:db8::1]:2222")
        precondition(ipv6.host == "2001:db8::1" && ipv6.port == 2222)
        let local6 = try Endpoint(address: "::1")
        precondition(local6.host == "::1" && local6.port == 22)
        for address in ["", "-oProxyCommand=evil", "host;touch /tmp/a", "ssh://host", "user@host",
                        "host:0", "host:65536", "host:", "host:abc", "[::1", "[::1]oops"] {
            do {
                _ = try Endpoint(address: address)
                preconditionFailure("Accepted invalid address: \(address)")
            } catch is HomeLinkError { }
        }
        for user in ["", "-root", "user name", "root;id", "root@host"] {
            do {
                _ = try Endpoint.validateUsername(user)
                preconditionFailure("Accepted invalid username: \(user)")
            } catch is HomeLinkError { }
        }
        let user = try Endpoint.validateUsername(" studio ")
        precondition(user == "studio")
        let device = RemoteDevice(id: UUID(), name: "家庭 Studio", host: ipv6.host, port: ipv6.port,
                                  username: "studio", publicKey: "ssh-ed25519 test")
        let decoded = try JSONDecoder().decode(RemoteDevice.self, from: JSONEncoder().encode(device))
        precondition(decoded == device && decoded.address == "[2001:db8::1]:2222")
        print("PASS: address parsing, port precedence, IPv6, invalid-input rejection, device persistence")
    }
}
