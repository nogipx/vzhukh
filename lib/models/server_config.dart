class ServerConfig {
  final String host;
  final int port;
  final String username;
  final String? password;
  final String? privateKey;

  /// If true, SSH connects via WebSocket instead of raw TCP.
  /// [wsUrl] must be set, e.g. "wss://example.com/tunnel".
  final bool useWebSocket;
  final String? wsUrl;
  final bool skipTlsVerify;

  const ServerConfig({
    required this.host,
    required this.port,
    required this.username,
    this.password,
    this.privateKey,
    this.useWebSocket = false,
    this.wsUrl,
    this.skipTlsVerify = false,
  });

  bool get isValid =>
      host.isNotEmpty &&
      port > 0 &&
      port <= 65535 &&
      username.isNotEmpty &&
      (password != null && password!.isNotEmpty ||
          privateKey != null && privateKey!.isNotEmpty);

  Map<String, dynamic> toJson() => {
        'host': host,
        'port': port,
        'username': username,
        'password': password,
        'privateKey': privateKey,
        'useWebSocket': useWebSocket,
        'wsUrl': wsUrl,
        'skipTlsVerify': skipTlsVerify,
      };

  factory ServerConfig.fromJson(Map<String, dynamic> json) => ServerConfig(
        host: json['host'] as String,
        port: json['port'] as int,
        username: json['username'] as String,
        password: json['password'] as String?,
        privateKey: json['privateKey'] as String?,
        useWebSocket: json['useWebSocket'] as bool? ?? false,
        wsUrl: json['wsUrl'] as String?,
        skipTlsVerify: json['skipTlsVerify'] as bool? ?? false,
      );
}
