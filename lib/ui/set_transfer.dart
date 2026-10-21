import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import 'common/widgets.dart';

/// Saves [text] as [fileName] or copies it, as the user picks.
Future<void> exportText(BuildContext context, {required String fileName, required String text}) async {
  final choice = await showModalBottomSheet<String>(
    context: context,
    builder: (ctx) => SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          ListTile(
            leading: const Icon(Icons.save_alt),
            title: Text(Platform.isMacOS ? 'Save to a file…' : 'Share as a file…'),
            onTap: () => Navigator.pop(ctx, 'file'),
          ),
          ListTile(
            leading: const Icon(Icons.copy),
            title: const Text('Copy as text'),
            onTap: () => Navigator.pop(ctx, 'copy'),
          ),
        ],
      ),
    ),
  );
  try {
    switch (choice) {
      case 'copy':
        await Clipboard.setData(ClipboardData(text: text));
        if (context.mounted) showToast(context, 'Copied.');
      case 'file' when Platform.isMacOS || Platform.isLinux || Platform.isWindows:
        final location = await getSaveLocation(suggestedName: fileName);
        if (location == null) return;
        await File(location.path).writeAsString(text);
        if (context.mounted) showToast(context, 'Saved to ${location.path}.');
      case 'file':
        final dir = await getTemporaryDirectory();
        final file = File('${dir.path}/$fileName');
        await file.writeAsString(text);
        await SharePlus.instance.share(ShareParams(files: [XFile(file.path)]));
    }
  } catch (e) {
    if (context.mounted) showToast(context, 'Export failed: $e', error: true);
  }
}

/// Reads text from a file or from the clipboard, as the user picks. Null
/// when they cancel.
Future<String?> importText(BuildContext context) async {
  final choice = await showModalBottomSheet<String>(
    context: context,
    builder: (ctx) => SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          ListTile(
            leading: const Icon(Icons.file_open_outlined),
            title: const Text('Open a file…'),
            onTap: () => Navigator.pop(ctx, 'file'),
          ),
          ListTile(
            leading: const Icon(Icons.paste),
            title: const Text('Paste text'),
            onTap: () => Navigator.pop(ctx, 'paste'),
          ),
        ],
      ),
    ),
  );
  switch (choice) {
    case 'paste':
      return (await Clipboard.getData(Clipboard.kTextPlain))?.text;
    case 'file':
      // Android file managers often call a .json file something else, so
      // there it is any file; a wrong one is refused when it is read.
      final file = await openFile(
        acceptedTypeGroups: Platform.isAndroid
            ? const []
            : const [
                XTypeGroup(label: 'Vzhukh set', extensions: ['json'], uniformTypeIdentifiers: ['public.json']),
              ],
      );
      return file?.readAsString();
  }
  return null;
}
