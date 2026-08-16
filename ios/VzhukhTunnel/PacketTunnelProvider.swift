import Darwin
import NetworkExtension
import VzhukhTunnelCore
import os

// os_log rather than the nicer Logger, which needs iOS 14 in an app extension
// while the rest of the project still targets 13. Same destination either way:
//
//   log stream --predicate 'subsystem == "dev.nogipx.vzhukh"'
private let log = OSLog(subsystem: "dev.nogipx.vzhukh", category: "provider")

private func logInfo(_ message: String) {
    os_log("%{public}s", log: log, type: .info, message)
}

private func logError(_ message: String) {
    os_log("%{public}s", log: log, type: .error, message)
}

/// Where the drop handler finds the provider.
///
/// A `@convention(c)` function cannot capture anything, so the callback Go
/// holds has to reach the instance through file scope. There is exactly one
/// provider per extension process, which is what makes that safe.
private let activeProviderLock = NSLock()
private weak var activeProvider: PacketTunnelProvider?

private let goDroppedTunnel: @convention(c) (UnsafePointer<CChar>?) -> Void = { reason in
    let text = reason.map { String(cString: $0) } ?? "unknown"

    activeProviderLock.lock()
    let provider = activeProvider
    activeProviderLock.unlock()

    provider?.tunnelDropped(reason: text)
}

/// Runs the SSH tunnel inside a NetworkExtension.
///
/// The division of labour: this class owns everything the system will only
/// talk to an extension about — the utun device, the network settings, the
/// reconnect schedule — and Go owns the packets and the SSH chain. The two
/// meet at a single file descriptor.
final class PacketTunnelProvider: NEPacketTunnelProvider {
    /// A packet tunnel provider is killed for going much past 50 MB, without
    /// a warning and without anything in the log to explain the death. The
    /// limit is set below that, and the collector told to work harder than
    /// its default, trading throughput for staying alive.
    private static let memoryLimitMB: Int32 = 45
    private static let gcPercent: Int32 = 20

    private static let maxRetryDelay: TimeInterval = 30

    /// `_IOWR('N', 3, struct ctl_info)`, which Swift cannot compute from the
    /// macro because the importer does not evaluate it.
    private static let ctliocginfo: UInt = 0xC064_4E03

    private let queue = DispatchQueue(label: "dev.nogipx.vzhukh.provider")

    private var configuration: TunnelConfiguration?
    private var retryCount = 0
    private var retryWork: DispatchWorkItem?
    private var stopping = false

    // MARK: - Lifecycle

    override func startTunnel(
        options _: [String: NSObject]?,
        completionHandler: @escaping (Error?) -> Void
    ) {
        queue.async {
            self.stopping = false
            self.retryCount = 0

            let configuration: TunnelConfiguration
            do {
                configuration = try TunnelConfigStore.load().validated()
            } catch {
                logError("cannot read the tunnel configuration: \(error.localizedDescription)")
                completionHandler(error)
                return
            }

            self.configuration = configuration

            activeProviderLock.lock()
            activeProvider = self
            activeProviderLock.unlock()

            vzhukh_tune_runtime(Self.memoryLimitMB, Self.gcPercent)
            vzhukh_set_drop_handler(goDroppedTunnel)

            self.bringUp(configuration) { error in
                if let error {
                    logError("tunnel did not start: \(error.localizedDescription)")
                }
                completionHandler(error)
            }
        }
    }

    override func stopTunnel(
        with reason: NEProviderStopReason,
        completionHandler: @escaping () -> Void
    ) {
        queue.async {
            logInfo("stopping, reason \(reason.rawValue)")

            self.stopping = true
            self.retryWork?.cancel()
            self.retryWork = nil

            // Unregister before stopping: tearing the tunnel down would
            // otherwise look like a drop and start a reconnect.
            vzhukh_set_drop_handler(nil)
            vzhukh_tunnel_stop()

            activeProviderLock.lock()
            activeProvider = nil
            activeProviderLock.unlock()

            completionHandler()
        }
    }

    /// Answers status queries from the app, which cannot see into the
    /// extension any other way.
    override func handleAppMessage(
        _ messageData: Data,
        completionHandler: ((Data?) -> Void)?
    ) {
        let running = vzhukh_tunnel_is_running() == 1
        let reply = ["running": running]
        completionHandler?(try? JSONSerialization.data(withJSONObject: reply))
    }

    // MARK: - Bringing the tunnel up

    private func bringUp(
        _ configuration: TunnelConfiguration,
        completion: @escaping (Error?) -> Void
    ) {
        guard let firstHop = configuration.hops.first else {
            completion(TunnelConfiguration.ConfigurationError.noHops)
            return
        }

        // Resolving before the settings are applied matters: afterwards the
        // default route belongs to the tunnel, and looking the server up
        // would mean asking through the tunnel that is not up yet.
        let serverAddress: String
        do {
            serverAddress = try Self.resolveIPv4(firstHop.host)
        } catch {
            completion(error)
            return
        }

        logInfo("first hop \(firstHop.host) resolved to \(serverAddress)")

        let settings: NEPacketTunnelNetworkSettings
        do {
            settings = try Self.makeSettings(configuration, serverAddress: serverAddress)
        } catch {
            completion(error)
            return
        }

        setTunnelNetworkSettings(settings) { [weak self] error in
            guard let self else { return }
            if let error {
                completion(error)
                return
            }
            self.queue.async {
                completion(self.startEngine(configuration))
            }
        }
    }

    /// Hands the utun descriptor to Go and starts moving packets. Returns the
    /// reason it could not, or nil.
    private func startEngine(_ configuration: TunnelConfiguration) -> Error? {
        guard let descriptor = Self.findTunnelDescriptor() else {
            return ProviderError.noTunnelDescriptor
        }

        let payload: Data
        do {
            payload = try configuration.encoded()
        } catch {
            return error
        }

        let result = payload.withUnsafeBytes { raw -> Int32 in
            guard let base = raw.baseAddress else { return -1 }
            // Data is not null-terminated and the C side expects a string.
            var bytes = [CChar](repeating: 0, count: raw.count + 1)
            memcpy(&bytes, base, raw.count)
            return vzhukh_tunnel_start(descriptor, &bytes)
        }

        guard result == 0 else {
            return ProviderError.engineRefused(code: result, detail: Self.lastEngineError())
        }

        logInfo("tunnel up on descriptor \(descriptor)")
        return nil
    }

    // MARK: - Reconnecting

    /// Called from Go when the chain dies on its own.
    ///
    /// Reconnecting happens here rather than in the app: once the phone has
    /// been idle a while the app is suspended, and the extension is the only
    /// part of this still running.
    func tunnelDropped(reason: String) {
        queue.async {
            guard !self.stopping else { return }

            logError("tunnel dropped: \(reason)")
            self.reasserting = true
            vzhukh_tunnel_stop()
            self.scheduleReconnect()
        }
    }

    private func scheduleReconnect() {
        guard !stopping, let configuration else { return }

        let delay = Self.retryDelay(attempt: retryCount)
        retryCount += 1

        logInfo("reconnecting in \(Int(delay))s (attempt \(retryCount))")

        let work = DispatchWorkItem { [weak self] in
            guard let self, !self.stopping else { return }

            self.bringUp(configuration) { error in
                self.queue.async {
                    guard !self.stopping else { return }

                    if let error {
                        logError("reconnect failed: \(error.localizedDescription)")
                        self.scheduleReconnect()
                        return
                    }

                    logInfo("reconnected")
                    self.retryCount = 0
                    self.reasserting = false
                }
            }
        }

        retryWork = work
        queue.asyncAfter(deadline: .now() + delay, execute: work)
    }

    /// Doubling, capped — the same policy VpnController uses on Android.
    static func retryDelay(attempt: Int) -> TimeInterval {
        min(pow(2, Double(min(attempt, 5))), maxRetryDelay)
    }

    // MARK: - Network settings

    static func makeSettings(
        _ configuration: TunnelConfiguration,
        serverAddress: String
    ) throws -> NEPacketTunnelNetworkSettings {
        guard let address = configuration.tunnelAddress,
              let subnetMask = configuration.tunnelSubnetMask
        else {
            throw TunnelConfiguration.ConfigurationError.badAddress(configuration.address)
        }

        let settings = NEPacketTunnelNetworkSettings(tunnelRemoteAddress: serverAddress)

        let ipv4 = NEIPv4Settings(addresses: [address], subnetMasks: [subnetMask])
        ipv4.includedRoutes = [NEIPv4Route.default()]
        // The SSH connection has to stay outside the tunnel it is carrying,
        // or it becomes its own transport. VzhukhVpnService does the same on
        // Android by splitting 0.0.0.0/0 around the server's address.
        ipv4.excludedRoutes = [
            NEIPv4Route(destinationAddress: serverAddress, subnetMask: "255.255.255.255"),
        ]
        settings.ipv4Settings = ipv4

        settings.mtu = NSNumber(value: configuration.mtu)

        let dns = NEDNSSettings(servers: configuration.dnsServers)
        // An empty match domain claims every lookup, which is the point: the
        // whole reason for the tunnel is that the local resolver is not to be
        // trusted with them.
        dns.matchDomains = [""]
        settings.dnsSettings = dns

        return settings
    }

    // MARK: - Plumbing

    /// Finds the descriptor of the utun the extension was given.
    ///
    /// NetworkExtension exposes the device as `packetFlow`, an object that
    /// reads and writes packets one array at a time, and never as a
    /// descriptor. But a descriptor is what the packet engine wants, and it
    /// does exist — so it is found the way WireGuard finds it: walk the open
    /// descriptors and pick the one that is a socket in the AF_SYSTEM family
    /// whose control ID matches `com.apple.net.utun_control`.
    ///
    /// Undocumented, and load-bearing for every Go-based tunnel on iOS.
    static func findTunnelDescriptor() -> Int32? {
        var info = ctl_info()
        withUnsafeMutablePointer(to: &info.ctl_name) { pointer in
            pointer.withMemoryRebound(
                to: CChar.self,
                capacity: MemoryLayout.size(ofValue: pointer.pointee)
            ) {
                _ = strcpy($0, "com.apple.net.utun_control")
            }
        }

        for candidate in Int32(0)...1024 {
            var address = sockaddr_ctl()
            var length = socklen_t(MemoryLayout<sockaddr_ctl>.size)
            var result: Int32 = -1

            withUnsafeMutablePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    result = getpeername(candidate, $0, &length)
                }
            }

            guard result == 0, address.sc_family == UInt8(AF_SYSTEM) else { continue }

            if info.ctl_id == 0 {
                guard ioctl(candidate, Self.ctliocginfo, &info) == 0 else { continue }
            }

            if address.sc_id == info.ctl_id {
                return candidate
            }
        }

        return nil
    }

    /// Resolves a host to a dotted IPv4 address, leaving one alone if that is
    /// what it already is.
    static func resolveIPv4(_ host: String) throws -> String {
        var hints = addrinfo()
        hints.ai_family = AF_INET
        hints.ai_socktype = SOCK_STREAM

        var results: UnsafeMutablePointer<addrinfo>?
        let status = getaddrinfo(host, nil, &hints, &results)
        guard status == 0, let first = results else {
            throw ProviderError.cannotResolve(host: host, detail: String(cString: gai_strerror(status)))
        }
        defer { freeaddrinfo(results) }

        guard let raw = first.pointee.ai_addr else {
            throw ProviderError.cannotResolve(host: host, detail: "no address returned")
        }

        var sin = raw.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr }
        var text = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
        guard inet_ntop(AF_INET, &sin, &text, socklen_t(INET_ADDRSTRLEN)) != nil else {
            throw ProviderError.cannotResolve(host: host, detail: "address could not be formatted")
        }

        return String(cString: text)
    }

    static func lastEngineError() -> String {
        guard let raw = vzhukh_last_error() else { return "no detail" }
        defer { vzhukh_free(raw) }

        let text = String(cString: raw)
        return text.isEmpty ? "no detail" : text
    }
}

enum ProviderError: LocalizedError {
    case noTunnelDescriptor
    case engineRefused(code: Int32, detail: String)
    case cannotResolve(host: String, detail: String)

    var errorDescription: String? {
        switch self {
        case .noTunnelDescriptor:
            return "The tunnel device could not be found after the network settings were applied."
        case let .engineRefused(code, detail):
            return "The tunnel engine refused to start (\(code)): \(detail)"
        case let .cannotResolve(host, detail):
            return "Could not resolve \(host): \(detail)"
        }
    }
}
