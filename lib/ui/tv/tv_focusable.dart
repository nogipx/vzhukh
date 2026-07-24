import 'dart:async';

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
/// A remote has no second button for secondary actions, so holding the centre
/// key is the conventional way to reach them; [onLongPress] hooks into that.
/// Taps and long presses still work, so the same widget serves a touchscreen.
class TvFocusable extends StatefulWidget {
  const TvFocusable({
    super.key,
    required this.child,
    this.onPressed,
    this.onLongPress,
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
  final VoidCallback? onLongPress;
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
  static const _longPressDelay = Duration(milliseconds: 500);

  /// Keys a remote or keyboard may send for "activate". Flutter's default
  /// activation shortcuts cover enter and space but not the D-pad centre.
  static final _activationKeys = <LogicalKeyboardKey>{
    LogicalKeyboardKey.select,
    LogicalKeyboardKey.enter,
    LogicalKeyboardKey.numpadEnter,
    LogicalKeyboardKey.space,
    LogicalKeyboardKey.gameButtonA,
  };

  bool _focused = false;
  Timer? _holdTimer;
  bool _longPressFired = false;

  @override
  void dispose() {
    _holdTimer?.cancel();
    super.dispose();
  }

  void _onFocusChange(bool value) {
    if (value == _focused) return;
    setState(() => _focused = value);
    widget.onFocusChange?.call(value);
  }

  /// Distinguishes a tap from a hold by timing the key press, since the
  /// centre key reports only down and up.
  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (!widget.enabled || !_activationKeys.contains(event.logicalKey)) {
      return KeyEventResult.ignored;
    }

    if (event is KeyDownEvent) {
      _longPressFired = false;
      _holdTimer?.cancel();
      if (widget.onLongPress != null) {
        _holdTimer = Timer(_longPressDelay, () {
          _longPressFired = true;
          widget.onLongPress!.call();
        });
      }
      return KeyEventResult.handled;
    }

    if (event is KeyUpEvent) {
      _holdTimer?.cancel();
      _holdTimer = null;
      if (!_longPressFired) widget.onPressed?.call();
      _longPressFired = false;
      return KeyEventResult.handled;
    }

    // Swallow repeats so holding does not fire the action over and over.
    return KeyEventResult.handled;
  }

  @override
  Widget build(BuildContext context) {
    return Focus(
      focusNode: widget.focusNode,
      autofocus: widget.autofocus,
      canRequestFocus: widget.enabled,
      onFocusChange: _onFocusChange,
      onKeyEvent: _onKey,
      child: GestureDetector(
        onTap: widget.enabled ? widget.onPressed : null,
        onLongPress: widget.enabled ? widget.onLongPress : null,
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
