import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../theme/app_theme.dart';

/// A D-pad friendly tappable surface.
///
/// Material's ink ripple communicates nothing from across a room, so focus is
/// expressed as a bright ring, a soft glow and a slight scale-up instead. The
/// ring is painted at a constant width and only changes colour, so gaining
/// focus never reflows the layout around it.
///
/// Still handles taps, so the same widget serves the handheld shell.
class TvFocusable extends StatefulWidget {
  const TvFocusable({
    super.key,
    required this.child,
    this.onPressed,
    this.autofocus = false,
    this.focusNode,
    this.enabled = true,
    this.borderRadius = const BorderRadius.all(Radius.circular(16)),
    this.scale = AppFocus.scale,
    this.padding = EdgeInsets.zero,
    this.onFocusChange,
  });

  final Widget child;
  final VoidCallback? onPressed;
  final bool autofocus;
  final FocusNode? focusNode;
  final bool enabled;
  final BorderRadius borderRadius;
  final double scale;
  final EdgeInsetsGeometry padding;
  final ValueChanged<bool>? onFocusChange;

  @override
  State<TvFocusable> createState() => _TvFocusableState();
}

class _TvFocusableState extends State<TvFocusable> {
  bool _focused = false;

  /// TV remotes deliver the centre button as [LogicalKeyboardKey.select],
  /// which Flutter's default activation shortcuts (enter/space) do not cover.
  static const Map<ShortcutActivator, Intent> _dpadShortcuts = {
    SingleActivator(LogicalKeyboardKey.select): ActivateIntent(),
  };

  void _activate() {
    if (!widget.enabled) return;
    widget.onPressed?.call();
  }

  void _onHighlight(bool value) {
    if (value == _focused) return;
    setState(() => _focused = value);
    widget.onFocusChange?.call(value);
  }

  @override
  Widget build(BuildContext context) {
    return FocusableActionDetector(
      enabled: widget.enabled,
      autofocus: widget.autofocus,
      focusNode: widget.focusNode,
      shortcuts: _dpadShortcuts,
      actions: <Type, Action<Intent>>{
        ActivateIntent: CallbackAction<ActivateIntent>(
          onInvoke: (_) {
            _activate();
            return null;
          },
        ),
      },
      mouseCursor: SystemMouseCursors.click,
      onShowFocusHighlight: _onHighlight,
      child: GestureDetector(
        onTap: _activate,
        behavior: HitTestBehavior.opaque,
        child: AnimatedScale(
          scale: _focused ? widget.scale : 1,
          duration: AppFocus.duration,
          curve: AppFocus.curve,
          child: AnimatedContainer(
            duration: AppFocus.duration,
            curve: AppFocus.curve,
            padding: widget.padding,
            decoration: BoxDecoration(
              borderRadius: widget.borderRadius,
              border: Border.all(
                color: _focused ? AppFocus.ring : Colors.transparent,
                width: AppFocus.ringWidth,
              ),
              boxShadow: _focused
                  ? [
                      BoxShadow(
                        color: AppFocus.ring.withValues(alpha: 0.35),
                        blurRadius: 24,
                        spreadRadius: 1,
                      ),
                    ]
                  : const [],
            ),
            child: widget.child,
          ),
        ),
      ),
    );
  }
}
