import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Multiline drafting composer; glow uses [accentColor] when [focusNode] has focus.
class CommandCaptureBar extends StatefulWidget {
  const CommandCaptureBar({
    super.key,
    required this.controller,
    required this.focusNode,
    required this.accentColor,
    required this.hintText,
    this.suggestionsPanel,
    this.inlinePickActive = false,
    this.onInlinePickConfirm,
    /// When non-null and increases (Home reset), request focus after this bar is mounted.
    this.refocusRequestToken,
  });

  final TextEditingController controller;
  final FocusNode focusNode;
  final Color accentColor;
  final String hintText;
  /// Bumped by the ledger after a home composer hard-reset so the new [TextField] receives focus.
  final int? refocusRequestToken;
  /// Shown inside the card under the field (e.g. @/# chips); null hides the strip.
  final Widget? suggestionsPanel;
  /// When true, Enter is handled here so it cannot insert a newline and dismiss @/# completion.
  final bool inlinePickActive;
  final VoidCallback? onInlinePickConfirm;

  @override
  State<CommandCaptureBar> createState() => _CommandCaptureBarState();
}

class _CommandCaptureBarState extends State<CommandCaptureBar> {
  static const _mono = TextStyle(fontFamily: 'monospace', fontSize: 15, height: 1.4);

  void _scheduleCaptureRefocusIfRequested() {
    final t = widget.refocusRequestToken;
    if (t == null || t <= 0) return;
    void refocus() {
      if (!mounted) return;
      widget.focusNode.requestFocus();
    }

    WidgetsBinding.instance.addPostFrameCallback((_) {
      refocus();
      WidgetsBinding.instance.addPostFrameCallback((_) => refocus());
    });
  }

  @override
  void initState() {
    super.initState();
    widget.focusNode.addListener(_onFocusChange);
    _scheduleCaptureRefocusIfRequested();
  }

  @override
  void didUpdateWidget(covariant CommandCaptureBar oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.focusNode != widget.focusNode) {
      oldWidget.focusNode.removeListener(_onFocusChange);
      widget.focusNode.addListener(_onFocusChange);
    }
    final nt = widget.refocusRequestToken;
    final ot = oldWidget.refocusRequestToken;
    if (nt != null && nt > 0 && nt != ot) {
      _scheduleCaptureRefocusIfRequested();
    }
  }

  @override
  void dispose() {
    widget.focusNode.removeListener(_onFocusChange);
    super.dispose();
  }

  void _onFocusChange() => setState(() {});

  Widget _buildTextField(ColorScheme scheme) {
    // Always wrap with [CallbackShortcuts] so the tree shape does not flip when
    // [inlinePickActive] toggles (that swap used to drop TextField focus on the
    // first @/# character that opened multi-match mode).
    final bindings = <ShortcutActivator, VoidCallback>{};
    if (widget.inlinePickActive && widget.onInlinePickConfirm != null) {
      bindings[const SingleActivator(LogicalKeyboardKey.enter)] =
          widget.onInlinePickConfirm!;
    }
    return CallbackShortcuts(
      bindings: bindings,
      child: TextField(
        controller: widget.controller,
        focusNode: widget.focusNode,
        style: _mono.copyWith(color: scheme.onSurface),
        minLines: 5,
        maxLines: 10,
        textInputAction: TextInputAction.newline,
        decoration: InputDecoration(
          isDense: true,
          hintText: widget.hintText,
          hintStyle: _mono.copyWith(
            color: scheme.onSurfaceVariant.withValues(alpha: 0.75),
            height: 1.35,
          ),
          border: InputBorder.none,
          contentPadding: const EdgeInsets.fromLTRB(8, 6, 8, 8),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final focused = widget.focusNode.hasFocus;
    final accent = widget.accentColor;
    final indicatorColor = focused
        ? accent.withValues(alpha: 0.95)
        : scheme.onSurfaceVariant.withValues(alpha: 0.85);
    final glow = focused
        ? [
            BoxShadow(
              color: accent.withValues(alpha: 0.26),
              blurRadius: 20,
              spreadRadius: 0,
            ),
            BoxShadow(
              color: accent.withValues(alpha: 0.12),
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
              ? accent.withValues(alpha: 0.55)
              : scheme.outline.withValues(alpha: 0.35),
          width: focused ? 1.5 : 1,
        ),
        boxShadow: glow,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Icon(Icons.chevron_right, color: indicatorColor, size: 22),
                ),
                Expanded(
                  child: _buildTextField(scheme),
                ),
              ],
            ),
          ),
          // Always keep divider + scroll slot so hiding suggestions does not change
          // subtree shape (that used to drop TextField focus after Tab autocomplete).
          Divider(
            height: widget.suggestionsPanel != null ? 1 : 0,
            thickness: widget.suggestionsPanel != null ? 1 : 0,
            color: widget.suggestionsPanel != null
                ? scheme.outline.withValues(alpha: 0.22)
                : Colors.transparent,
          ),
          ConstrainedBox(
            constraints: BoxConstraints(
              maxHeight: widget.suggestionsPanel != null ? 168 : 0,
            ),
            child: SingleChildScrollView(
              child: widget.suggestionsPanel ?? const SizedBox.shrink(),
            ),
          ),
        ],
      ),
    );
  }
}
