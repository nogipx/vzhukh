import 'dart:io' show InternetAddress, InternetAddressType;

import 'package:xml/xml.dart';

import '../models/routing_rule.dart';
import '../models/rule_set.dart';

/// A rule set made from a Proxifier profile, and what of the profile it
/// could not carry over.
class ProxifierImport {
  final RuleSet set;

  /// One line per entry or rule left out, for the user to look through.
  final List<String> skipped;

  const ProxifierImport({required this.set, required this.skipped});
}

/// Turns a Proxifier profile (.ppx) into one rule set.
///
/// Rules keep their order, names and on/off state. Every proxy and chain
/// becomes the route Connect was pressed on: the profile's proxies are
/// addresses vzhukh knows nothing about. The criterion-less rule Proxifier
/// keeps last, "Default", becomes the set's default.
///
/// Matching is close to Proxifier's, not equal: "example.com" here also
/// covers the names under it, so "example.com; *.example.com" is one entry.
/// What vzhukh cannot match on (bundle ids, wildcards inside a name, the
/// %Macros%) is left out. A rule that loses a whole criterion that way is
/// left out with it, rather than matching more than it did.
class ImportProxifierProfile {
  const ImportProxifierProfile();

  /// Throws [FormatException] when [text] is not a Proxifier profile.
  ProxifierImport call(String text, {required String id, required String name}) {
    final XmlElement root;
    try {
      root = XmlDocument.parse(text).rootElement;
    } on XmlException {
      throw const FormatException('Not a Proxifier profile');
    }
    if (root.name.local != 'ProxifierProfile') {
      throw const FormatException('Not a Proxifier profile');
    }

    final skipped = <String>[];
    final rules = <RoutingRule>[];
    var defaultAction = const RoutingRules().defaultAction;
    final elements = root.getElement('RuleList')?.findElements('Rule').toList() ?? const [];

    for (final (i, e) in elements.indexed) {
      final ruleName = e.getElement('Name')?.innerText.trim() ?? '';
      final label = ruleName.isEmpty ? 'Rule ${i + 1}' : ruleName;
      final type = e.getElement('Action')?.getAttribute('type');
      final action = switch (type) {
        'Direct' => RuleAction.direct,
        'Block' => RuleAction.block,
        'Proxy' || 'Chain' => RuleAction.connectedRoute,
        _ => null,
      };
      if (action == null) {
        skipped.add('$label: action "$type"');
        continue;
      }

      final rawApps = _entries(e, 'Applications');
      final rawTargets = _entries(e, 'Targets');
      final rawPorts = _entries(e, 'Ports');
      final enabled = e.getAttribute('enabled') != 'false';

      final isDefault = i == elements.length - 1 &&
          rawApps.isEmpty &&
          rawTargets.isEmpty &&
          rawPorts.isEmpty &&
          enabled &&
          action != RuleAction.block;
      if (isDefault) {
        defaultAction =
            action == RuleAction.direct ? DefaultAction.direct : DefaultAction.connectedRoute;
        continue;
      }

      final lost = <String>[];
      final apps = _apps(rawApps, lost);
      final destinations = _targets(rawTargets, lost);
      final ports = _ports(rawPorts, lost);
      skipped.addAll(lost.map((entry) => '$label: $entry'));

      if (rawApps.isNotEmpty && apps.isEmpty ||
          rawTargets.isNotEmpty && destinations.domains.isEmpty && destinations.cidrs.isEmpty ||
          rawPorts.isNotEmpty && ports.isEmpty) {
        skipped.add('$label: the whole rule, nothing left to match on');
        continue;
      }

      rules.add(RoutingRule(
        id: '${id}_$i',
        name: ruleName,
        apps: apps,
        domains: destinations.domains,
        cidrs: destinations.cidrs,
        ports: ports,
        action: action,
        enabled: enabled,
      ));
    }

    return ProxifierImport(
      set: RuleSet(id: id, name: name, rules: RoutingRules(rules: rules, defaultAction: defaultAction)),
      skipped: skipped,
    );
  }

  static List<String> _entries(XmlElement rule, String tag) => [
        for (final entry in (rule.getElement(tag)?.innerText ?? '').split(RegExp(r'[;,\n]')))
          if (entry.trim().isNotEmpty) entry.trim(),
      ];

  static final _bundleId = RegExp(r'^[A-Za-z0-9-]+(\.[A-Za-z0-9-]+){2,}$');

  /// "Claude.app" and "Claude" are the same app to the daemon, which knows
  /// a bundle by its name. Proxifier lists an app's bundle id next to its
  /// name, so a bundle id is only worth reporting when it was all there was.
  static List<String> _apps(List<String> raw, List<String> lost) {
    final out = <String>[];
    final bundleIds = <String>[];
    for (var app in raw) {
      app = app.replaceAll('"', '').trim();
      if (!app.startsWith('/')) app = app.replaceFirst(RegExp(r'\.app$', caseSensitive: false), '');
      if (app.contains('*') || app.contains('?')) {
        lost.add('app "$app", wildcards are not supported');
      } else if (!app.startsWith('/') && _bundleId.hasMatch(app)) {
        bundleIds.add('app "$app", bundle ids are not supported');
      } else if (app.isNotEmpty && !out.any((a) => a.toLowerCase() == app.toLowerCase())) {
        out.add(app);
      }
    }
    if (out.isEmpty) lost.addAll(bundleIds);
    return out;
  }

  static final _domain = RegExp(r'^[a-z0-9_-]+(\.[a-z0-9_-]+)*$');

  static ({List<String> domains, List<String> cidrs}) _targets(List<String> raw, List<String> lost) {
    final domains = <String>[];
    final cidrs = <String>[];
    void addCidr(String c) => cidrs.contains(c) ? null : cidrs.add(c);

    for (final target in raw) {
      final ip = InternetAddress.tryParse(target);
      if (ip != null) {
        addCidr(ip.address);
        continue;
      }
      final cidr = _cidr(target);
      if (cidr != null) {
        addCidr(cidr);
        continue;
      }
      final range = _range(target) ?? _ipWildcard(target);
      if (range != null) {
        range.forEach(addCidr);
        continue;
      }
      var name = target.toLowerCase();
      if (name.endsWith('.')) name = name.substring(0, name.length - 1);
      if (name.startsWith('*.')) name = name.substring(2);
      if (_domain.hasMatch(name)) {
        if (!domains.contains(name)) domains.add(name);
      } else {
        lost.add('target "$target"');
      }
    }
    return (domains: domains, cidrs: cidrs);
  }

  static String? _cidr(String target) {
    final (addr, bits) = switch (target.split('/')) {
      [final a, final b] => (InternetAddress.tryParse(a.trim()), int.tryParse(b.trim())),
      _ => (null, null),
    };
    if (addr == null || bits == null) return null;
    final max = addr.type == InternetAddressType.IPv4 ? 32 : 128;
    return bits < 0 || bits > max ? null : '${addr.address}/$bits';
  }

  /// "10.0.0.1-10.0.0.20", as the fewest prefixes that cover it.
  static List<String>? _range(String target) {
    final parts = target.split('-');
    if (parts.length != 2) return null;
    final from = _ipv4(parts[0].trim());
    final to = _ipv4(parts[1].trim());
    if (from == null || to == null || from > to) return null;
    final out = <String>[];
    var start = from;
    while (start <= to) {
      var bits = 32;
      while (bits > 0) {
        final size = 1 << (33 - bits);
        if (start % size != 0 || start + size - 1 > to) break;
        bits--;
      }
      out.add('${_ipv4Text(start)}/$bits');
      start += 1 << (32 - bits);
    }
    return out;
  }

  /// "192.168.*.*": stars only at the end, one octet each.
  static List<String>? _ipWildcard(String target) {
    final octets = target.split('.');
    if (octets.length != 4 || !octets.contains('*')) return null;
    final fixed = octets.takeWhile((o) => o != '*').toList();
    if (octets.skip(fixed.length).any((o) => o != '*')) return null;
    final base = _ipv4([...fixed, for (var i = fixed.length; i < 4; i++) '0'].join('.'));
    return base == null ? null : ['${_ipv4Text(base)}/${fixed.length * 8}'];
  }

  static int? _ipv4(String text) {
    final ip = InternetAddress.tryParse(text);
    if (ip == null || ip.type != InternetAddressType.IPv4) return null;
    return ip.rawAddress.fold<int>(0, (acc, b) => acc << 8 | b);
  }

  static String _ipv4Text(int v) => [24, 16, 8, 0].map((s) => (v >> s) & 0xff).join('.');

  static List<String> _ports(List<String> raw, List<String> lost) {
    final out = <String>[];
    for (final port in raw) {
      final spec = port.replaceAll(' ', '');
      final bounds = spec.split('-').map(int.tryParse).toList();
      final valid = bounds.length <= 2 &&
          bounds.every((p) => p != null && p >= 1 && p <= 65535) &&
          bounds.first! <= bounds.last!;
      if (valid) {
        if (!out.contains(spec)) out.add(spec);
      } else {
        lost.add('port "$port"');
      }
    }
    return out;
  }
}
