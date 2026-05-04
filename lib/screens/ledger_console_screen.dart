import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:inled/data_sources/local_ledger_data_source.dart';
import 'package:inled/models/expectation.dart';
import 'package:inled/models/feed_entry.dart';
import 'package:inled/models/goal.dart';
import 'package:inled/models/ledger_pillar.dart';
import 'package:inled/models/person.dart';
import 'package:inled/models/stakeholder.dart';
import 'package:inled/theme.dart';
import 'package:inled/utils/capture_parser.dart';
import 'package:inled/widgets/command_capture_bar.dart';
import 'package:inled/widgets/expectation_status_badge.dart';
import 'package:inled/widgets/responsive_centered_body.dart';
import 'package:inled/widgets/visibility_glyph.dart';

/// Single-column command thread with pillar sidebar and pinned composer.
class LedgerConsoleScreen extends StatefulWidget {
  const LedgerConsoleScreen({
    super.key,
    required this.onThemeVariantChanged,
  });

  final ValueChanged<AppThemeVariant> onThemeVariantChanged;

  @override
  State<LedgerConsoleScreen> createState() => _LedgerConsoleScreenState();
}

class _LedgerConsoleScreenState extends State<LedgerConsoleScreen> {
  static const _data = LocalLedgerDataSource();

  final _scaffoldKey = GlobalKey<ScaffoldState>();
  final _captureController = TextEditingController();
  final _captureFocus = FocusNode();
  final _scrollController = ScrollController();

  LedgerPillar _pillar = LedgerPillar.expectations;
  final Map<LedgerPillar, List<FeedEntry>> _userCaptures = {
    for (final p in LedgerPillar.values) p: [],
  };

  bool _keyboardHookRegistered = false;

  void _focusComposer() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        _captureFocus.requestFocus();
      }
    });
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (!_keyboardHookRegistered) {
        _keyboardHookRegistered = true;
        HardwareKeyboard.instance.addHandler(_onHardwareKey);
      }
      _captureFocus.requestFocus();
    });
  }

  @override
  void dispose() {
    if (_keyboardHookRegistered) {
      HardwareKeyboard.instance.removeHandler(_onHardwareKey);
    }
    _captureController.dispose();
    _captureFocus.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  bool _shiftDown() {
    final pressed = HardwareKeyboard.instance.logicalKeysPressed;
    return pressed.contains(LogicalKeyboardKey.shiftLeft) ||
        pressed.contains(LogicalKeyboardKey.shiftRight);
  }

  bool _onHardwareKey(KeyEvent event) {
    if (event is! KeyDownEvent) return false;
    if (!_captureFocus.hasFocus) return false;
    if (event.logicalKey == LogicalKeyboardKey.enter && !_shiftDown()) {
      _submitCapture();
      return true;
    }
    if (event.logicalKey == LogicalKeyboardKey.tab &&
        _captureController.text.isEmpty) {
      setState(() => _pillar = _pillar.next);
      return true;
    }
    return false;
  }

  void _submitCapture() {
    final text = _captureController.text.trim();
    if (text.isEmpty) return;
    final parse = parseCaptureLine(text);
    setState(() {
      _userCaptures[_pillar]!.insert(
        0,
        FeedEntry(
          id: 'cap_${DateTime.now().millisecondsSinceEpoch}',
          createdAt: DateTime.now().toUtc(),
          body: text,
          parse: parse,
          isUserCapture: true,
        ),
      );
      _captureController.clear();
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollController.hasClients) {
        _scrollController.jumpTo(0);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final stakeholders = _data.getStakeholders();
    final goals = _data.getGoals();
    final people = _data.getPeople();
    final expectations = _data.getExpectations();
    final peopleById = {for (final p in people) p.id: p};
    final goalsById = {for (final g in goals) g.id: g};

    return Scaffold(
      key: _scaffoldKey,
      backgroundColor: theme.scaffoldBackgroundColor,
      drawer: _PillarDrawer(
        selected: _pillar,
        onSelect: (p) {
          setState(() => _pillar = p);
          Navigator.of(context).pop();
          _focusComposer();
        },
      ),
      appBar: AppBar(
        leading: IconButton(
          icon: const Icon(Icons.menu),
          tooltip: 'Pillars',
          onPressed: () => _scaffoldKey.currentState?.openDrawer(),
        ),
        title: const Text('inled'),
        actions: [
          MenuAnchor(
            menuChildren: [
              for (final v in AppThemeVariant.values)
                MenuItemButton(
                  onPressed: () => widget.onThemeVariantChanged(v),
                  leadingIcon: Icon(_iconFor(v)),
                  child: Text(_labelFor(v)),
                ),
            ],
            builder: (context, controller, child) {
              return IconButton(
                tooltip: 'Theme',
                onPressed: () => controller.isOpen
                    ? controller.close()
                    : controller.open(),
                icon: const Icon(Icons.palette_outlined),
              );
            },
          ),
          const SizedBox(width: 4),
        ],
      ),
      body: SafeArea(
        child: ResponsiveCenteredBody(
          maxWidth: 800,
          alwaysApplyMaxWidth: true,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _PillarHeader(pillar: _pillar, theme: theme),
              const SizedBox(height: 12),
              CommandCaptureBar(
                controller: _captureController,
                focusNode: _captureFocus,
                accentColor: _pillar.accent,
              ),
              const SizedBox(height: 20),
              Text(
                'Recent',
                style: theme.textTheme.titleSmall?.copyWith(
                  fontWeight: FontWeight.w700,
                  color: scheme.onSurface,
                ),
              ),
              const SizedBox(height: 8),
              Expanded(
                child: ListView(
                  controller: _scrollController,
                  padding: const EdgeInsets.only(bottom: 16),
                  children: _threadChildren(
                    theme: theme,
                    scheme: scheme,
                    stakeholders: stakeholders,
                    goals: goals,
                    people: people,
                    expectations: expectations,
                    peopleById: peopleById,
                    goalsById: goalsById,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  List<Widget> _threadChildren({
    required ThemeData theme,
    required ColorScheme scheme,
    required List<Stakeholder> stakeholders,
    required List<Goal> goals,
    required List<Person> people,
    required List<Expectation> expectations,
    required Map<String, Person> peopleById,
    required Map<String, Goal> goalsById,
  }) {
    final out = <Widget>[];
    for (final e in _userCaptures[_pillar]!) {
      out.add(_UserCaptureGlassCard(entry: e, scheme: scheme, theme: theme));
    }
    switch (_pillar) {
      case LedgerPillar.stakeholders:
        for (final s in stakeholders) {
          out.add(_StakeholderGlassCard(s: s, theme: theme, scheme: scheme));
        }
        break;
      case LedgerPillar.goals:
        for (final g in goals) {
          out.add(_GoalGlassCard(g: g, theme: theme, scheme: scheme));
        }
        break;
      case LedgerPillar.expectations:
        for (final x in expectations) {
          out.add(
            _ExpectationGlassCard(
              e: x,
              theme: theme,
              scheme: scheme,
              peopleById: peopleById,
              goalsById: goalsById,
            ),
          );
        }
        break;
      case LedgerPillar.people:
        for (final p in people) {
          out.add(_PersonGlassCard(p: p, theme: theme, scheme: scheme));
        }
        break;
    }
    if (out.isEmpty) {
      out.add(
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 32),
          child: Text(
            'Nothing in this pillar yet. Capture above.',
            textAlign: TextAlign.center,
            style: theme.textTheme.bodyMedium?.copyWith(
              color: scheme.onSurfaceVariant,
            ),
          ),
        ),
      );
    }
    return out;
  }

  static IconData _iconFor(AppThemeVariant v) => switch (v) {
        AppThemeVariant.light => Icons.light_mode_outlined,
        AppThemeVariant.dark => Icons.dark_mode_outlined,
        AppThemeVariant.modern => Icons.auto_awesome_outlined,
      };

  static String _labelFor(AppThemeVariant v) => switch (v) {
        AppThemeVariant.light => 'Light',
        AppThemeVariant.dark => 'Dark',
        AppThemeVariant.modern => 'Modern',
      };
}

class _PillarDrawer extends StatelessWidget {
  const _PillarDrawer({
    required this.selected,
    required this.onSelect,
  });

  final LedgerPillar selected;
  final ValueChanged<LedgerPillar> onSelect;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Drawer(
      child: SafeArea(
        child: ListView(
          padding: const EdgeInsets.symmetric(vertical: 8),
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 16, 20, 8),
              child: Text(
                'Pyramid',
                style: theme.textTheme.titleSmall?.copyWith(
                  color: scheme.onSurfaceVariant,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            for (final p in LedgerPillar.values)
              ListTile(
                leading: Icon(Icons.circle, size: 10, color: p.accent),
                title: Text(p.title),
                subtitle: Text(
                  p.description,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodySmall,
                ),
                selected: p == selected,
                selectedTileColor: p.accent.withValues(alpha: 0.12),
                onTap: () => onSelect(p),
              ),
          ],
        ),
      ),
    );
  }
}

class _PillarHeader extends StatelessWidget {
  const _PillarHeader({required this.pillar, required this.theme});

  final LedgerPillar pillar;
  final ThemeData theme;

  @override
  Widget build(BuildContext context) {
    final scheme = theme.colorScheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 4,
                height: 22,
                decoration: BoxDecoration(
                  color: pillar.accent,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              const SizedBox(width: 10),
              Text(
                pillar.title,
                style: theme.textTheme.headlineSmall?.copyWith(
                  fontWeight: FontWeight.w700,
                  color: scheme.onSurface,
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            pillar.description,
            style: theme.textTheme.bodyMedium?.copyWith(
              color: scheme.onSurfaceVariant,
              height: 1.35,
            ),
          ),
        ],
      ),
    );
  }
}

class _Glass extends StatelessWidget {
  const _Glass({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(14),
        color: const Color(0x14FFFFFF),
        border: Border.all(color: const Color(0x28FFFFFF)),
      ),
      child: child,
    );
  }
}

class _UserCaptureGlassCard extends StatelessWidget {
  const _UserCaptureGlassCard({
    required this.entry,
    required this.scheme,
    required this.theme,
  });

  final FeedEntry entry;
  final ColorScheme scheme;
  final ThemeData theme;

  @override
  Widget build(BuildContext context) {
    final parse = entry.parse;
    return _Glass(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(
                'Capture',
                style: theme.textTheme.labelLarge?.copyWith(
                  color: scheme.onSurface,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const Spacer(),
              Text(
                _timeLabel(entry.createdAt),
                style: theme.textTheme.labelSmall?.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          SelectableText(
            entry.body,
            style: const TextStyle(
              fontFamily: 'monospace',
              fontSize: 14,
              height: 1.45,
            ),
          ),
          if (parse != null && parse.hasAnySignal) ...[
            const SizedBox(height: 10),
            Wrap(
              spacing: 8,
              runSpacing: 6,
              children: [
                if (parse.personHandle != null)
                  _MiniTag('!${parse.personHandle}', scheme),
                if (parse.goalTag != null)
                  _MiniTag('#${parse.goalTag}', scheme),
                if (parse.deadlineHint != null)
                  _MiniTag(parse.deadlineHint!, scheme),
              ],
            ),
          ],
        ],
      ),
    );
  }
}

class _MiniTag extends StatelessWidget {
  const _MiniTag(this.text, this.scheme);

  final String text;
  final ColorScheme scheme;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(8),
        color: scheme.onSurface.withValues(alpha: 0.08),
        border: Border.all(color: scheme.outline.withValues(alpha: 0.35)),
      ),
      child: Text(
        text,
        style: const TextStyle(fontFamily: 'monospace', fontSize: 11),
      ),
    );
  }
}

String _timeLabel(DateTime t) {
  final l = t.toLocal();
  return '${l.year}-${l.month.toString().padLeft(2, '0')}-${l.day.toString().padLeft(2, '0')} '
      '${l.hour.toString().padLeft(2, '0')}:${l.minute.toString().padLeft(2, '0')}';
}

class _StakeholderGlassCard extends StatelessWidget {
  const _StakeholderGlassCard({
    required this.s,
    required this.theme,
    required this.scheme,
  });

  final Stakeholder s;
  final ThemeData theme;
  final ColorScheme scheme;

  @override
  Widget build(BuildContext context) {
    return _Glass(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            s.name,
            style: theme.textTheme.titleSmall?.copyWith(
              fontWeight: FontWeight.w600,
              color: scheme.onSurface,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            s.ask,
            style: theme.textTheme.bodyMedium?.copyWith(
              color: scheme.onSurfaceVariant,
              height: 1.4,
            ),
          ),
        ],
      ),
    );
  }
}

class _GoalGlassCard extends StatelessWidget {
  const _GoalGlassCard({
    required this.g,
    required this.theme,
    required this.scheme,
  });

  final Goal g;
  final ThemeData theme;
  final ColorScheme scheme;

  @override
  Widget build(BuildContext context) {
    return _Glass(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            g.title,
            style: theme.textTheme.titleSmall?.copyWith(
              fontWeight: FontWeight.w600,
              color: scheme.onSurface,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            '#${g.tag}',
            style: const TextStyle(
              fontFamily: 'monospace',
              fontSize: 13,
              color: Color(0xFFB8B8B8),
            ),
          ),
        ],
      ),
    );
  }
}

class _PersonGlassCard extends StatelessWidget {
  const _PersonGlassCard({
    required this.p,
    required this.theme,
    required this.scheme,
  });

  final Person p;
  final ThemeData theme;
  final ColorScheme scheme;

  @override
  Widget build(BuildContext context) {
    return _Glass(
      child: Row(
        children: [
          CircleAvatar(
            radius: 18,
            backgroundColor: scheme.onSurface.withValues(alpha: 0.12),
            child: Text(
              p.displayName.isNotEmpty ? p.displayName[0].toUpperCase() : '?',
              style: TextStyle(color: scheme.onSurface),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  p.displayName,
                  style: theme.textTheme.titleSmall?.copyWith(
                    fontWeight: FontWeight.w600,
                    color: scheme.onSurface,
                  ),
                ),
                Text(
                  '!${p.handle}',
                  style: const TextStyle(
                    fontFamily: 'monospace',
                    fontSize: 12,
                    color: Color(0xFF9E9E9E),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _ExpectationGlassCard extends StatelessWidget {
  const _ExpectationGlassCard({
    required this.e,
    required this.theme,
    required this.scheme,
    required this.peopleById,
    required this.goalsById,
  });

  final Expectation e;
  final ThemeData theme;
  final ColorScheme scheme;
  final Map<String, Person> peopleById;
  final Map<String, Goal> goalsById;

  @override
  Widget build(BuildContext context) {
    final person = peopleById[e.personId];
    final goal = goalsById[e.goalId];
    final who = person?.displayName ?? e.personId;
    final tag = goal != null ? '#${goal.tag}' : e.goalId;
    return _Glass(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              VisibilityGlyph(visibility: e.visibility),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  who,
                  style: theme.textTheme.titleSmall?.copyWith(
                    fontWeight: FontWeight.w600,
                    color: scheme.onSurface,
                  ),
                ),
              ),
              ExpectationStatusBadge(status: e.status),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            e.summary,
            style: theme.textTheme.bodyMedium?.copyWith(
              color: scheme.onSurfaceVariant,
              height: 1.4,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            '$tag · ${e.deadlineLabel}',
            style: theme.textTheme.bodySmall?.copyWith(
              fontFamily: 'monospace',
              color: const Color(0xFF9E9E9E),
            ),
          ),
        ],
      ),
    );
  }
}
