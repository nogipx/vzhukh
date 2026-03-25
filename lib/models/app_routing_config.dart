enum AppRoutingMode { whitelist, blacklist }

class AppRoutingConfig {
  final AppRoutingMode mode;
  final List<String> packages;

  const AppRoutingConfig({
    required this.mode,
    required this.packages,
  });

  const AppRoutingConfig.empty()
      : mode = AppRoutingMode.blacklist,
        packages = const [];

  AppRoutingConfig copyWith({
    AppRoutingMode? mode,
    List<String>? packages,
  }) =>
      AppRoutingConfig(
        mode: mode ?? this.mode,
        packages: packages ?? this.packages,
      );

  Map<String, dynamic> toJson() => {
        'mode': mode.name,
        'packages': packages,
      };

  factory AppRoutingConfig.fromJson(Map<String, dynamic> json) =>
      AppRoutingConfig(
        mode: AppRoutingMode.values.byName(json['mode'] as String),
        packages: List<String>.from(json['packages'] as List),
      );
}
