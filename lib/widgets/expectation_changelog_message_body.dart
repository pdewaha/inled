import 'package:flutter/material.dart';
import 'package:exled/models/expectation_type.dart';
import 'package:exled/models/expectation_changelog_payload.dart';
import 'package:exled/services/expectation_chat_changelog.dart';
import 'package:exled/utils/display_date_format.dart';

/// Renders [expectation_messages.message_text] for changelog rows using [messageType] as the
/// renderer key (plain vs structured JSON).
class ExpectationChangelogMessageBody extends StatelessWidget {
  const ExpectationChangelogMessageBody({
    super.key,
    required this.messageType,
    required this.messageText,
    required this.expectationType,
    required this.theme,
    required this.scheme,
    required this.textAlign,
    this.compact = false,
  });

  final int messageType;
  final String messageText;
  final ExpectationType expectationType;
  final ThemeData theme;
  final ColorScheme scheme;
  final TextAlign textAlign;

  /// Denser line metrics (e.g. inline in expectation conversation bubbles).
  final bool compact;

  bool get _isTopic => expectationType == ExpectationType.topic;

  String get _noun => _isTopic ? 'talking point' : 'expectation';

  double get _fontSize =>
      compact ? 12.5 : (theme.textTheme.bodySmall?.fontSize ?? 13);

  double get _lineHeight => compact ? 1.28 : 1.35;

  TextStyle _mutedBody() {
    final base = theme.textTheme.bodySmall;
    return base?.copyWith(
          color: scheme.onSurfaceVariant,
          fontStyle: FontStyle.italic,
          height: _lineHeight,
          fontSize: _fontSize,
        ) ??
        TextStyle(
          color: scheme.onSurfaceVariant,
          fontStyle: FontStyle.italic,
          height: _lineHeight,
          fontSize: _fontSize,
        );
  }

  TextStyle _normalBody() {
    final base = theme.textTheme.bodySmall;
    return base?.copyWith(
          color: scheme.onSurface,
          height: _lineHeight,
          fontSize: _fontSize,
          fontWeight: FontWeight.w400,
        ) ??
        TextStyle(
          color: scheme.onSurface,
          height: _lineHeight,
          fontSize: _fontSize,
        );
  }

  TextStyle _valueAccent(TextStyle base) => base.copyWith(
        color: scheme.primary,
        fontWeight: FontWeight.w700,
        letterSpacing: compact ? 0.1 : 0.15,
      );

  Widget _rich(TextSpan span) => SelectableText.rich(
        span,
        textAlign: textAlign,
      );

  @override
  Widget build(BuildContext context) {
    if (messageText.trim().isEmpty) {
      return SelectableText(
        '(no message body)',
        textAlign: textAlign,
        style: _mutedBody(),
      );
    }

    if (messageType == kExpectationMessageTypeChangelogPlain) {
      return SelectableText(
        messageText,
        textAlign: textAlign,
        style: _normalBody(),
      );
    }

    final parsed = tryDecodeChangelogPayload(messageText);
    if (parsed == null) {
      return SelectableText(
        messageText,
        textAlign: textAlign,
        style: _normalBody(),
      );
    }

    final base = _normalBody();
    final accent = _valueAccent(base);

    final kind = '${parsed['kind'] ?? ''}'.trim();
    switch (kind) {
      case 'description':
        return _rich(
          TextSpan(
            style: base,
            children: [
              const TextSpan(text: 'Updated the '),
              TextSpan(text: 'description', style: accent),
              TextSpan(text: ' of this $_noun.', style: base),
            ],
          ),
        );
      case 'deadline':
        final locale = Localizations.localeOf(context);
        final label = (parsed['label'] as String?)?.trim() ?? '';
        final highlightRaw = label.isEmpty ? '—' : label;
        final highlight = formatDeadlineLabelForDisplay(highlightRaw, locale);
        return _rich(
          TextSpan(
            style: base,
            children: [
              const TextSpan(text: 'Changed deadline to '),
              TextSpan(text: highlight, style: accent),
              const TextSpan(text: '.'),
            ],
          ),
        );
      case 'progress':
        final p = changelogProgressPctFromJson(parsed['pct']);
        if (p == null) {
          return SelectableText(
            'Changed progress.',
            textAlign: textAlign,
            style: base,
          );
        }
        return _rich(
          TextSpan(
            style: base,
            children: [
              const TextSpan(text: 'Changed progress to '),
              TextSpan(text: '$p%', style: accent),
              const TextSpan(text: '.'),
            ],
          ),
        );
      case 'fields':
        final sl = (parsed['statusLabel'] as String?)?.trim();
        final hl = (parsed['healthLabel'] as String?)?.trim();
        final p = changelogProgressPctFromJson(parsed['progressPct']);
        final clauses = <InlineSpan>[];
        void addClause(String prefix, String value) {
          if (clauses.isNotEmpty) {
            clauses.add(TextSpan(text: ', ', style: base));
          }
          clauses.addAll([
            TextSpan(text: prefix, style: base),
            TextSpan(text: value, style: accent),
          ]);
        }
        if (sl != null && sl.isNotEmpty) addClause('status to ', sl);
        if (hl != null && hl.isNotEmpty) addClause('health to ', hl);
        if (p != null) addClause('progress to ', '$p%');
        if (clauses.isEmpty) {
          return SelectableText(
            'Updated this $_noun.',
            textAlign: textAlign,
            style: base,
          );
        }
        return _rich(
          TextSpan(
            style: base,
            children: [
              const TextSpan(text: 'Changed '),
              ...clauses,
              const TextSpan(text: '.'),
            ],
          ),
        );
      case 'visibility':
        final echo = parsed['echo'] == true;
        final word = echo ? 'shared' : 'private';
        return _rich(
          TextSpan(
            style: base,
            children: [
              const TextSpan(text: 'Set visibility to '),
              TextSpan(text: word, style: accent),
              const TextSpan(text: '.'),
            ],
          ),
        );
      case 'published':
        return _rich(
          TextSpan(
            style: base,
            children: [
              TextSpan(text: 'Published', style: accent),
              TextSpan(text: ' this $_noun.', style: base),
            ],
          ),
        );
      case 'update_requested':
        return _rich(
          TextSpan(
            style: base,
            children: [
              TextSpan(text: 'Update requested', style: accent),
              const TextSpan(
                text:
                    ' — please consider updating progress, deadline, or status.',
              ),
            ],
          ),
        );
      case 'receivers_added':
        final raw = parsed['handles'];
        final hs = <String>[];
        if (raw is List) {
          for (final e in raw) {
            if (e is String && e.trim().isNotEmpty) hs.add(e.trim());
          }
        }
        if (hs.isEmpty) {
          return SelectableText(
            'Added receiver(s).',
            textAlign: textAlign,
            style: base,
          );
        }
        final spans = <InlineSpan>[
          const TextSpan(text: 'Added '),
        ];
        for (var i = 0; i < hs.length; i++) {
          if (i > 0) {
            spans.add(TextSpan(text: ', ', style: base));
          }
          final t = hs[i].trim();
          final at = t.startsWith('@') ? t : '@$t';
          spans.add(TextSpan(text: at, style: accent));
        }
        spans.add(const TextSpan(text: '.'));
        return _rich(TextSpan(style: base, children: spans));
      default:
        final fallback = expectationChangelogActivityFeedLine(
          messageType: messageType,
          messageText: messageText,
          expectationType: expectationType,
        );
        if (fallback.trim().isEmpty) {
          return SelectableText(
            '(unrecognized activity)',
            textAlign: textAlign,
            style: _mutedBody(),
          );
        }
        return SelectableText(
          fallback,
          textAlign: textAlign,
          style: base,
        );
    }
  }
}
