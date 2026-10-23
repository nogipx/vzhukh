import 'routing_rule.dart';

/// One line of the rule list: a folder's heading, or a rule.
sealed class RuleEntry {
  const RuleEntry();
}

class FolderEntry extends RuleEntry {
  final RuleFolder folder;

  /// All of its rules, shown under it or not.
  final List<RoutingRule> rules;

  const FolderEntry(this.folder, this.rules);
}

class RuleLine extends RuleEntry {
  final RoutingRule rule;

  /// The folder it is shown in, null for a rule of its own.
  final RuleFolder? folder;

  const RuleLine(this.rule, [this.folder]);
}

/// Folders as blocks in the rule order. Rules are still one flat list, the
/// one matching walks; a folder is a name and a switch over a run of it.
/// Every change here ends in [normalized], so a folder's rules always
/// stand together and no folder is left empty.
extension RuleFolderOps on RoutingRules {
  /// What the list shows: each folder where its rules are, then its rules
  /// unless it is collapsed.
  List<RuleEntry> entries() {
    final out = <RuleEntry>[];
    final seen = <String>{};
    for (final rule in rules) {
      final folder = folderOf(rule);
      if (folder == null) {
        out.add(RuleLine(rule));
        continue;
      }
      if (seen.add(folder.id)) {
        out.add(FolderEntry(folder, [for (final r in rules) if (r.folderId == folder.id) r]));
      }
      if (!folder.collapsed) out.add(RuleLine(rule, folder));
    }
    return out;
  }

  /// Puts each folder's rules together where its first one stands, drops
  /// folders with no rules, and frees rules whose folder is gone.
  RoutingRules normalized() {
    final ids = {for (final f in folders) f.id};
    final fixed = [
      for (final r in rules) r.folderId != null && !ids.contains(r.folderId) ? r.copyWith(clearFolder: true) : r,
    ];
    final out = <RoutingRule>[];
    final placed = <String>{};
    for (final r in fixed) {
      final id = r.folderId;
      if (id == null) {
        out.add(r);
      } else if (placed.add(id)) {
        out.addAll(fixed.where((x) => x.folderId == id));
      }
    }
    return copyWith(rules: out, folders: [for (final f in folders) if (placed.contains(f.id)) f]);
  }

  /// A new [folder] around the rule [ruleId], where that rule stands.
  RoutingRules newFolder(String ruleId, RuleFolder folder) => copyWith(
        rules: [for (final r in rules) r.id == ruleId ? r.copyWith(folderId: folder.id) : r],
        folders: [...folders, folder],
      ).normalized();

  /// Moves the rule to the end of [folderId]'s block.
  RoutingRules moveToFolder(String ruleId, String folderId) {
    final rule = rules.where((r) => r.id == ruleId).firstOrNull;
    if (rule == null) return this;
    final list = [for (final r in rules) if (r.id != ruleId) r];
    final last = list.lastIndexWhere((r) => r.folderId == folderId);
    list.insert(last + 1, rule.copyWith(folderId: folderId));
    return copyWith(rules: list).normalized();
  }

  /// Takes the rule out of its folder and puts it just after the folder.
  RoutingRules takeOutOfFolder(String ruleId) {
    final rule = rules.where((r) => r.id == ruleId).firstOrNull;
    final folderId = rule?.folderId;
    if (rule == null || folderId == null) return this;
    final list = [for (final r in rules) if (r.id != ruleId) r];
    final last = list.lastIndexWhere((r) => r.folderId == folderId);
    list.insert(last + 1, rule.copyWith(clearFolder: true));
    return copyWith(rules: list).normalized();
  }

  RoutingRules updateFolder(RuleFolder folder) =>
      copyWith(folders: [for (final f in folders) f.id == folder.id ? folder : f]);

  /// Removes the folder and keeps its rules where they are.
  RoutingRules ungroup(String folderId) => copyWith(
        rules: [for (final r in rules) r.folderId == folderId ? r.copyWith(clearFolder: true) : r],
        folders: [for (final f in folders) if (f.id != folderId) f],
      ).normalized();

  /// Removes the folder and its rules.
  RoutingRules deleteFolder(String folderId) => copyWith(
        rules: [for (final r in rules) if (r.folderId != folderId) r],
        folders: [for (final f in folders) if (f.id != folderId) f],
      ).normalized();

  /// Moves a folder's whole block to the top or the bottom of the list.
  RoutingRules moveFolder(String folderId, {required bool toTop}) {
    final block = [for (final r in rules) if (r.folderId == folderId) r];
    final rest = [for (final r in rules) if (r.folderId != folderId) r];
    return copyWith(rules: toTop ? [...block, ...rest] : [...rest, ...block]).normalized();
  }

  /// A drag in the list: the entry at [from] of [entries] lands at [to],
  /// counted once it has been taken out. A folder takes its rules along.
  /// A rule joins the folder of whatever it lands after: the folder's
  /// heading or one of its rules; anywhere else it stands on its own.
  RoutingRules reorder(int from, int to) {
    final list = [...entries()];
    if (from < 0 || from >= list.length) return this;
    final moved = list.removeAt(from);
    final carried = <RuleEntry>[];
    if (moved is FolderEntry) {
      while (from < list.length) {
        final next = list[from];
        if (next is! RuleLine || next.folder?.id != moved.folder.id) break;
        carried.add(list.removeAt(from));
      }
      // Dropped among its own rules it stays; past them, they no longer
      // count.
      if (to > from + carried.length) {
        to -= carried.length;
      } else if (to > from) {
        to = from;
      }
    }
    list.insertAll(to.clamp(0, list.length), [moved, ...carried]);

    final out = <RoutingRule>[];
    String? context;
    for (final e in list) {
      switch (e) {
        case FolderEntry(:final folder, rules: final members):
          if (folder.collapsed) {
            out.addAll(members);
            context = null;
          } else {
            context = folder.id;
          }
        case RuleLine(:final rule) when identical(e, moved):
          out.add(context == null ? rule.copyWith(clearFolder: true) : rule.copyWith(folderId: context));
        case RuleLine(:final rule):
          out.add(rule);
          context = rule.folderId;
      }
    }
    return copyWith(rules: out).normalized();
  }
}
