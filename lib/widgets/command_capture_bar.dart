import 'package:flutter/material.dart';

/// Multiline drafting composer; glow uses [accentColor] when [focusNode] has focus.
class CommandCaptureBar extends StatefulWidget {
  const CommandCaptureBar({
    super.key,
    required this.controller,
    required this.focusNode,
    required this.accentColor,
  });

  final TextEditingController controller;
  final FocusNode focusNode;
  final Color accentColor;

  @override
  State<CommandCaptureBar> createState() => _CommandCaptureBarState();
}

class _CommandCaptureBarState extends State<CommandCaptureBar> {
  static const _mono = TextStyle(fontFamily: 'monospace', fontSize: 15, height: 1.4);

  @override
  void initState() {
    super.initState();
    widget.focusNode.addListener(_onFocusChange);
  }

  @override
  void didUpdateWidget(covariant CommandCaptureBar oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.focusNode != widget.focusNode) {
      oldWidget.focusNode.removeListener(_onFocusChange);
      widget.focusNode.addListener(_onFocusChange);
    }
  }

  @override
  void dispose() {
    widget.focusNode.removeListener(_onFocusChange);
    super.dispose();
  }

  void _onFocusChange() => setState(() {});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final focused = widget.focusNode.hasFocus;
    final glow = focused
        ? [
            BoxShadow(
              color: widget.accentColor.withValues(alpha: 0.35),
              blurRadius: 20,
              spreadRadius: 0,
            ),
            BoxShadow(
              color: widget.accentColor.withValues(alpha: 0.12),
              blurRadius: 40,
              spreadRadius: 2,
            ),
          ]
        : <BoxShadow>[];

    return AnimatedContainer(
      duration: const Duration(milliseconds: 180),
      curve: Curves.easeOutCubic,
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHigh.withValues(alpha: 0.45),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: focused
              ? widget.accentColor.withValues(alpha: 0.55)
              : scheme.outline.withValues(alpha: 0.35),
          width: focused ? 1.5 : 1,
        ),
        boxShadow: glow,
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Icon(Icons.chevron_right, color: widget.accentColor, size: 22),
            ),
            Expanded(
              child: TextField(
                controller: widget.controller,
                focusNode: widget.focusNode,
                style: _mono.copyWith(color: scheme.onSurface),
                minLines: 5,
                maxLines: 10,
                textInputAction: TextInputAction.newline,
                decoration: InputDecoration(
                  isDense: true,
                  hintText:
                      'Draft a commitment… Enter to send · Shift+Enter newline',
                  hintStyle: _mono.copyWith(
                    color: scheme.onSurfaceVariant.withValues(alpha: 0.75),
                    height: 1.35,
                  ),
                  border: InputBorder.none,
                  contentPadding: const EdgeInsets.fromLTRB(8, 6, 8, 8),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
