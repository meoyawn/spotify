import 'package:flutter/gestures.dart' show DragStartBehavior;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

typedef SidebarWidthRange = ({double min, double max});

/// The original library has separate collapsed, default and expanded ranges.
/// Keep gaps between those ranges, including directional keyboard snapping.
double snapSidebarWidth(double requested, List<SidebarWidthRange> ranges, {int direction = 0}) {
  for (final range in ranges) {
    if (requested >= range.min && requested <= range.max) return requested.truncateToDouble();
  }
  if (requested <= ranges.first.min) return ranges.first.min;
  if (requested >= ranges.last.max) return ranges.last.max;
  for (var index = 1; index < ranges.length; index++) {
    final lower = ranges[index - 1].max, upper = ranges[index].min;
    if (requested > lower && requested < upper) {
      if (direction > 0) return snapSidebarWidth((upper / 10).ceilToDouble() * 10, ranges);
      if (direction < 0) return snapSidebarWidth((lower / 10).floorToDouble() * 10, ranges);
      return requested - lower <= upper - requested ? lower : upper;
    }
  }
  return ranges.first.min;
}

class SidebarResizeHandle extends StatefulWidget {
  const SidebarResizeHandle({super.key, required this.label, required this.width,
    required this.ranges, required this.growsRight, required this.onResize,
    required this.onDragState, required this.onResizeEnd});
  final String label;
  final double width;
  final List<SidebarWidthRange> ranges;
  final bool growsRight;
  final ValueChanged<double> onResize;
  final ValueChanged<bool> onDragState;
  final VoidCallback onResizeEnd;

  @override State<SidebarResizeHandle> createState() => _SidebarResizeHandleState();
}

class _SidebarResizeHandleState extends State<SidebarResizeHandle> {
  bool _hover = false, _focus = false, _dragging = false;
  double _originX = 0, _originWidth = 0;
  bool get _enabled => widget.ranges.first.min != widget.ranges.last.max;

  void _resize(double value, {int direction = 0}) {
    widget.onResize(snapSidebarWidth(value, widget.ranges, direction: direction));
  }

  void _step(double amount) {
    _resize(widget.width + amount, direction: amount.sign.toInt());
    widget.onResizeEnd();
  }

  void _finish() {
    if (!_dragging) return;
    setState(() => _dragging = false);
    widget.onDragState(false);
    widget.onResizeEnd();
  }

  void _doubleClick() {
    final maximum = widget.ranges.indexWhere((range) => widget.width == range.max);
    if (maximum >= 0) {
      if (maximum + 1 < widget.ranges.length) {
        _resize(widget.ranges[maximum + 1].min); widget.onResizeEnd();
      }
      return;
    }
    final minimum = widget.ranges.indexWhere((range) => widget.width == range.min);
    if (minimum > 0) {
      _resize(widget.ranges[minimum - 1].max); widget.onResizeEnd();
    }
  }

  @override Widget build(BuildContext context) => Semantics(
    label: widget.label, value: '${widget.width.round()} pixels',
    onIncrease: _enabled ? () => _step(10) : null,
    onDecrease: _enabled ? () => _step(-10) : null,
    child: FocusableActionDetector(enabled: _enabled,
      mouseCursor: _enabled ? SystemMouseCursors.resizeColumn : SystemMouseCursors.basic,
      shortcuts: {
        const SingleActivator(LogicalKeyboardKey.arrowLeft):
          _ResizeSidebarIntent(widget.growsRight ? -10 : 10),
        const SingleActivator(LogicalKeyboardKey.arrowRight):
          _ResizeSidebarIntent(widget.growsRight ? 10 : -10),
      }, actions: <Type, Action<Intent>>{
        _ResizeSidebarIntent: CallbackAction<_ResizeSidebarIntent>(onInvoke: (intent) {
          _step(intent.amount); return null;
        }),
      },
      onShowFocusHighlight: (value) => setState(() => _focus = value),
      onShowHoverHighlight: (value) => setState(() => _hover = value),
      child: GestureDetector(behavior: HitTestBehavior.opaque,
        dragStartBehavior: DragStartBehavior.down,
        onHorizontalDragStart: !_enabled ? null : (details) {
          _originX = details.globalPosition.dx; _originWidth = widget.width;
          setState(() => _dragging = true);
          widget.onDragState(true);
        },
        onHorizontalDragUpdate: !_enabled ? null : (details) => _resize(
          _originWidth + (details.globalPosition.dx - _originX) * (widget.growsRight ? 1 : -1)),
        onHorizontalDragEnd: !_enabled ? null : (_) => _finish(),
        onHorizontalDragCancel: !_enabled ? null : _finish,
        onDoubleTap: !_enabled ? null : _doubleClick,
        child: SizedBox(width: 8, child: Padding(padding: const EdgeInsets.symmetric(vertical: 8),
          child: Center(child: AnimatedContainer(duration: const Duration(milliseconds: 150),
            width: 1, height: double.infinity,
            color: !_enabled || !(_hover || _focus || _dragging) ? Colors.transparent
              : _dragging ? Colors.white : const Color(0xff7c7c7c))))),
      ),
    ),
  );
}

class _ResizeSidebarIntent extends Intent {
  const _ResizeSidebarIntent(this.amount);
  final double amount;
}
