import 'package:flutter/material.dart';

import '../../ssh/invite_codec.dart';
import '../../ssh/route_invite_codec.dart';
import '../theme/app_theme.dart';
import 'tv_button.dart';

/// Unlocks a password protected payload on the television.
///
/// An invite is sealed with PBKDF2 and AES-GCM, so there is no way around
/// asking for the password. Typing on a remote is slow, so the field takes
/// focus immediately, a wrong attempt keeps what was typed, and the payload
/// comes back already decoded rather than making the caller try again.
class TvUnlockScreen extends StatefulWidget {
  const TvUnlockScreen({super.key, required this.type, required this.data});

  /// Either `invite` (a single server) or `route` (a full chain).
  final String type;
  final String data;

  @override
  State<TvUnlockScreen> createState() => _TvUnlockScreenState();
}

class _TvUnlockScreenState extends State<TvUnlockScreen> {
  final _controller = TextEditingController();

  bool _working = false;
  String? _error;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _unlock() async {
    final password = _controller.text;
    if (password.isEmpty || _working) return;

    setState(() {
      _working = true;
      _error = null;
    });

    try {
      final payload = widget.type == 'invite'
          ? _asRoute(await const InviteCodec().decodeAsync(widget.data, password))
          : await const RouteInviteCodec().decodeAsync(widget.data, password);
      if (mounted) Navigator.pop(context, payload);
    } catch (_) {
      // The codec cannot tell a wrong password from corrupt data, and for
      // somebody at a television the first is overwhelmingly likelier.
      if (mounted) {
        setState(() {
          _working = false;
          _error = 'Wrong password.';
        });
      }
    }
  }

  /// A single-server invite carries exactly the fields of one hop.
  RouteInvitePayload _asRoute(InvitePayload invite) => RouteInvitePayload(
        label: invite.nickname,
        hops: [
          RouteHopData(
            host: invite.host,
            port: invite.port,
            nickname: invite.nickname,
            username: invite.username,
            privateKeyPem: invite.privateKeyPem,
          ),
        ],
      );

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      body: Padding(
        padding: TvInsets.overscan,
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 900),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Enter the password', style: theme.textTheme.displaySmall),
                const SizedBox(height: AppSpacing.md),
                Text(
                  'This invite is encrypted. Ask whoever shared it for the '
                  'password.',
                  style: theme.textTheme.bodyLarge?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
                const SizedBox(height: AppSpacing.xl),
                TextField(
                  controller: _controller,
                  autofocus: true,
                  obscureText: true,
                  enabled: !_working,
                  style: theme.textTheme.headlineSmall,
                  textInputAction: TextInputAction.done,
                  onSubmitted: (_) => _unlock(),
                  decoration: InputDecoration(
                    labelText: 'Password',
                    errorText: _error,
                    border: const OutlineInputBorder(),
                    contentPadding: const EdgeInsets.symmetric(
                      horizontal: AppSpacing.lg,
                      vertical: AppSpacing.lg,
                    ),
                  ),
                ),
                const SizedBox(height: AppSpacing.xl),
                if (_working)
                  const CircularProgressIndicator()
                else
                  TvButton(
                    label: 'Unlock',
                    icon: Icons.lock_open,
                    onPressed: _unlock,
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
