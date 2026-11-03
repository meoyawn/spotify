import 'package:flutter/material.dart';

/// A flat desktop control: hover/focus feedback without a per-button Material
/// theme, ink renderer or animated physical shape in every recycled list row.
class DesktopIconButton extends StatefulWidget {
  const DesktopIconButton({super.key, required this.tooltip, required this.icon,
    this.onPressed, this.color = const Color(0xffb3b3b3), this.size = 32,
    this.padding = const EdgeInsets.all(6), this.backgroundColor,
    this.disabledColor = const Color(0xff4d4d4d)});
  final String tooltip;
  final Widget icon;
  final VoidCallback? onPressed;
  final Color color;
  final double size;
  final EdgeInsetsGeometry padding;
  final Color? backgroundColor;
  final Color disabledColor;

  @override State<DesktopIconButton> createState() => _DesktopIconButtonState();
}

class _DesktopIconButtonState extends State<DesktopIconButton> {
  bool _hovered = false, _focused = false;

  @override Widget build(BuildContext context) {
    final enabled = widget.onPressed != null;
    return Tooltip(message: widget.tooltip, excludeFromSemantics: true,
      child: Semantics(button: true, enabled: enabled, label: widget.tooltip,
        child: FocusableActionDetector(enabled: enabled,
          mouseCursor: enabled ? SystemMouseCursors.click : SystemMouseCursors.basic,
          onShowHoverHighlight: (value) => setState(() => _hovered = value),
          onShowFocusHighlight: (value) => setState(() => _focused = value),
          actions: {ActivateIntent: CallbackAction<ActivateIntent>(onInvoke: (_) {
            widget.onPressed?.call();
            return null;
          })},
          child: GestureDetector(behavior: HitTestBehavior.opaque, onTap: widget.onPressed,
            child: Container(width: widget.size, height: widget.size,
              alignment: Alignment.center, padding: widget.padding,
              decoration: BoxDecoration(shape: BoxShape.circle,
                color: enabled && _hovered
                  ? widget.backgroundColor == null ? const Color(0xff2a2a2a)
                    : Color.lerp(widget.backgroundColor, Colors.white, 0.12)
                  : widget.backgroundColor ?? Colors.transparent,
                border: _focused ? Border.all(color: Colors.white) : null),
              child: IconTheme.merge(data: IconThemeData(color: enabled ? widget.color : widget.disabledColor),
                child: widget.icon))))));
  }
}
