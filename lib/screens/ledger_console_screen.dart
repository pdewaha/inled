import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:inled/data_sources/local_ledger_data_source.dart';
import 'package:inled/models/expectation.dart';
import 'package:inled/models/feed_entry.dart';
import 'package:inled/models/ledger_pillar.dart';
import 'package:inled/models/person.dart';
import 'package:inled/models/expectation_status.dart';
import 'package:inled/models/expectation_visibility.dart';
import 'package:inled/theme.dart';
import 'package:inled/utils/capture_parser.dart';
import 'package:inled/widgets/command_capture_bar.dart';
import 'package:inled/widgets/expectation_status_badge.dart';
import 'package:inled/widgets/responsive_centered_body.dart';
import 'package:inled/widgets/visibility_glyph.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// Single-column command thread with persistent pillar rail and pinned composer.
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
  static const _probeTable = 'connection_probe';

  final _captureController = TextEditingController();
  final _captureFocus = FocusNode();
  final _scrollController = ScrollController();
  Timer? _composerToastTimer;
  String? _composerToastMessage;

  /// Persistent left rail (not a modal drawer — stays put when the canvas is used).
  bool _railExpanded = true;

  LedgerPillar _pillar = LedgerPillar.home;
  final List<FeedEntry> _homeRecent = [];
  final List<Person> _people = [];
  late final List<Expectation> _expectations;
  bool _peopleLoading = true;
  String? _peopleLoadError;
  bool _tagsLoading = true;
  String? _tagsLoadError;
  final List<String> _recentTags = [];
  _SupabaseProbeStatus _supabaseProbeStatus = _SupabaseProbeStatus.checking;
  String? _supabaseProbeMessage;

  bool _keyboardHookRegistered = false;
  bool _submitInFlight = false;

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
    _expectations = _data.getExpectations();
    _probeSupabase();
    _loadPeopleFromSupabase();
    _loadRecentTagsFromSupabase();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (!_keyboardHookRegistered) {
        _keyboardHookRegistered = true;
        HardwareKeyboard.instance.addHandler(_onHardwareKey);
      }
      _captureFocus.requestFocus();
    });
  }

  Future<void> _probeSupabase() async {
    final client = Supabase.instance.client;
    try {
      try {
        await client.from(_probeTable).select('id').limit(1);
      } on PostgrestException catch (e) {
        final msg = e.message.toLowerCase();
        final unauthorized =
            msg.contains('jwt') ||
            msg.contains('api key') ||
            msg.contains('apikey') ||
            msg.contains('unauthorized');
        if (unauthorized) {
          if (mounted) {
            setState(() {
              _supabaseProbeStatus = _SupabaseProbeStatus.unauthorized;
              _supabaseProbeMessage = e.message;
            });
          }
          return;
        }
        if (e.code == 'PGRST205' || e.code == '42P01') {
          if (mounted) {
            setState(() {
              _supabaseProbeStatus = _SupabaseProbeStatus.tableMissing;
              _supabaseProbeMessage =
                  'Reachable, but table "public.$_probeTable" does not exist.';
            });
          }
          return;
        }
        if (e.code == '42501') {
          if (mounted) {
            setState(() {
              _supabaseProbeStatus = _SupabaseProbeStatus.unauthorized;
              _supabaseProbeMessage = e.message;
            });
          }
          return;
        }
        rethrow;
      }
      if (mounted) {
        setState(() {
          _supabaseProbeStatus = _SupabaseProbeStatus.connected;
          _supabaseProbeMessage = 'Connected';
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _supabaseProbeStatus = _SupabaseProbeStatus.failed;
          _supabaseProbeMessage = e.toString();
        });
      }
    }
  }

  Future<void> _loadPeopleFromSupabase() async {
    final client = Supabase.instance.client;
    final user = client.auth.currentUser;
    if (user == null) {
      if (!mounted) return;
      setState(() {
        _peopleLoading = false;
        _peopleLoadError = 'No authenticated user.';
      });
      return;
    }
    try {
      final meRows = await client
          .from('people')
          .select('company_id')
          .eq('auth_user_id', user.id)
          .limit(1);
      if ((meRows as List).isEmpty) {
        if (!mounted) return;
        setState(() {
          _peopleLoading = false;
          _peopleLoadError = 'No linked person/company found for this user.';
          _people.clear();
        });
        return;
      }

      final companyId = meRows.first['company_id'] as String;
      final rows = await client
          .from('people')
          .select('id,created_at,display_name,handle,email,title')
          .eq('company_id', companyId)
          .order('display_name', ascending: true);

      final mapped = (rows as List)
          .map(
            (r) => Person(
              id: r['id'] as String,
              createdAt: DateTime.tryParse(r['created_at'] as String? ?? '') ??
                  DateTime.now().toUtc(),
              displayName: (r['display_name'] as String?)?.trim().isNotEmpty ==
                      true
                  ? (r['display_name'] as String).trim()
                  : (r['handle'] as String? ?? 'Unknown'),
              handle: ((r['handle'] as String?) ?? 'unknown').trim(),
              email: (r['email'] as String?)?.trim(),
              title: (r['title'] as String?)?.trim(),
            ),
          )
          .toList();

      if (!mounted) return;
      setState(() {
        _people
          ..clear()
          ..addAll(mapped);
        _peopleLoading = false;
        _peopleLoadError = null;
      });
    } on PostgrestException catch (e) {
      if (!mounted) return;
      setState(() {
        _peopleLoading = false;
        _peopleLoadError = 'Failed to load people: ${e.message}';
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _peopleLoading = false;
        _peopleLoadError = 'Failed to load people: $e';
      });
    }
  }

  Future<void> _loadRecentTagsFromSupabase() async {
    final client = Supabase.instance.client;
    final user = client.auth.currentUser;
    if (user == null) {
      if (!mounted) return;
      setState(() {
        _tagsLoading = false;
        _tagsLoadError = 'No authenticated user.';
      });
      return;
    }
    try {
      final meRows = await client
          .from('people')
          .select('company_id')
          .eq('auth_user_id', user.id)
          .limit(1);
      if ((meRows as List).isEmpty) {
        if (!mounted) return;
        setState(() {
          _tagsLoading = false;
          _tagsLoadError = 'No linked person/company found for this user.';
          _recentTags.clear();
        });
        return;
      }

      final companyId = meRows.first['company_id'] as String;
      final rows = await client
          .from('expectation_tag_links')
          .select('created_at, expectation_tags!inner(name,company_id)')
          .eq('expectation_tags.company_id', companyId)
          .order('created_at', ascending: false)
          .limit(80);

      final seen = <String>{};
      final tags = <String>[];
      for (final row in (rows as List)) {
        final tagObj = row['expectation_tags'];
        if (tagObj is! Map) continue;
        final name = (tagObj['name'] as String?)?.trim();
        if (name == null || name.isEmpty) continue;
        final key = name.toLowerCase();
        if (seen.add(key)) {
          tags.add(name);
        }
        if (tags.length >= 20) break;
      }

      if (!mounted) return;
      setState(() {
        _recentTags
          ..clear()
          ..addAll(tags);
        _tagsLoading = false;
        _tagsLoadError = null;
      });
    } on PostgrestException catch (e) {
      if (!mounted) return;
      setState(() {
        _tagsLoading = false;
        _tagsLoadError = 'Failed to load tags: ${e.message}';
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _tagsLoading = false;
        _tagsLoadError = 'Failed to load tags: $e';
      });
    }
  }

  @override
  void dispose() {
    if (_keyboardHookRegistered) {
      HardwareKeyboard.instance.removeHandler(_onHardwareKey);
    }
    _captureController.dispose();
    _captureFocus.dispose();
    _scrollController.dispose();
    _composerToastTimer?.cancel();
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
      if (_submitInFlight) return true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          _submitCapture();
        }
      });
      return true;
    }
    return false;
  }

  Future<void> _submitCapture() async {
    if (_submitInFlight) return;
    final text = _captureController.text.trim();
    if (text.isEmpty) return;
    final hasTag = _atTagRegex.hasMatch(text) || _hashTagRegex.hasMatch(text);
    if (!hasTag) {
      _showComposerToast(
        'Please add @XYZ to tag a person, or at least one #tag to classify the expectation.',
      );
      return;
    }
    _submitInFlight = true;
    final parse = parseCaptureLine(text);
    final mode = await _askSubmitMode();
    if (mode == null) {
      _submitInFlight = false;
      return;
    }

    final handle = _extractMentionHandle(text);
    Person? person;
    if (handle != null) {
      person = _findPersonByHandle(handle);
      if (person == null) {
        final email = await _askOptionalEmailForHandle(handle);
        if (email == _cancelToken) {
          _submitInFlight = false;
          return;
        }
        person = _createPersonFromHandle(handle, email: email);
      }
    }

    final visibility = mode == _ExpectationSubmitMode.draft
        ? ExpectationVisibility.shadow
        : ExpectationVisibility.echo;

    setState(() {
      _homeRecent.insert(
        0,
        FeedEntry(
          id: 'cap_${DateTime.now().millisecondsSinceEpoch}',
          createdAt: DateTime.now().toUtc(),
          body: text,
          parse: parse,
          isUserCapture: true,
        ),
      );
      final target = person ?? (_people.isNotEmpty ? _people.first : null);
      if (target != null) {
        _expectations.insert(
          0,
          Expectation(
            id: 'exp_${DateTime.now().millisecondsSinceEpoch}',
            createdAt: DateTime.now().toUtc(),
            personId: target.id,
            summary: text,
            deadlineLabel: 'TBD',
            status: ExpectationStatus.pending,
            visibility: visibility,
          ),
        );
      }
      _captureController.clear();
    });
    try {
      await _persistExpectationToSupabase(
        text: text,
        visibility: visibility,
        target: person ?? (_people.isNotEmpty ? _people.first : null),
      );
    } catch (e) {
      if (mounted) {
        _showComposerToast('Expectation saved locally, but DB write failed: $e');
      }
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollController.hasClients) {
        _scrollController.jumpTo(0);
      }
    });
    _submitInFlight = false;
  }

  static const _cancelToken = '__cancel__';
  static final RegExp _mentionRegex = RegExp(r'@([a-zA-Z0-9._-]+)');
  static final RegExp _atTagRegex = RegExp(r'@([a-zA-Z0-9._-]+)');
  static final RegExp _hashTagRegex = RegExp(r'#([a-zA-Z0-9._-]+)');
  static final RegExp _allHashTagsRegex = RegExp(r'#([a-zA-Z0-9._-]+)');
  static final RegExp _uuidRegex = RegExp(
    r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[1-5][0-9a-fA-F]{3}-[89abAB][0-9a-fA-F]{3}-[0-9a-fA-F]{12}$',
  );
  static final RegExp _emailRegex = RegExp(r'^[^\s@]+@[^\s@]+\.[^\s@]+$');

  Future<void> _persistExpectationToSupabase({
    required String text,
    required ExpectationVisibility visibility,
    required Person? target,
  }) async {
    final client = Supabase.instance.client;
    final user = client.auth.currentUser;
    if (user == null) {
      throw Exception('No authenticated user.');
    }

    final meRows = await client
        .from('people')
        .select('id,company_id')
        .eq('auth_user_id', user.id)
        .limit(1);
    if ((meRows as List).isEmpty) {
      throw Exception('No linked person/company for this user.');
    }
    final writerPersonId = meRows.first['id'] as String;
    final companyId = meRows.first['company_id'] as String;

    final targetPersonId = (target != null && _uuidRegex.hasMatch(target.id))
        ? target.id
        : writerPersonId;
    final title = text.length > 80 ? '${text.substring(0, 80)}...' : text;

    final inserted = await client.from('expectations').insert({
      'company_id': companyId,
      'writer_user_id': user.id,
      'target_person_id': targetPersonId,
      'title': title,
      'summary': text,
      'deadline_label': 'TBD',
      'expectation_status': ExpectationStatus.pending.index,
      'expectation_visibility': visibility.index,
    }).select('id').single();

    final expectationId = inserted['id'] as String;
    final rawTags = _allHashTagsRegex
        .allMatches(text)
        .map((m) => (m.group(1) ?? '').trim().toLowerCase())
        .where((t) => t.isNotEmpty)
        .toSet();

    for (final tag in rawTags) {
      String tagId;
      try {
        final insertedTag = await client
            .from('expectation_tags')
            .insert({
              'company_id': companyId,
              'name': tag,
            })
            .select('id')
            .single();
        tagId = insertedTag['id'] as String;
      } on PostgrestException {
        final existingTag = await client
            .from('expectation_tags')
            .select('id')
            .eq('company_id', companyId)
            .ilike('name', tag)
            .limit(1);
        if ((existingTag as List).isEmpty) {
          rethrow;
        }
        tagId = existingTag.first['id'] as String;
      }

      try {
        await client.from('expectation_tag_links').insert({
          'expectation_id': expectationId,
          'tag_id': tagId,
        });
      } on PostgrestException {
        // Ignore duplicate link insert attempts for idempotency.
      }
    }
    if (mounted) {
      await _loadRecentTagsFromSupabase();
    }
  }

  void _showComposerToast(String message) {
    if (!mounted) return;
    _composerToastTimer?.cancel();
    setState(() => _composerToastMessage = message);
    _composerToastTimer = Timer(const Duration(seconds: 4), () {
      if (!mounted) return;
      setState(() => _composerToastMessage = null);
    });
  }

  String? _extractMentionHandle(String input) {
    final m = _mentionRegex.firstMatch(input);
    return m?.group(1);
  }

  Person? _findPersonByHandle(String handle) {
    final key = handle.toLowerCase();
    for (final p in _people) {
      if (p.handle.toLowerCase() == key) return p;
    }
    return null;
  }

  Person _createPersonFromHandle(String handle, {String? email}) {
    final normalized = handle.trim();
    final display = normalized.isEmpty
        ? 'Unknown'
        : '${normalized[0].toUpperCase()}${normalized.substring(1)}';
    final person = Person(
      id: 'person_${DateTime.now().millisecondsSinceEpoch}',
      createdAt: DateTime.now().toUtc(),
      displayName: display,
      handle: normalized,
      email: email,
    );
    setState(() => _people.add(person));
    return person;
  }

  Future<_ExpectationSubmitMode?> _askSubmitMode() async {
    return showDialog<_ExpectationSubmitMode>(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: const Text('Save expectation'),
          content: const Text(
            'Do you want to save this as draft, or directly publish it?',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('Cancel'),
            ),
            TextButton(
              onPressed: () =>
                  Navigator.of(context).pop(_ExpectationSubmitMode.draft),
              child: const Text('Save as draft'),
            ),
            FilledButton(
              onPressed: () =>
                  Navigator.of(context).pop(_ExpectationSubmitMode.inform),
              child: const Text('Publish'),
            ),
          ],
        );
      },
    );
  }

  Future<String?> _askOptionalEmailForHandle(String handle) async {
    final controller = TextEditingController();
    String? error;
    final result = await showDialog<String>(
      context: context,
      barrierDismissible: false,
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setLocalState) {
            return AlertDialog(
              title: Text('Create @$handle'),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'No person found. Optionally provide a company email.',
                  ),
                  const SizedBox(height: 10),
                  TextField(
                    controller: controller,
                    autofocus: true,
                    decoration: InputDecoration(
                      hintText: 'name@company.com (optional)',
                      errorText: error,
                    ),
                    onSubmitted: (_) {
                      final value = controller.text.trim();
                      if (value.isEmpty || _emailRegex.hasMatch(value)) {
                        Navigator.of(context).pop(value);
                      } else {
                        setLocalState(() {
                          error = 'Please enter a valid email or leave empty.';
                        });
                      }
                    },
                  ),
                ],
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(context).pop(_cancelToken),
                  child: const Text('Cancel'),
                ),
                FilledButton(
                  onPressed: () {
                    final value = controller.text.trim();
                    if (value.isEmpty || _emailRegex.hasMatch(value)) {
                      Navigator.of(context).pop(value);
                    } else {
                      setLocalState(() {
                        error = 'Please enter a valid email or leave empty.';
                      });
                    }
                  },
                  child: const Text('Save'),
                ),
              ],
            );
          },
        );
      },
    );
    controller.dispose();
    return result;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final peopleById = {for (final p in _people) p.id: p};

    return Scaffold(
      backgroundColor: theme.scaffoldBackgroundColor,
      appBar: AppBar(
        leading: IconButton(
          icon: Icon(_railExpanded ? Icons.menu_open : Icons.menu),
          tooltip: _railExpanded ? 'Collapse sidebar' : 'Expand sidebar',
          onPressed: () => setState(() => _railExpanded = !_railExpanded),
        ),
        title: const Text('ExLed'),
        actions: [
          _SupabaseProbeBadge(
            status: _supabaseProbeStatus,
            message: _supabaseProbeMessage,
          ),
          const SizedBox(width: 4),
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
          IconButton(
            tooltip: 'Logout',
            onPressed: () async {
              await Supabase.instance.client.auth.signOut();
            },
            icon: const Icon(Icons.logout),
          ),
          const SizedBox(width: 4),
        ],
      ),
      body: SafeArea(
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            ExcludeFocus(
              excluding: true,
              child: _PillarRail(
                expanded: _railExpanded,
                selected: _pillar,
                recentTags: _recentTags,
                onSelect: (p) {
                  setState(() => _pillar = p);
                  if (p == LedgerPillar.home) {
                    _focusComposer();
                  } else {
                    _captureFocus.unfocus();
                  }
                },
              ),
            ),
            Expanded(
              child: GestureDetector(
                behavior: HitTestBehavior.translucent,
                onTap: _focusComposer,
                child: ResponsiveCenteredBody(
                  maxWidth: 800,
                  alwaysApplyMaxWidth: true,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      _PillarHeader(pillar: _pillar, theme: theme),
                      const SizedBox(height: 12),
                      if (_pillar == LedgerPillar.home) ...[
                        Padding(
                          padding:
                              const EdgeInsets.symmetric(vertical: 8),
                          child: CommandCaptureBar(
                            controller: _captureController,
                            focusNode: _captureFocus,
                            accentColor: _pillar.accent,
                          ),
                        ),
                        if (_composerToastMessage != null)
                          Container(
                            width: double.infinity,
                            margin: const EdgeInsets.only(bottom: 8),
                            padding: const EdgeInsets.symmetric(
                              horizontal: 12,
                              vertical: 10,
                            ),
                            decoration: BoxDecoration(
                              color: scheme.errorContainer.withValues(alpha: 0.9),
                              borderRadius: BorderRadius.circular(10),
                              border: Border.all(
                                color: scheme.error.withValues(alpha: 0.35),
                              ),
                            ),
                            child: Text(
                              _composerToastMessage!,
                              style: theme.textTheme.bodySmall?.copyWith(
                                color: scheme.onErrorContainer,
                              ),
                            ),
                          ),
                        const SizedBox(height: 20),
                      ],
                      if (_pillar != LedgerPillar.people) ...[
                        Text(
                          'Recent',
                          style: theme.textTheme.titleSmall?.copyWith(
                            fontWeight: FontWeight.w700,
                            color: scheme.onSurface,
                          ),
                        ),
                        const SizedBox(height: 12),
                      ],
                      Expanded(
                        child: ListView(
                          controller: _scrollController,
                          padding: const EdgeInsets.only(bottom: 16),
                          children: _threadChildren(
                            theme: theme,
                            scheme: scheme,
                            people: _people,
                            expectations: _expectations,
                            peopleById: peopleById,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  List<Widget> _threadChildren({
    required ThemeData theme,
    required ColorScheme scheme,
    required List<Person> people,
    required List<Expectation> expectations,
    required Map<String, Person> peopleById,
  }) {
    final out = <Widget>[];
    final mePerson = (() {
      for (final p in people) {
        if (p.handle.toLowerCase() == 'john') return p;
      }
      return null;
    })();
    final otherPerson = (() {
      for (final p in people) {
        if (p.handle.toLowerCase() == 'ava') return p;
      }
      return null;
    })();

    switch (_pillar) {
      case LedgerPillar.home:
        for (final e in _homeRecent) {
          out.add(_UserCaptureGlassCard(entry: e, scheme: scheme, theme: theme));
        }
        for (final x in expectations) {
          out.add(
            _ExpectationGlassCard(
              e: x,
              theme: theme,
              scheme: scheme,
              peopleById: peopleById,
            ),
          );
        }
        break;

      case LedgerPillar.people:
        if (_peopleLoading) {
          out.add(const _PeopleLoadingCard());
        } else if (_peopleLoadError != null) {
          out.add(_PeopleErrorCard(message: _peopleLoadError!, onRetry: _loadPeopleFromSupabase));
        } else {
          out.add(_PeopleTileGrid(people: people, theme: theme, scheme: scheme));
        }
        break;

      case LedgerPillar.tags:
        if (_tagsLoading) {
          out.add(const _TagsLoadingCard());
        } else if (_tagsLoadError != null) {
          out.add(
            _TagsErrorCard(
              message: _tagsLoadError!,
              onRetry: _loadRecentTagsFromSupabase,
            ),
          );
        } else {
          out.add(_RecentTagsCloud(tags: _recentTags, theme: theme, scheme: scheme));
        }
        break;

      case LedgerPillar.expectationsMe:
        if (mePerson != null) {
          for (final e in _homeRecent) {
            final ph = e.parse?.personHandle;
            if (ph != null && ph.toLowerCase() == mePerson.handle.toLowerCase()) {
              out.add(_UserCaptureGlassCard(entry: e, scheme: scheme, theme: theme));
            }
          }
          for (final x in expectations) {
            if (x.personId == mePerson.id) {
              out.add(
                _ExpectationGlassCard(
                  e: x,
                  theme: theme,
                  scheme: scheme,
                  peopleById: peopleById,
                ),
              );
            }
          }
        }
        break;

      case LedgerPillar.expectationsOthers:
        if (otherPerson != null) {
          for (final e in _homeRecent) {
            final ph = e.parse?.personHandle;
            if (ph != null && ph.toLowerCase() == otherPerson.handle.toLowerCase()) {
              out.add(_UserCaptureGlassCard(entry: e, scheme: scheme, theme: theme));
            }
          }
          for (final x in expectations) {
            if (x.personId == otherPerson.id) {
              out.add(
                _ExpectationGlassCard(
                  e: x,
                  theme: theme,
                  scheme: scheme,
                  peopleById: peopleById,
                ),
              );
            }
          }
        }
        break;
    }

    if (out.isEmpty) {
      out.add(
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 32),
          child: Text(
            'Nothing in this section yet.',
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

enum _ExpectationSubmitMode {
  draft,
  inform,
}

class _PillarRail extends StatelessWidget {
  const _PillarRail({
    required this.expanded,
    required this.selected,
    required this.recentTags,
    required this.onSelect,
  });

  static const double _widthExpanded = 280;
  static const double _widthCollapsed = 72;

  static const List<LedgerPillar> _sidebarOrder = [
    LedgerPillar.expectationsMe,
    LedgerPillar.expectationsOthers,
  ];

  final bool expanded;
  final LedgerPillar selected;
  final List<String> recentTags;
  final ValueChanged<LedgerPillar> onSelect;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final railColor = theme.drawerTheme.backgroundColor ??
        scheme.surfaceContainerLow;
    return AnimatedContainer(
      duration: const Duration(milliseconds: 220),
      curve: Curves.easeOutCubic,
      width: expanded ? _widthExpanded : _widthCollapsed,
      child: Material(
        color: railColor,
        child: ListView(
          padding: const EdgeInsets.symmetric(vertical: 8),
          children: [
            if (expanded) ...[
              ListTile(
                leading: const Icon(Icons.home_outlined),
                title: const Text('Home'),
                selected: selected == LedgerPillar.home,
                selectedTileColor:
                    LedgerPillar.home.accent.withValues(alpha: 0.12),
                onTap: () => onSelect(LedgerPillar.home),
              ),
              _railSectionHeading(context, 'Expectations', primary: true),
              for (final p in _sidebarOrder)
                _expandedPillarTile(
                  context,
                  p: p,
                  selected: selected,
                  onSelect: onSelect,
                ),
              const SizedBox(height: 10),
              _railSectionHeading(context, 'Organisation'),
              _expandedPillarTile(
                context,
                p: LedgerPillar.people,
                selected: selected,
                onSelect: onSelect,
              ),
              _expandedPillarTile(
                context,
                p: LedgerPillar.tags,
                selected: selected,
                onSelect: onSelect,
              ),
              if (recentTags.isNotEmpty) ...[
                const SizedBox(height: 6),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  child: Wrap(
                    spacing: 6,
                    runSpacing: 6,
                    children: [
                      for (final tag in recentTags.take(8))
                        ActionChip(
                          label: Text(
                            '#$tag',
                            style: theme.textTheme.labelSmall,
                          ),
                          onPressed: () => onSelect(LedgerPillar.tags),
                          materialTapTargetSize:
                              MaterialTapTargetSize.shrinkWrap,
                          visualDensity: VisualDensity.compact,
                        ),
                    ],
                  ),
                ),
              ],
            ] else ...[
              const SizedBox(height: 12),
              _collapsedPillarDot(
                context,
                p: LedgerPillar.home,
                selected: selected,
                onSelect: onSelect,
              ),
              const SizedBox(height: 14),
              for (final p in _sidebarOrder)
                _collapsedPillarDot(
                  context,
                  p: p,
                  selected: selected,
                  onSelect: onSelect,
                ),
              const SizedBox(height: 14),
              _collapsedPillarDot(
                context,
                p: LedgerPillar.people,
                selected: selected,
                onSelect: onSelect,
              ),
              _collapsedPillarDot(
                context,
                p: LedgerPillar.tags,
                selected: selected,
                onSelect: onSelect,
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _railSectionHeading(
    BuildContext context,
    String label, {
    bool primary = false,
  }) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Padding(
      padding: EdgeInsets.fromLTRB(20, primary ? 16 : 10, 20, 6),
      child: Text(
        label,
        style: theme.textTheme.titleSmall?.copyWith(
          color: scheme.onSurfaceVariant,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }

  Widget _expandedPillarTile(
    BuildContext context, {
    required LedgerPillar p,
    required LedgerPillar selected,
    required ValueChanged<LedgerPillar> onSelect,
  }) {
    final theme = Theme.of(context);
    final icon = switch (p) {
      LedgerPillar.home => Icons.home_outlined,
      LedgerPillar.expectationsMe => Icons.south_west_outlined,
      LedgerPillar.expectationsOthers => Icons.north_east_outlined,
      LedgerPillar.people => Icons.group_outlined,
      LedgerPillar.tags => Icons.tag_outlined,
    };
    return ListTile(
      leading: Icon(icon, size: 18, color: p.accent),
      title: Text(p.title),
      subtitle: p == LedgerPillar.home
          ? null
          : Text(
              p.description,
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodySmall,
            ),
      selected: p == selected,
      selectedTileColor: p.accent.withValues(alpha: 0.12),
      onTap: () => onSelect(p),
    );
  }

  Widget _collapsedPillarDot(
    BuildContext context, {
    required LedgerPillar p,
    required LedgerPillar selected,
    required ValueChanged<LedgerPillar> onSelect,
  }) {
    final scheme = Theme.of(context).colorScheme;
    final icon = switch (p) {
      LedgerPillar.home => Icons.home_outlined,
      LedgerPillar.expectationsMe => Icons.south_west_outlined,
      LedgerPillar.expectationsOthers => Icons.north_east_outlined,
      LedgerPillar.people => Icons.group_outlined,
      LedgerPillar.tags => Icons.tag_outlined,
    };
    return Tooltip(
      message: '${p.title}\n${p.description}',
      waitDuration: const Duration(milliseconds: 400),
      child: InkWell(
        onTap: () => onSelect(p),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 10),
          child: Center(
            child: Container(
              width: 30,
              height: 30,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(8),
                color: p == selected
                    ? p.accent.withValues(alpha: 0.2)
                    : Colors.transparent,
                border: Border.all(
                  color: p == selected
                      ? scheme.onSurface.withValues(alpha: 0.25)
                      : Colors.transparent,
                ),
              ),
              child: Icon(icon, size: 16, color: p.accent),
            ),
          ),
        ),
      ),
    );
  }
}

enum _SupabaseProbeStatus {
  checking,
  connected,
  tableMissing,
  unauthorized,
  failed,
}

class _SupabaseProbeBadge extends StatelessWidget {
  const _SupabaseProbeBadge({
    required this.status,
    this.message,
  });

  final _SupabaseProbeStatus status;
  final String? message;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final (IconData icon, String label, Color color) = switch (status) {
      _SupabaseProbeStatus.checking => (
          Icons.cloud_sync_outlined,
          'Supabase: checking',
          scheme.onSurfaceVariant,
        ),
      _SupabaseProbeStatus.connected => (
          Icons.cloud_done_outlined,
          'Supabase: reachable',
          Colors.lightGreenAccent.shade200,
        ),
      _SupabaseProbeStatus.tableMissing => (
          Icons.table_chart_outlined,
          'Supabase: reachable, probe table missing',
          Colors.orangeAccent.shade200,
        ),
      _SupabaseProbeStatus.unauthorized => (
          Icons.key_off_outlined,
          'Supabase: reachable but unauthorized',
          Colors.amberAccent.shade200,
        ),
      _SupabaseProbeStatus.failed => (
          Icons.cloud_off_outlined,
          'Supabase: not reachable',
          scheme.error,
        ),
    };
    return Tooltip(
      message: message == null ? label : '$label\n$message',
      child: Icon(icon, size: 20, color: color),
    );
  }
}

class _PeopleGlassCard extends StatelessWidget {
  const _PeopleGlassCard({
    required this.person,
    required this.theme,
    required this.scheme,
  });

  final Person person;
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
              person.displayName.isNotEmpty
                  ? person.displayName[0].toUpperCase()
                  : '?',
              style: TextStyle(color: scheme.onSurface),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  person.displayName,
                  style: theme.textTheme.titleSmall?.copyWith(
                    fontWeight: FontWeight.w600,
                    color: scheme.onSurface,
                  ),
                ),
                Text(
                  (person.title?.isNotEmpty ?? false)
                      ? person.title!
                      : 'No title set',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: scheme.onSurfaceVariant,
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

class _PeopleTileGrid extends StatelessWidget {
  const _PeopleTileGrid({
    required this.people,
    required this.theme,
    required this.scheme,
  });

  final List<Person> people;
  final ThemeData theme;
  final ColorScheme scheme;

  @override
  Widget build(BuildContext context) {
    if (people.isEmpty) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 20),
        child: Text(
          'No people found in this company yet.',
          textAlign: TextAlign.center,
          style: theme.textTheme.bodyMedium?.copyWith(
            color: scheme.onSurfaceVariant,
          ),
        ),
      );
    }
    return LayoutBuilder(
      builder: (context, constraints) {
        final columns = constraints.maxWidth >= 720
            ? 3
            : constraints.maxWidth >= 480
                ? 2
                : 1;
        final tileWidth = (constraints.maxWidth - (columns - 1) * 12) / columns;
        return Wrap(
          spacing: 12,
          runSpacing: 12,
          children: [
            for (final p in people)
              SizedBox(
                width: tileWidth,
                child: _PeopleGlassCard(person: p, theme: theme, scheme: scheme),
              ),
          ],
        );
      },
    );
  }
}

class _PeopleLoadingCard extends StatelessWidget {
  const _PeopleLoadingCard();

  @override
  Widget build(BuildContext context) {
    return const _Glass(
      child: Row(
        children: [
          SizedBox(
            width: 18,
            height: 18,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
          SizedBox(width: 10),
          Text('Loading people from Supabase...'),
        ],
      ),
    );
  }
}

class _PeopleErrorCard extends StatelessWidget {
  const _PeopleErrorCard({
    required this.message,
    required this.onRetry,
  });

  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return _Glass(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            message,
            style: TextStyle(color: scheme.error),
          ),
          const SizedBox(height: 10),
          FilledButton(
            onPressed: onRetry,
            child: const Text('Retry'),
          ),
        ],
      ),
    );
  }
}

class _RecentTagsCloud extends StatelessWidget {
  const _RecentTagsCloud({
    required this.tags,
    required this.theme,
    required this.scheme,
  });

  final List<String> tags;
  final ThemeData theme;
  final ColorScheme scheme;

  @override
  Widget build(BuildContext context) {
    if (tags.isEmpty) {
      return _Glass(
        child: Text(
          'No recent tags yet. Create expectations with #tags to build the cloud.',
          style: theme.textTheme.bodyMedium?.copyWith(
            color: scheme.onSurfaceVariant,
          ),
        ),
      );
    }
    return _Glass(
      child: Wrap(
        spacing: 8,
        runSpacing: 8,
        children: [
          for (final tag in tags)
            Chip(
              avatar: Icon(Icons.tag, size: 16, color: scheme.primary),
              label: Text('#$tag'),
              backgroundColor: scheme.primaryContainer.withValues(alpha: 0.4),
              side: BorderSide(color: scheme.outlineVariant),
            ),
        ],
      ),
    );
  }
}

class _TagsLoadingCard extends StatelessWidget {
  const _TagsLoadingCard();

  @override
  Widget build(BuildContext context) {
    return const _Glass(
      child: Row(
        children: [
          SizedBox(
            width: 18,
            height: 18,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
          SizedBox(width: 10),
          Text('Loading recent tags...'),
        ],
      ),
    );
  }
}

class _TagsErrorCard extends StatelessWidget {
  const _TagsErrorCard({
    required this.message,
    required this.onRetry,
  });

  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return _Glass(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            message,
            style: TextStyle(color: scheme.error),
          ),
          const SizedBox(height: 10),
          FilledButton(
            onPressed: onRetry,
            child: const Text('Retry'),
          ),
        ],
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

class _ExpectationGlassCard extends StatelessWidget {
  const _ExpectationGlassCard({
    required this.e,
    required this.theme,
    required this.scheme,
    required this.peopleById,
  });

  final Expectation e;
  final ThemeData theme;
  final ColorScheme scheme;
  final Map<String, Person> peopleById;

  @override
  Widget build(BuildContext context) {
    final person = peopleById[e.personId];
    final who = person?.displayName ?? e.personId;
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
            e.deadlineLabel,
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
