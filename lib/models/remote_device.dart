/// A television this phone can drive over ADB.
///
/// The address is stored rather than discovered every time: a set that has
/// already been paired keeps its position on the network in practice, and
/// waiting on a subnet sweep before every session would be tedious.
class RemoteDevice {
  const RemoteDevice({
    required this.id,
    required this.name,
    required this.host,
    this.port = 5555,
  });

  final String id;
  final String name;
  final String host;
  final int port;

  RemoteDevice copyWith({String? name, String? host, int? port}) =>
      RemoteDevice(
        id: id,
        name: name ?? this.name,
        host: host ?? this.host,
        port: port ?? this.port,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'host': host,
        'port': port,
      };

  factory RemoteDevice.fromJson(Map<String, dynamic> json) => RemoteDevice(
        id: json['id'] as String,
        name: json['name'] as String,
        host: json['host'] as String,
        port: json['port'] as int? ?? 5555,
      );
}
