import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// A remote key sized for a thumb.
///
/// Icon buttons are laid out for a mouse pointer; on a remote every press
/// happens without looking at the screen, so the targets are large, spaced,
/// and confirm themselves with a tick of haptic feedback.
///
/// Holding repeats, which is what makes volume and arrows usable — pressing
/// eleven times to cross a menu is not.
class RemoteKey extends StatefulWidget {
  const RemoteKey({
    super.key,
    required this.onPressed,
    this.icon,
    this.label,
    this.size = 68,
    this.filled = false,
    this.repeats = true,
    this.enabled = true,
  });

  final VoidCallback? onPressed;
  final IconData? icon;
  final String? label;
  final double size;
  final bool filled;
  final bool repeats;
  final bool enabled;

  @override
  State<RemoteKey> createState() => _RemoteKeyState();
}

class _RemoteKeyState extends State<RemoteKey> {
  static const _firstRepeat = Duration(milliseconds: 400);
  static const _thenEvery = Duration(milliseconds: 130);

  Timer? _delay;
  Timer? _repeat;
  bool _down = false;

  bool get _live => widget.enabled && widget.onPressed != null;

  @override
  void dispose() {
    _delay?.cancel();
    _repeat?.cancel();
    super.dispose();
  }

  void _fire() {
    HapticFeedback.selectionClick();
    widget.onPressed?.call();
  }

  void _onDown() {
    if (!_live) return;
    setState(() => _down = true);
    _fire();
    if (!widget.repeats) return;
    _delay = Timer(_firstRepeat, () {
      _repeat = Timer.periodic(_thenEvery, (_) => _fire());
    });
  }

  void _onUp() {
    _delay?.cancel();
    _repeat?.cancel();
    if (mounted && _down) setState(() => _down = false);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final background = widget.filled
        ? scheme.primary
        : scheme.surfaceContainerHighest.withValues(alpha: _down ? 0.9 : 0.5);
    final foreground = widget.filled
        ? scheme.onPrimary
        : (_live ? scheme.onSurface : scheme.onSurfaceVariant.withValues(alpha: 0.4));

    return GestureDetector(
      onTapDown: (_) => _onDown(),
      onTapUp: (_) => _onUp(),
      onTapCancel: _onUp,
      behavior: HitTestBehavior.opaque,
      child: AnimatedScale(
        scale: _down ? 0.92 : 1,
        duration: const Duration(milliseconds: 80),
        child: Container(
          width: widget.size,
          height: widget.size,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: background,
            shape: BoxShape.circle,
          ),
          child: widget.icon != null
              ? Icon(widget.icon, color: foreground, size: widget.size * 0.42)
              : Text(
                  widget.label ?? '',
                  style: TextStyle(
                    color: foreground,
                    fontSize: widget.size * 0.26,
                    fontWeight: FontWeight.w600,
                  ),
                ),
        ),
      ),
    );
  }
}

/// The directional cross, laid out so the centre is reachable by thumb and the
/// arrows are far enough apart to hit blind.
///
/// Back and home sit in the bottom row, flanking the down arrow: they are
/// pressed as often as the arrows are, and putting them in the cross keeps the
/// thumb in one place instead of travelling to a separate strip.
class DirectionPad extends StatelessWidget {
  const DirectionPad({
    super.key,
    required this.onUp,
    required this.onDown,
    required this.onLeft,
    required this.onRight,
    required this.onSelect,
    required this.onBack,
    required this.onHome,
    this.enabled = true,
  });

  final VoidCallback onUp;
  final VoidCallback onDown;
  final VoidCallback onLeft;
  final VoidCallback onRight;
  final VoidCallback onSelect;
  final VoidCallback onBack;
  final VoidCallback onHome;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        RemoteKey(
          icon: Icons.keyboard_arrow_up,
          onPressed: onUp,
          enabled: enabled,
        ),
        const SizedBox(height: 10),
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            RemoteKey(
              icon: Icons.keyboard_arrow_left,
              onPressed: onLeft,
              enabled: enabled,
            ),
            const SizedBox(width: 14),
            RemoteKey(
              label: 'OK',
              onPressed: onSelect,
              filled: true,
              repeats: false,
              size: 78,
              enabled: enabled,
            ),
            const SizedBox(width: 14),
            RemoteKey(
              icon: Icons.keyboard_arrow_right,
              onPressed: onRight,
              enabled: enabled,
            ),
          ],
        ),
        const SizedBox(height: 10),
        // The 19pt gaps line back, down and home up with left, OK and right:
        // three 68s plus two 19s is the same 242 as the row above.
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            RemoteKey(
              icon: Icons.arrow_back,
              onPressed: onBack,
              enabled: enabled,
            ),
            const SizedBox(width: 19),
            RemoteKey(
              icon: Icons.keyboard_arrow_down,
              onPressed: onDown,
              enabled: enabled,
            ),
            const SizedBox(width: 19),
            RemoteKey(
              icon: Icons.home_outlined,
              onPressed: onHome,
              repeats: false,
              enabled: enabled,
            ),
          ],
        ),
      ],
    );
  }
}
