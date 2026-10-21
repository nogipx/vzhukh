import 'daemon_models.dart';

/// What traffic can be grouped and filtered by.
enum TrafficDim {
  app('app', 'App'),
  site('site', 'Site'),
  host('host', 'Host'),
  port('port', 'Port'),
  action('action', 'Action'),
  route('route', 'Route'),
  rule('rule', 'Rule'),
  network('net', 'Protocol');

  const TrafficDim(this.key, this.label);

  /// The word for it in a query: `app:telegram`.
  final String key;
  final String label;

  static TrafficDim? byKey(String key) => switch (key) {
        'domain' => TrafficDim.host,
        'proto' || 'network' => TrafficDim.network,
        _ => values.where((d) => d.key == key).firstOrNull,
      };
}

/// The last two labels of [host], a good enough guess at the site:
/// cdn.example.com is example.com. Addresses stay as they are. Wrong for
/// co.uk-style suffixes.
String siteOf(String host) {
  if (host.isEmpty || RegExp(r'^[\d.]+$').hasMatch(host) || host.contains(':')) return host;
  final parts = host.split('.');
  return parts.length <= 2 ? host : parts.sublist(parts.length - 2).join('.');
}

/// One line of traffic: a key of the helper's statistics, or one open
/// connection, with what it adds up to.
class TrafficRow {
  TrafficRow({
    required this.app,
    this.appPath,
    required this.host,
    required this.port,
    required this.network,
    required this.action,
    this.route,
    this.ruleId,
    this.matched,
    this.conns = 0,
    this.open = 0,
    this.errors = 0,
    this.upload = 0,
    this.download = 0,
    this.rateUp = 0,
    this.rateDown = 0,
    DateTime? last,
    this.reasons = const [],
  }) : last = last ?? DateTime.fromMillisecondsSinceEpoch(0);

  final String app;
  final String? appPath;
  final String host;
  final int port;
  final String network;
  final String action;
  final String? route;
  final String? ruleId;
  final String? matched;
  final int conns;
  final int open;
  final int errors;
  final int upload;
  final int download;

  /// Bytes a second now, for open connections.
  final double rateUp;
  final double rateDown;
  final DateTime last;
  final List<({String error, int count})> reasons;

  late final String site = siteOf(host);

  factory TrafficRow.fromStat(FlowStatRow r) => TrafficRow(
        app: r.owner,
        appPath: r.appPath,
        host: r.host,
        port: r.port,
        network: r.network,
        action: r.action,
        route: r.route,
        ruleId: r.ruleId,
        matched: r.matched,
        conns: r.conns,
        open: r.open,
        errors: r.errors,
        upload: r.upload,
        download: r.download,
        last: r.last,
        reasons: r.reasons,
      );

  /// One connection as a row. [rateUp] and [rateDown] come from comparing
  /// two polls.
  factory TrafficRow.fromFlow(FlowRecord f, {double rateUp = 0, double rateDown = 0}) {
    final port = int.tryParse(f.destination.split(':').last) ?? 0;
    return TrafficRow(
      app: f.owner,
      appPath: f.appPath ?? f.exePath,
      host: f.domain ?? f.destination.substring(0, f.destination.lastIndexOf(':').clamp(0, f.destination.length)),
      port: port,
      network: f.network,
      action: f.action,
      route: f.route,
      ruleId: f.ruleId,
      matched: f.matched,
      conns: 1,
      open: f.open ? 1 : 0,
      errors: f.error == null ? 0 : 1,
      upload: f.upload,
      download: f.download,
      rateUp: rateUp,
      rateDown: rateDown,
      last: f.ended ?? DateTime.now(),
      reasons: f.error == null ? const [] : [(error: f.error!, count: 1)],
    );
  }

  /// The raw value of [dim]; route and rule are ids, '' when none.
  String value(TrafficDim dim) => switch (dim) {
        TrafficDim.app => app,
        TrafficDim.site => site,
        TrafficDim.host => host,
        TrafficDim.port => '$port',
        TrafficDim.action => action,
        TrafficDim.route => route ?? '',
        TrafficDim.rule => ruleId ?? '',
        TrafficDim.network => network,
      };
}

/// Sums of a set of rows.
class TrafficTotals {
  int conns = 0, open = 0, errors = 0, upload = 0, download = 0;
  double rateUp = 0, rateDown = 0;
  DateTime last = DateTime.fromMillisecondsSinceEpoch(0);

  void add(TrafficRow r) {
    conns += r.conns;
    open += r.open;
    errors += r.errors;
    upload += r.upload;
    download += r.download;
    rateUp += r.rateUp;
    rateDown += r.rateDown;
    if (r.last.isAfter(last)) last = r.last;
  }

  int get bytes => upload + download;
  double get rate => rateUp + rateDown;

  static TrafficTotals of(Iterable<TrafficRow> rows) {
    final t = TrafficTotals();
    rows.forEach(t.add);
    return t;
  }
}

/// A filter typed as words: `app:telegram host:*.google.com -action:route
/// err youtube`. Terms are ANDed; within one term commas are ORs
/// (`action:direct,system`); a leading `-` negates; `err` keeps rows with
/// errors, `open` rows with open connections; a bare word is looked for in
/// the app, the host and the matched rule text.
class TrafficQuery {
  TrafficQuery._(this.text, this._terms);

  final String text;
  final List<_Term> _terms;

  bool get isEmpty => _terms.isEmpty;

  static final empty = TrafficQuery._('', const []);

  factory TrafficQuery.parse(String text) {
    final terms = <_Term>[];
    for (var word in text.trim().split(RegExp(r'\s+'))) {
      if (word.isEmpty) continue;
      var negate = false;
      if (word.startsWith('-') && word.length > 1) {
        negate = true;
        word = word.substring(1);
      }
      final lower = word.toLowerCase();
      if (lower == 'err' || lower == 'errors') {
        terms.add(_Term(null, const [], negate, errors: true));
        continue;
      }
      if (lower == 'open') {
        terms.add(_Term(null, const [], negate, open: true));
        continue;
      }
      final colon = word.indexOf(':');
      final dim = colon > 0 ? TrafficDim.byKey(lower.substring(0, colon)) : null;
      if (dim != null) {
        final values = lower.substring(colon + 1).split(',').where((v) => v.isNotEmpty).toList();
        if (values.isNotEmpty) terms.add(_Term(dim, values, negate));
      } else {
        terms.add(_Term(null, [lower], negate));
      }
    }
    return TrafficQuery._(text, terms);
  }

  /// [names] turns route and rule ids into what the user sees, so
  /// `route:home` finds the route by its name.
  bool matches(TrafficRow r, {String Function(TrafficDim, String)? names}) {
    for (final t in _terms) {
      if (t.matches(r, names) == t.negate) return false;
    }
    return true;
  }

  /// This query with [dim] set to [value], or that term dropped when it is
  /// there already: what a click on a facet does.
  TrafficQuery toggle(TrafficDim dim, String value) {
    final word = '${dim.key}:${value.contains(' ') ? value.replaceAll(' ', '') : value}';
    final words = text.trim().split(RegExp(r'\s+')).where((w) => w.isNotEmpty).toList();
    final at = words.indexWhere((w) => w.toLowerCase() == word.toLowerCase());
    if (at >= 0) {
      words.removeAt(at);
    } else {
      words.add(word);
    }
    return TrafficQuery.parse(words.join(' '));
  }

  bool has(TrafficDim dim, String value) =>
      _terms.any((t) => t.dim == dim && !t.negate && t.values.contains(value.toLowerCase()));
}

class _Term {
  const _Term(this.dim, this.values, this.negate, {this.errors = false, this.open = false});

  final TrafficDim? dim;
  final List<String> values;
  final bool negate;
  final bool errors;
  final bool open;

  bool matches(TrafficRow r, String Function(TrafficDim, String)? names) {
    if (errors) return r.errors > 0;
    if (open) return r.open > 0;
    final dim = this.dim;
    if (dim == null) {
      final v = values.single;
      return r.app.toLowerCase().contains(v) ||
          r.host.toLowerCase().contains(v) ||
          (r.matched ?? '').toLowerCase().contains(v);
    }
    final raw = r.value(dim);
    final shown = names?.call(dim, raw) ?? raw;
    return values.any((v) => _like(raw.toLowerCase(), v) || _like(shown.toLowerCase(), v));
  }

  /// `*.google.com` is a suffix, `api*` a prefix, anything else a part.
  static bool _like(String s, String pattern) {
    if (pattern.startsWith('*') && pattern.length > 1) return s.endsWith(pattern.substring(1));
    if (pattern.endsWith('*') && pattern.length > 1) return s.startsWith(pattern.substring(0, pattern.length - 1));
    return s.contains(pattern);
  }
}

/// What a table is sorted by.
enum TrafficSort { bytes, sent, received, rate, conns, errors, last, name }

/// One line of the grouped table: a value of one dimension and everything
/// under it.
class TrafficGroup {
  TrafficGroup(this.dim, this.value, this.rows, this.path) : totals = TrafficTotals.of(rows);

  final TrafficDim dim;
  final String value;
  final List<TrafficRow> rows;
  final TrafficTotals totals;

  /// The values above this one and this one: what selecting it filters to.
  final List<(TrafficDim, String)> path;

  int get depth => path.length - 1;
}

/// Groups rows by [dim] and sorts the groups.
class GroupTraffic {
  const GroupTraffic();

  List<TrafficGroup> call(
    List<TrafficRow> rows,
    TrafficDim dim, {
    TrafficSort sort = TrafficSort.bytes,
    List<(TrafficDim, String)> parent = const [],
  }) {
    final by = <String, List<TrafficRow>>{};
    for (final r in rows) {
      by.putIfAbsent(r.value(dim), () => []).add(r);
    }
    final groups = [
      for (final MapEntry(:key, :value) in by.entries) TrafficGroup(dim, key, value, [...parent, (dim, key)]),
    ];
    int metric(TrafficGroup g) => switch (sort) {
          TrafficSort.bytes => g.totals.bytes,
          TrafficSort.sent => g.totals.upload,
          TrafficSort.received => g.totals.download,
          TrafficSort.rate => g.totals.rate.round(),
          TrafficSort.conns => g.totals.conns,
          TrafficSort.errors => g.totals.errors,
          TrafficSort.last => g.totals.last.millisecondsSinceEpoch,
          TrafficSort.name => 0,
        };
    groups.sort((a, b) => sort == TrafficSort.name
        ? a.value.toLowerCase().compareTo(b.value.toLowerCase())
        : metric(b).compareTo(metric(a)));
    return groups;
  }
}
