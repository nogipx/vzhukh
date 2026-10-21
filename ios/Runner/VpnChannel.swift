import Flutter
import NetworkExtension
import os

private let log = OSLog(subsystem: "dev.nogipx.vzhukh", category: "channel")

/// The app side of the tunnel.
///
/// On Android the Dart code holds the SSH connection itself and asks the
/// platform only for a TUN descriptor. Here it holds nothing: the tunnel lives
/// in a separate process that outlives the app, so all Dart can do is write
/// the configuration down, ask the system to start the extension, and watch.
final class VpnChannel: NSObject {
    private static let methodChannelName = "dev.nogipx.vzhukh/vpn"
    private static let statusChannelName = "dev.nogipx.vzhukh/vpn_status"

    /// Must match PRODUCT_BUNDLE_IDENTIFIER of the extension target.
    private static let providerBundleIdentifier = "dev.nogipx.vzhukh.tunnel"

    private var manager: NETunnelProviderManager?
    private var statusSink: FlutterEventSink?

    func register(with registrar: FlutterPluginRegistrar) {
        let methods = FlutterMethodChannel(
            name: Self.methodChannelName,
            binaryMessenger: registrar.messenger()
        )
        methods.setMethodCallHandler { [weak self] call, result in
            self?.handle(call, result: result)
        }

        FlutterEventChannel(
            name: Self.statusChannelName,
            binaryMessenger: registrar.messenger()
        ).setStreamHandler(self)

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(vpnStatusChanged),
            name: .NEVPNStatusDidChange,
            object: nil
        )
    }

    // MARK: - Method calls

    private func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        switch call.method {
        case "startVpn":
            guard let arguments = call.arguments as? [String: Any],
                  let json = arguments["config"] as? String,
                  let data = json.data(using: .utf8)
            else {
                result(FlutterError(
                    code: "bad_arguments",
                    message: "startVpn needs a 'config' JSON string",
                    details: nil
                ))
                return
            }
            start(configurationData: data, result: result)

        case "stopVpn":
            stop(result: result)

        case "vpnStatus":
            loadManager { manager, _ in
                result(Self.name(for: manager?.connection.status ?? .invalid))
            }

        default:
            result(FlutterMethodNotImplemented)
        }
    }

    private func start(configurationData: Data, result: @escaping FlutterResult) {
        let configuration: TunnelConfiguration
        do {
            configuration = try TunnelConfiguration.decoded(from: configurationData).validated()
            // The extension is a separate process and cannot be handed
            // arguments, so the configuration goes where both can reach it.
            try TunnelConfigStore.save(configuration)
        } catch {
            result(FlutterError(
                code: "bad_configuration",
                message: error.localizedDescription,
                details: nil
            ))
            return
        }

        loadManager { [weak self] manager, error in
            guard let self else { return }
            if let error {
                result(Self.failure(error))
                return
            }

            let manager = manager ?? NETunnelProviderManager()

            let proto = NETunnelProviderProtocol()
            proto.providerBundleIdentifier = Self.providerBundleIdentifier
            proto.serverAddress = configuration.hops.first?.host
            // Nothing sensitive goes in here: providerConfiguration is stored
            // in the system's VPN preferences, and these are SSH keys.
            proto.providerConfiguration = [:]

            manager.protocolConfiguration = proto
            manager.localizedDescription = "Vzhukh"
            manager.isEnabled = true

            manager.saveToPreferences { error in
                if let error {
                    result(Self.failure(error))
                    return
                }

                // Reloading is not optional. Starting from the object that was
                // just saved fails with a configuration-invalid error, because
                // the copy in hand has no identifier until it is read back.
                manager.loadFromPreferences { error in
                    if let error {
                        result(Self.failure(error))
                        return
                    }

                    self.manager = manager
                    do {
                        try manager.connection.startVPNTunnel()
                        os_log("%{public}s", log: log, type: .info, "tunnel start requested")
                        result(nil)
                    } catch {
                        result(Self.failure(error))
                    }
                }
            }
        }
    }

    private func stop(result: @escaping FlutterResult) {
        loadManager { manager, error in
            if let error {
                result(Self.failure(error))
                return
            }
            manager?.connection.stopVPNTunnel()
            result(nil)
        }
    }

    /// Finds the configuration this app installed, if it is still there. A
    /// user can delete it from Settings at any time, which is why it is looked
    /// up again rather than cached.
    private func loadManager(completion: @escaping (NETunnelProviderManager?, Error?) -> Void) {
        NETunnelProviderManager.loadAllFromPreferences { managers, error in
            if let error {
                completion(nil, error)
                return
            }

            let mine = managers?.first { manager in
                let proto = manager.protocolConfiguration as? NETunnelProviderProtocol
                return proto?.providerBundleIdentifier == Self.providerBundleIdentifier
            }

            self.manager = mine
            completion(mine, nil)
        }
    }

    // MARK: - Status

    @objc private func vpnStatusChanged(_ notification: Notification) {
        guard let connection = notification.object as? NEVPNConnection else { return }
        emit(connection.status)
    }

    private func emit(_ status: NEVPNStatus) {
        guard let statusSink else { return }
        DispatchQueue.main.async { statusSink(Self.name(for: status)) }
    }

    /// The names Dart maps onto VpnStatus. `reasserting` is the one that has
    /// no Android equivalent: it means the extension is rebuilding the tunnel
    /// under a connection that, as far as the system is concerned, never went
    /// away.
    private static func name(for status: NEVPNStatus) -> String {
        switch status {
        case .invalid: return "invalid"
        case .disconnected: return "disconnected"
        case .connecting: return "connecting"
        case .connected: return "connected"
        case .reasserting: return "reasserting"
        case .disconnecting: return "disconnecting"
        @unknown default: return "invalid"
        }
    }

    private static func failure(_ error: Error) -> FlutterError {
        let message: String
        if let vpnError = error as? NEVPNError, vpnError.code == .configurationReadWriteFailed {
            // What a missing entitlement looks like from here.
            message = """
            \(error.localizedDescription) — this usually means the app is not \
            allowed to install a VPN configuration. packet-tunnel-provider \
            requires a paid Apple Developer Program membership.
            """
        } else {
            message = error.localizedDescription
        }

        os_log("%{public}s", log: log, type: .error, message)
        return FlutterError(code: "vpn_error", message: message, details: nil)
    }
}

extension VpnChannel: FlutterStreamHandler {
    func onListen(
        withArguments _: Any?,
        eventSink events: @escaping FlutterEventSink
    ) -> FlutterError? {
        statusSink = events
        // Report where things stand now, so a freshly opened app does not sit
        // on "disconnected" while a tunnel is already up.
        loadManager { manager, _ in
            self.emit(manager?.connection.status ?? .invalid)
        }
        return nil
    }

    func onCancel(withArguments _: Any?) -> FlutterError? {
        statusSink = nil
        return nil
    }
}
