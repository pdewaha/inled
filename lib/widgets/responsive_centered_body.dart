import 'package:flutter/material.dart';

/// Centers content on wide viewports and uses full width on narrow screens.
class ResponsiveCenteredBody extends StatelessWidget {
  const ResponsiveCenteredBody({
    super.key,
    required this.child,
    this.maxWidth = 1200,
    this.horizontalPadding,
    this.alwaysApplyMaxWidth = false,
  });

  final Widget child;
  final double maxWidth;
  final double? horizontalPadding;

  /// When true, [maxWidth] applies on narrow viewports too (e.g. command thread).
  final bool alwaysApplyMaxWidth;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final mq = MediaQuery.sizeOf(context);
        final width = constraints.hasBoundedWidth
            ? constraints.maxWidth
            : mq.width;
        final isCompact = width < 600;
        final pad = horizontalPadding ?? (isCompact ? 16.0 : 24.0);
        final cap = alwaysApplyMaxWidth || !isCompact ? maxWidth : double.infinity;
        return Align(
          alignment: Alignment.topCenter,
          child: ConstrainedBox(
            constraints: BoxConstraints(maxWidth: cap),
            child: Padding(
              padding: EdgeInsets.symmetric(horizontal: pad),
              child: child,
            ),
          ),
        );
      },
    );
  }
}
