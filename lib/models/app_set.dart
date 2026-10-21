import 'app_routing_config.dart';

/// A named list of Android apps and what to do with it: only these through
/// the tunnel, or everything but these. Routes and servers point at a set,
/// so one change reaches all of them.
class AppSet {
  final String id;
  final String name;
  final AppRoutingConfig config;

  const AppSet({required this.id, required this.name, required this.config});

  AppSet copyWith({String? name, AppRoutingConfig? config}) =>
      AppSet(id: id, name: name ?? this.name, config: config ?? this.config);

  Map<String, dynamic> toJson() => {'id': id, 'name': name, ...config.toJson()};

  factory AppSet.fromJson(Map<String, dynamic> json) => AppSet(
        id: json['id'] as String,
        name: json['name'] as String,
        config: AppRoutingConfig.fromJson(json),
      );
}
