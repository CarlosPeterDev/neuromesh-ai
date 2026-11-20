import 'package:flutter/material.dart';

/// Places a jump button over the scrollable area, above any composer or tab bar.
class ScrollToEnd extends StatefulWidget {
  const ScrollToEnd({
    super.key,
    required this.child,
    required this.label,
    this.controller,
    this.onJump,
    this.toStart = false,
  });

  final Widget child;
  final String label;
  final ScrollController? controller;
  final VoidCallback? onJump;
  final bool toStart;

  @override
  State<ScrollToEnd> createState() => _ScrollToEndState();
}

class _ScrollToEndState extends State<ScrollToEnd> {
  ScrollPosition? _position;
  bool _show = false;
  bool _updateScheduled = false;

  void _observe(BuildContext? scrollContext, ScrollMetrics metrics, int depth) {
    if (scrollContext == null || depth != 0 || metrics.axis != Axis.vertical)
      return;
    _position = Scrollable.maybeOf(scrollContext)?.position;
    if (_updateScheduled) return;
    _updateScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _updateScheduled = false;
      if (!mounted) return;
      final position = _attached;
      final show = position != null &&
          position.hasContentDimensions &&
          _remaining(position) > 180;
      if (show != _show) setState(() => _show = show);
    });
  }

  ScrollPosition? get _attached {
    final controller = widget.controller;
    if (controller != null)
      return controller.hasClients ? controller.position : null;
    return _position;
  }

  double _remaining(ScrollPosition position) =>
      widget.toStart ? position.extentBefore : position.extentAfter;

  Future<void> _jump() async {
    widget.onJump?.call();
    final position = _attached;
    if (position == null) return;
    // A lazy list can revise the end estimate as it lays out more items.
    for (var attempt = 0; mounted && attempt < 4; attempt++) {
      if (_attached != position ||
          !position.hasContentDimensions ||
          _remaining(position) <= 1) return;
      final end =
          widget.toStart ? position.minScrollExtent : position.maxScrollExtent;
      await position.animateTo(end,
          duration: Duration(milliseconds: attempt == 0 ? 240 : 100),
          curve: Curves.easeOutCubic);
      if (!mounted ||
          _attached != position ||
          (position.pixels - end).abs() > 1) return;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        NotificationListener<ScrollMetricsNotification>(
          onNotification: (event) {
            _observe(event.context, event.metrics, event.depth);
            return false;
          },
          child: NotificationListener<ScrollNotification>(
            onNotification: (event) {
              _observe(event.context, event.metrics, event.depth);
              return false;
            },
            child: widget.child,
          ),
        ),
        if (_show)
          Positioned(
            bottom: 12,
            right: 16,
            child: FloatingActionButton.small(
              heroTag: null,
              tooltip: widget.label,
              onPressed: _jump,
              child: Icon(widget.toStart
                  ? Icons.keyboard_arrow_up_rounded
                  : Icons.keyboard_arrow_down_rounded),
            ),
          ),
      ],
    );
  }
}
