import 'package:flutter/foundation.dart';

/// Mirrors of the JSON vzhukhd answers with (go/tun2socks/internal/daemon).

enum DaemonState { idle, running, error }

enum RouteState { connecting, up, down }

@immutable
class DaemonRouteStatus {
  final String id;
  final String name;
  final RouteState state;
  final String? error;
  final DateTime since;
  final String server;
  final int hops;
  final int retries;

  const DaemonRouteStatus({
    required this.id,
    required this.name,
    required this.state,
    required this.error,
    required this.since,
    required this.server,
    required this.hops,
    required this.retries,
  });

  factory DaemonRouteStatus.fromJson(Map<String, dynamic> json) =>
      DaemonRouteStatus(
        id: json['id'] as String,
        name: json['name'] as String? ?? '',
        state: RouteState.values.byName(json['state'] as String),
        error: json['error'] as String?,
        since: DateTime.parse(json['since'] as String),
        server: json['server'] as String? ?? '',
        hops: json['hops'] as int? ?? 1,
        retries: json['retries'] as int? ?? 0,
      );
}

@immutable
class DaemonStatus {
  final String version;
  final DaemonState state;
  final String? error;
  final DateTime since;
  final List<DaemonRouteStatus> routes;
  final String? physicalInterface;
  final String? tunnelInterface;
  final List<String> upstreamDns;
  final int rules;

  /// Whether the helper keeps traffic history now.
  final bool recording;

  const DaemonStatus({
    required this.version,
    required this.state,
    required this.error,
    required this.since,
    required this.routes,
    required this.physicalInterface,
    required this.tunnelInterface,
    required this.upstreamDns,
    required this.rules,
    this.recording = false,
  });

  DaemonRouteStatus? route(String id) {
    for (final r in routes) {
      if (r.id == id) return r;
    }
    return null;
  }

  factory DaemonStatus.fromJson(Map<String, dynamic> json) {
    final platform = Map<String, dynamic>.from(json['platform'] as Map? ?? {});
    return DaemonStatus(
      version: json['version'] as String? ?? '',
      state: DaemonState.values.byName(json['state'] as String),
      error: json['error'] as String?,
      since: DateTime.parse(json['since'] as String),
      routes: (json['routes'] as List? ?? const [])
          .map((r) =>
              DaemonRouteStatus.fromJson(Map<String, dynamic>.from(r as Map)))
          .toList(),
      physicalInterface: platform['interface'] as String?,
      tunnelInterface: platform['tunnel'] as String?,
      upstreamDns: List<String>.from(platform['upstreamDns'] as List? ?? []),
      rules: json['rules'] as int? ?? 0,
      recording: json['recording'] as bool? ?? false,
    );
  }
}

/// One connection the daemon handled.
@immutable
class FlowRecord {
  final int id;
  final String network;
  final DateTime started;
  final DateTime? ended;
  final bool open;
  final int? pid;
  final String? app;
  final String? appPath;
  final String? exePath;
  final String? domain;
  final String? domainSource;
  final String destination;
  final String? dialed;
  final String action;
  final String? route;
  final String? ruleId;

  /// What of the rule matched: `app "telegram", port 443`. Null for the
  /// default, or from a helper too old to say.
  final String? matched;
  final int upload;
  final int download;
  final String? error;

  const FlowRecord({
    required this.id,
    required this.network,
    required this.started,
    required this.ended,
    required this.open,
    required this.pid,
    required this.app,
    required this.appPath,
    required this.exePath,
    required this.domain,
    required this.domainSource,
    required this.destination,
    required this.dialed,
    required this.action,
    required this.route,
    required this.ruleId,
    this.matched,
    required this.upload,
    required this.download,
    required this.error,
  });

  /// What a person would call the destination.
  String get target => domain ?? destination;

  /// Who opened it, or the closest thing known.
  String get owner => app ?? (exePath != null ? exePath!.split('/').last : 'unknown');

  Duration get duration => (ended ?? DateTime.now()).difference(started);

  static DateTime? _time(Object? raw) {
    if (raw is! String || raw.isEmpty) return null;
    final t = DateTime.parse(raw);
    // Go writes the zero time for "never" when omitzero is not honoured.
    return t.year <= 1 ? null : t;
  }

  factory FlowRecord.fromJson(Map<String, dynamic> json) => FlowRecord(
        id: json['id'] as int,
        network: json['network'] as String,
        started: DateTime.parse(json['started'] as String),
        ended: _time(json['ended']),
        open: json['open'] as bool? ?? false,
        pid: json['pid'] as int?,
        app: json['app'] as String?,
        appPath: json['appPath'] as String?,
        exePath: json['exePath'] as String?,
        domain: json['domain'] as String?,
        domainSource: json['domainSource'] as String?,
        destination: json['destination'] as String,
        dialed: json['dialed'] as String?,
        action: json['action'] as String? ?? '',
        route: json['route'] as String?,
        ruleId: json['ruleId'] as String?,
        matched: json['matched'] as String?,
        upload: json['upload'] as int? ?? 0,
        download: json['download'] as int? ?? 0,
        error: json['error'] as String?,
      );
}

@immutable
class FlowSnapshot {
  final int seq;
  final List<FlowRecord> active;
  final List<FlowRecord> closed;
  final int totalConnections;
  final int totalUpload;
  final int totalDownload;

  /// Whether the helper keeps history now; null from a helper that always
  /// does and cannot be told otherwise.
  final bool? recording;
  final DateTime? recordingSince;

  const FlowSnapshot({
    required this.seq,
    required this.active,
    required this.closed,
    required this.totalConnections,
    required this.totalUpload,
    required this.totalDownload,
    this.recording,
    this.recordingSince,
  });

  factory FlowSnapshot.fromJson(Map<String, dynamic> json) {
    List<FlowRecord> list(Object? raw) => (raw as List? ?? const [])
        .map((f) => FlowRecord.fromJson(Map<String, dynamic>.from(f as Map)))
        .toList();
    final totals = Map<String, dynamic>.from(json['totals'] as Map? ?? {});
    return FlowSnapshot(
      seq: json['seq'] as int? ?? 0,
      active: list(json['active']),
      closed: list(json['closed']),
      totalConnections: totals['connections'] as int? ?? 0,
      totalUpload: totals['upload'] as int? ?? 0,
      totalDownload: totals['download'] as int? ?? 0,
      recording: json['recording'] as bool?,
      recordingSince: FlowRecord._time(json['recordingSince']),
    );
  }
}

/// Connections summed by app, host, port and decision over a window
/// (vzhukhd's `stats`). Outlives the list of closed connections.
@immutable
class FlowStatRow {
  final String? app;
  final String? appPath;
  final String host;
  final int port;
  final String network;
  final String action;
  final String? route;
  final String? ruleId;
  final String? matched;
  final DateTime first;
  final DateTime last;
  final int open;
  final int conns;
  final int errors;
  final int upload;
  final int download;

  /// Distinct errors and how often, the commonest few.
  final List<({String error, int count})> reasons;

  const FlowStatRow({
    required this.app,
    required this.appPath,
    required this.host,
    required this.port,
    required this.network,
    required this.action,
    required this.route,
    required this.ruleId,
    required this.matched,
    required this.first,
    required this.last,
    required this.open,
    required this.conns,
    required this.errors,
    required this.upload,
    required this.download,
    required this.reasons,
  });

  String get owner => app ?? 'unknown';

  factory FlowStatRow.fromJson(Map<String, dynamic> j) => FlowStatRow(
        app: j['app'] as String?,
        appPath: j['appPath'] as String?,
        host: j['host'] as String? ?? '',
        port: j['port'] as int? ?? 0,
        network: j['network'] as String? ?? 'tcp',
        action: j['action'] as String? ?? '',
        route: j['route'] as String?,
        ruleId: j['ruleId'] as String?,
        matched: j['matched'] as String?,
        first: DateTime.parse(j['first'] as String),
        last: DateTime.parse(j['last'] as String),
        open: j['open'] as int? ?? 0,
        conns: j['conns'] as int? ?? 0,
        errors: j['errors'] as int? ?? 0,
        upload: j['upload'] as int? ?? 0,
        download: j['download'] as int? ?? 0,
        reasons: [
          for (final r in j['reasons'] as List? ?? const [])
            (error: (r as Map)['error'] as String, count: r['count'] as int),
        ],
      );
}

/// One minute of all traffic, for the chart.
@immutable
class FlowStatPoint {
  final DateTime at;
  final int conns;
  final int errors;
  final int upload;
  final int download;

  const FlowStatPoint({
    required this.at,
    required this.conns,
    required this.errors,
    required this.upload,
    required this.download,
  });

  factory FlowStatPoint.fromJson(Map<String, dynamic> j) => FlowStatPoint(
        at: DateTime.parse(j['at'] as String),
        conns: j['conns'] as int? ?? 0,
        errors: j['errors'] as int? ?? 0,
        upload: j['upload'] as int? ?? 0,
        download: j['download'] as int? ?? 0,
      );
}

@immutable
class FlowStats {
  /// Minutes summed; 0 is everything since [since].
  final int window;
  final DateTime since;
  final List<FlowStatRow> rows;
  final List<FlowStatPoint> timeline;

  /// Keys dropped to keep the statistics bounded.
  final int evicted;

  const FlowStats({
    required this.window,
    required this.since,
    required this.rows,
    required this.timeline,
    required this.evicted,
  });

  factory FlowStats.fromJson(Map<String, dynamic> j) => FlowStats(
        window: j['window'] as int? ?? 0,
        since: DateTime.parse(j['since'] as String),
        rows: [
          for (final r in j['rows'] as List? ?? const [])
            FlowStatRow.fromJson(Map<String, dynamic>.from(r as Map)),
        ],
        timeline: [
          for (final p in j['timeline'] as List? ?? const [])
            FlowStatPoint.fromJson(Map<String, dynamic>.from(p as Map)),
        ],
        evicted: j['evicted'] as int? ?? 0,
      );
}
