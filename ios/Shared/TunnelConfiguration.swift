import Foundation

/// One SSH server in the chain, with the credentials for it.
///
/// The field names are the wire format the Go engine parses — see
/// `go/tun2socks/internal/sshtun/sshtun.go`. Renaming anything here means
/// renaming it there in the same commit.
struct TunnelHop: Codable, Equatable {
    var host: String
    var port: Int
    var username: String
    var password: String?
    var privateKeyPem: String?
    var passphrase: String?

    init(
        host: String,
        port: Int = 22,
        username: String,
        password: String? = nil,
        privateKeyPem: String? = nil,
        passphrase: String? = nil
    ) {
        self.host = host
        self.port = port
        self.username = username
        self.password = password
        self.privateKeyPem = privateKeyPem
        self.passphrase = passphrase
    }
}

/// Everything needed to bring a tunnel up.
///
/// The same JSON goes to two readers. Go takes the hops and the packet
/// settings; the extension additionally reads `dnsServers`, which it applies
/// through `NEDNSSettings` before Go ever sees a packet. Go ignores fields it
/// does not know, so the two do not have to agree on the whole shape.
struct TunnelConfiguration: Codable, Equatable {
    var hops: [TunnelHop]

    /// The address configured on the TUN device. Matches what
    /// `VzhukhVpnService` uses on Android.
    var address: String = "10.0.0.2/30"

    var mtu: UInt32 = 1500

    var dnsServers: [String] = ["8.8.8.8", "8.8.4.4"]

    var connectTimeoutSeconds: Int?
    var keepAliveSeconds: Int?
    var udpTimeoutSeconds: Int?

    init(
        hops: [TunnelHop],
        address: String = "10.0.0.2/30",
        mtu: UInt32 = 1500,
        dnsServers: [String] = ["8.8.8.8", "8.8.4.4"],
        connectTimeoutSeconds: Int? = nil,
        keepAliveSeconds: Int? = nil,
        udpTimeoutSeconds: Int? = nil
    ) {
        self.hops = hops
        self.address = address
        self.mtu = mtu
        self.dnsServers = dnsServers
        self.connectTimeoutSeconds = connectTimeoutSeconds
        self.keepAliveSeconds = keepAliveSeconds
        self.udpTimeoutSeconds = udpTimeoutSeconds
    }

    /// Written out rather than synthesised, because the synthesised decoder
    /// ignores the default values above and fails on a missing key. Only the
    /// hops are genuinely required; everything else has an answer already.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        hops = try container.decode([TunnelHop].self, forKey: .hops)
        address = try container.decodeIfPresent(String.self, forKey: .address) ?? "10.0.0.2/30"
        mtu = try container.decodeIfPresent(UInt32.self, forKey: .mtu) ?? 1500
        dnsServers = try container.decodeIfPresent([String].self, forKey: .dnsServers)
            ?? ["8.8.8.8", "8.8.4.4"]
        connectTimeoutSeconds = try container.decodeIfPresent(Int.self, forKey: .connectTimeoutSeconds)
        keepAliveSeconds = try container.decodeIfPresent(Int.self, forKey: .keepAliveSeconds)
        udpTimeoutSeconds = try container.decodeIfPresent(Int.self, forKey: .udpTimeoutSeconds)
    }

    enum ConfigurationError: LocalizedError {
        case noHops
        case badAddress(String)
        case hopMissingCredentials(Int)

        var errorDescription: String? {
            switch self {
            case .noHops:
                return "The tunnel configuration lists no servers."
            case let .badAddress(address):
                return "The tunnel address \(address) is not a valid CIDR block."
            case let .hopMissingCredentials(index):
                return "Server \(index + 1) has neither a password nor a private key."
            }
        }
    }

    /// Rejects what would otherwise come back as a tunnel that starts and then
    /// does nothing, which is a much harder thing to explain to a user.
    func validated() throws -> TunnelConfiguration {
        guard !hops.isEmpty else { throw ConfigurationError.noHops }

        for (index, hop) in hops.enumerated() {
            let hasPassword = !(hop.password ?? "").isEmpty
            let hasKey = !(hop.privateKeyPem ?? "").isEmpty
            guard hasPassword || hasKey else {
                throw ConfigurationError.hopMissingCredentials(index)
            }
        }

        guard let parsed = CIDR(address), parsed.isIPv4 else {
            throw ConfigurationError.badAddress(address)
        }

        return self
    }

    /// The address without its prefix length, which is the form
    /// `NEIPv4Settings` wants.
    var tunnelAddress: String? { CIDR(address)?.address }

    /// The prefix length as a dotted mask, again for `NEIPv4Settings`.
    var tunnelSubnetMask: String? { CIDR(address)?.subnetMask }

    func encoded() throws -> Data {
        try JSONEncoder().encode(self)
    }

    static func decoded(from data: Data) throws -> TunnelConfiguration {
        try JSONDecoder().decode(TunnelConfiguration.self, from: data)
    }
}

/// A parsed `a.b.c.d/n`, which Foundation has no type for.
struct CIDR {
    let address: String
    let prefixLength: Int

    init?(_ text: String) {
        let parts = text.split(separator: "/", maxSplits: 1)
        guard parts.count == 2, let length = Int(parts[1]), (0...32).contains(length) else {
            return nil
        }

        let octets = parts[0].split(separator: ".")
        guard octets.count == 4,
              octets.allSatisfy({ Int($0).map { (0...255).contains($0) } == true })
        else {
            return nil
        }

        address = String(parts[0])
        prefixLength = length
    }

    var isIPv4: Bool { true }

    var subnetMask: String {
        let mask: UInt32 = prefixLength == 0 ? 0 : ~UInt32(0) << (32 - prefixLength)
        return [24, 16, 8, 0].map { String((mask >> UInt32($0)) & 0xFF) }.joined(separator: ".")
    }
}
