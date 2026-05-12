import 'dart:async';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:inled/models/expectation.dart';
import 'package:inled/models/expectation_health.dart';
import 'package:inled/models/expectation_type.dart';
import 'package:inled/models/feed_entry.dart';
import 'package:inled/models/ledger_pillar.dart';
import 'package:inled/models/person.dart';
import 'package:inled/models/expectation_status.dart';
import 'package:inled/models/expectation_visibility.dart';
import 'package:inled/theme.dart';
import 'package:inled/utils/capture_parser.dart';
import 'package:inled/widgets/command_capture_bar.dart';
import 'package:inled/widgets/ledger_tag_chip.dart';
import 'package:inled/widgets/responsive_centered_body.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:url_launcher/url_launcher.dart';

/// Single-column command thread with persistent pillar rail; Home uses Quick Capture
/// in a sheet, other capture pillars keep an inline composer.
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
  static const _composerDefaultMode = _ComposerEntryMode.topic;
  final _captureController = TextEditingController();
  final _captureFocus = FocusNode();
  /// Save-action row (Home kind row / Add topic / Add expectation): Tab order field → A → B.
  final _composerSavePairFocusA = FocusNode(debugLabel: 'composerSaveA');
  final _composerSavePairFocusB = FocusNode(debugLabel: 'composerSaveB');
  /// Home visibility step only — must not reuse [_composerSavePairFocusA]/B or Flutter can
  /// keep the wrong [FilledButton] focused/visible after the kind row is shown again.
  final _homeVisSaveFocusA = FocusNode(debugLabel: 'homeVisSaveA');
  final _homeVisSaveFocusB = FocusNode(debugLabel: 'homeVisSaveB');
  final _scrollController = ScrollController();
  Timer? _composerToastTimer;
  String? _composerToastMessage;
  /// Bumped with [_captureController] via [Listenable.merge] so the home save row rebuilds
  /// when only [_homePendingEntry] changes — [ValueListenableBuilder] alone can keep a stale
  /// controller snapshot until the next text notification.
  final ValueNotifier<int> _homeComposerUiRevision = ValueNotifier<int>(0);
  late final Listenable _homeComposerSaveRowListenable;
  /// Rebuild Add topic / Add expectation save rows when text or capture focus changes.
  late final Listenable _composerSaveRowListenable;
  /// Changes after a successful home capture to remount the composer subtree (neutral UI).
  int _homeComposerBlockKey = 0;
  /// Incremented on home hard-reset so [CommandCaptureBar] can refocus after remount (see widget).
  int _homeCaptureRefocusToken = 0;
  /// Home-only: stable anchor under the capture bar for [FocusScope.requestFocus] after reset.
  final GlobalKey _homeComposerCaptureHostKey = GlobalKey();

  /// True while the Home Quick Capture bottom sheet is open ([_composerHasSavePairButtonsPillar]).
  bool _homeQuickCaptureSheetOpen = false;

  /// Persistent left rail (not a modal drawer — stays put when the canvas is used).
  bool _railExpanded = true;

  /// Outbox: show published (echo) vs draft (shadow) expectations only.
  _OutboxListingTab _outboxListingTab = _OutboxListingTab.published;

  /// Inbox: from other people vs self-authored (you as writer, you as receiver).
  _InboxListingTab _inboxListingTab = _InboxListingTab.fromOthers;

  LedgerPillar _pillar = LedgerPillar.home;
  final List<FeedEntry> _homeRecent = [];
  final List<Person> _people = [];
  final List<Expectation> _expectations = [];
  bool _peopleLoading = true;
  String? _peopleLoadError;
  bool _expectationsLoading = true;
  String? _expectationsLoadError;
  bool _tagsLoading = true;
  String? _tagsLoadError;
  final List<String> _recentTags = [];
  /// True when more than 20 distinct #tags exist in the loaded window (sidebar ellipsis).
  bool _recentTagsHasMore = false;
  String _profileName = 'You';
  String? _profileTitle;
  String? _myPersonId;
  /// From `companies.name` when set; footer directory uses this instead of "People".
  String? _companyName;

  bool _keyboardHookRegistered = false;
  bool _submitInFlight = false;
  bool _refreshInFlight = false;
  _ComposerEntryMode _composerMode = _composerDefaultMode;
  /// Home only: after "Save as Talking Point" / "Save as Expectation", pick visibility inline.
  _ComposerEntryMode? _homePendingEntry;
  _ExpectationPillarQuickChoice _expectationPillarQuickChoice =
      _ExpectationPillarQuickChoice.draft;
  String? _activeMentionQuery;
  int? _activeMentionStart;
  int? _activeMentionEnd;
  Person? _uniqueMentionSuggestion;
  /// Shown when @query matches several handles (or @ alone); not Tab-completable until unique.
  String? _mentionDisambiguationHint;
  /// Multiple @ handle matches — chips under the composer.
  List<Person> _mentionInlineCandidates = [];
  List<String> _tagInlineCandidates = [];
  /// Keyboard cycle index when [_mentionInlineCandidates] or [_tagInlineCandidates] has >1 item.
  int _composerPickIndex = 0;
  String? _activeTagQuery;
  int? _activeTagStart;
  int? _activeTagEnd;
  String? _uniqueTagSuggestion;
  bool _othersDraftsCollapsed = false;
  bool _othersPublishedCollapsed = false;
  bool _othersFinishedCollapsed = false;
  bool _othersArchiveCollapsed = true;
  bool _meOngoingCollapsed = false;
  bool _meFinishedCollapsed = false;
  bool _meArchiveCollapsed = true;
  bool _tagsArchiveCollapsed = true;
  bool _colleagueArchiveCollapsed = true;
  String? _tagsSelectedTag;
  _TalkingPointsSubView _talkingPointsSubView = _TalkingPointsSubView.meetingsOrTags;
  /// Private view: filter talking points @'d at this person (author-only).
  String? _colleagueFilterPersonId;
  ExpectationStatus? _othersStatusFilter;
  String? _othersTagFilter;
  String? _othersPersonFilter;
  ExpectationStatus? _inboxStatusFilter;
  String? _inboxTagFilter;
  String? _inboxPersonFilter;

  bool _hasUnreadChat(Expectation e) {
    final currentUserId = Supabase.instance.client.auth.currentUser?.id;
    if (currentUserId == null) return false;
    final senderAt = e.lastChattedSenderAt;
    final receiverAt = e.lastChattedReceiverAt;
    if (e.writerUserId == null) return false;
    final isWriterView = currentUserId == e.writerUserId;
    if (isWriterView) {
      return receiverAt != null && (senderAt == null || receiverAt.isAfter(senderAt));
    }
    return senderAt != null && (receiverAt == null || senderAt.isAfter(receiverAt));
  }

  void _openTagPillar(String tag) {
    setState(() {
      _homePendingEntry = null;
      _pillar = LedgerPillar.tags;
      _talkingPointsSubView = _TalkingPointsSubView.meetingsOrTags;
      _tagsSelectedTag = tag.trim().toLowerCase();
      _colleagueFilterPersonId = null;
    });
    _captureFocus.unfocus();
  }

  /// Private (@-person) talking points (author, non-empty receiver), for cloud + filters.
  List<_ColleagueCloudEntry> _colleagueTalkingPointCloudEntries() {
    final currentUserId = Supabase.instance.client.auth.currentUser?.id;
    if (currentUserId == null) return [];
    final byPersonId = <String, int>{};
    for (final x in _expectations) {
      if (x.type != ExpectationType.topic) continue;
      if (x.writerUserId != currentUserId) continue;
      final pid = x.personId.trim();
      if (pid.isEmpty) continue;
      byPersonId[pid] = (byPersonId[pid] ?? 0) + 1;
    }
    final peopleById = {for (final p in _people) p.id: p};
    final out = <_ColleagueCloudEntry>[];
    for (final e in byPersonId.entries) {
      final person = peopleById[e.key];
      if (person == null) continue;
      out.add(_ColleagueCloudEntry(person: person, count: e.value));
    }
    out.sort((a, b) {
      final byCount = b.count.compareTo(a.count);
      if (byCount != 0) return byCount;
      return a.person.displayName
          .toLowerCase()
          .compareTo(b.person.displayName.toLowerCase());
    });
    return out;
  }

  /// #tags on your shadow talking points (Private), newest-first for the rail cloud.
  List<String> _privateRailTagsFromExpectations({int max = 20}) {
    final uid = Supabase.instance.client.auth.currentUser?.id;
    if (uid == null) return [];
    final pool = _expectations
        .where(
          (x) =>
              x.type == ExpectationType.topic &&
              x.writerUserId == uid &&
              x.visibility == ExpectationVisibility.shadow &&
              _extractInlineTags(x.summary).isNotEmpty,
        )
        .toList()
      ..sort((a, b) => b.createdAt.compareTo(a.createdAt));
    final seen = <String>{};
    final out = <String>[];
    for (final e in pool) {
      for (final tag in _extractInlineTags(e.summary)) {
        final k = tag.toLowerCase();
        if (seen.add(k)) out.add(tag);
        if (out.length >= max) return out;
      }
    }
    return out;
  }

  /// #tags on echo talking points (Public), merged with [\_recentTags].
  /// [_recentTags] is loaded from Supabase as **echo topic** rows only (see
  /// [_loadRecentTagsFromSupabase]) so this cloud stays separate from [\_privateRailTagsFromExpectations].
  List<String> _mergedPublicRailTags({int max = 20}) {
    final seen = <String>{};
    final out = <String>[];
    void addDisplay(String tag) {
      final k = tag.toLowerCase();
      if (seen.add(k)) out.add(tag);
    }
    final pool = _expectations
        .where(
          (x) =>
              x.type == ExpectationType.topic &&
              x.visibility == ExpectationVisibility.echo &&
              x.personId.trim().isEmpty &&
              _extractInlineTags(x.summary).isNotEmpty,
        )
        .toList()
      ..sort((a, b) => b.createdAt.compareTo(a.createdAt));
    for (final e in pool) {
      for (final tag in _extractInlineTags(e.summary)) {
        addDisplay(tag);
        if (out.length >= max) return out;
      }
    }
    for (final tag in _recentTags) {
      addDisplay(tag);
      if (out.length >= max) return out;
    }
    return out;
  }

  /// # suggestions in the composer: public echo tags plus your private (shadow) tags.
  List<String> _hashtagAutocompletePool() {
    final seen = <String>{};
    final out = <String>[];
    void add(String t) {
      if (t.trim().isEmpty) return;
      final k = t.toLowerCase();
      if (seen.add(k)) out.add(t);
    }

    for (final t in _recentTags) {
      add(t);
    }
    for (final t in _privateRailTagsFromExpectations(max: 40)) {
      add(t);
    }
    return out;
  }

  void _onPrivateRailTagSelect(String tag) {
    setState(() {
      _pillar = LedgerPillar.tags;
      _talkingPointsSubView = _TalkingPointsSubView.colleagues;
      _tagsSelectedTag = tag.trim().toLowerCase();
      _colleagueFilterPersonId = null;
    });
  }

  void _openTalkingPointsSubView(_TalkingPointsSubView view) {
    setState(() {
      _homePendingEntry = null;
      _pillar = LedgerPillar.tags;
      _talkingPointsSubView = view;
      if (view == _TalkingPointsSubView.colleagues) {
        _tagsSelectedTag = null;
      } else {
        _colleagueFilterPersonId = null;
      }
    });
    _captureFocus.unfocus();
  }

  /// Rail @ chip: open Private with this person selected (main page uses dropdown).
  void _openColleaguesFilteredToPerson(String personId) {
    setState(() {
      _homePendingEntry = null;
      _pillar = LedgerPillar.tags;
      _talkingPointsSubView = _TalkingPointsSubView.colleagues;
      _colleagueFilterPersonId = personId;
      _tagsSelectedTag = null;
    });
    _captureFocus.unfocus();
  }

  /// Inbound expectation: [Expectation.personId] is the receiver (me); show the writer.
  Person? _writerPersonForExpectation(Expectation e, List<Person> people) {
    final w = e.writerUserId;
    if (w == null) return null;
    for (final p in people) {
      if (p.authUserId == w) return p;
    }
    return null;
  }

  void _onOutboxListingTabChanged(Set<_OutboxListingTab> selection) {
    if (selection.isEmpty) return;
    setState(() => _outboxListingTab = selection.first);
  }

  void _onInboxListingTabChanged(Set<_InboxListingTab> selection) {
    if (selection.isEmpty) return;
    setState(() => _inboxListingTab = selection.first);
  }

  bool _inboxTabMatchesWriter(Expectation x, String? currentUserId) {
    if (currentUserId == null) {
      return _inboxListingTab == _InboxListingTab.fromOthers;
    }
    final selfAuthored = x.writerUserId == currentUserId;
    return _inboxListingTab == _InboxListingTab.personal
        ? selfAuthored
        : !selfAuthored;
  }

  Future<void> _deleteExpectationFromList(Expectation expectation) async {
    final currentUserId = Supabase.instance.client.auth.currentUser?.id;
    if (currentUserId == null || expectation.writerUserId != currentUserId) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Only the author can delete this expectation.')),
      );
      return;
    }
    try {
      await Supabase.instance.client.from('expectations').delete().eq('id', expectation.id);
      if (!mounted) return;
      setState(() {
        _expectations.removeWhere((e) => e.id == expectation.id);
        _homeRecent.removeWhere((e) => e.linkedExpectationId == expectation.id);
      });
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Item has been deleted.')));
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Failed to delete expectation.')));
    }
  }

  /// Outbox draft → published (visible to receiver): echo visibility + published_at.
  Future<void> _publishOutboxDraft(Expectation expectation) async {
    final currentUserId = Supabase.instance.client.auth.currentUser?.id;
    if (currentUserId == null || expectation.writerUserId != currentUserId) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Only the author can publish this item.')),
      );
      return;
    }
    if (expectation.visibility != ExpectationVisibility.shadow) return;
    final now = DateTime.now().toUtc();
    try {
      await Supabase.instance.client.from('expectations').update({
        'expectation_visibility': ExpectationVisibility.echo.index,
        'published_at': now.toIso8601String(),
        'responsible_updated_at': now.toIso8601String(),
      }).eq('id', expectation.id);
      if (!mounted) return;
      setState(() {
        final i = _expectations.indexWhere((e) => e.id == expectation.id);
        if (i >= 0) {
          final e = _expectations[i];
          _expectations[i] = Expectation(
            id: e.id,
            createdAt: e.createdAt,
            writerUserId: e.writerUserId,
            personId: e.personId,
            summary: e.summary,
            deadlineLabel: e.deadlineLabel,
            deadlineAt: e.deadlineAt,
            finishedAt: e.finishedAt,
            responsibleUpdatedAt: now,
            publishedAt: now,
            seenAt: e.seenAt,
            lastChattedSenderAt: e.lastChattedSenderAt,
            lastChattedReceiverAt: e.lastChattedReceiverAt,
            progress: e.progress,
            health: e.health,
            type: e.type,
            status: e.status,
            visibility: ExpectationVisibility.echo,
          );
        }
        if (_pillar == LedgerPillar.expectationsOthers) {
          _outboxListingTab = _OutboxListingTab.published;
        }
      });
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Published — now visible to your receiver.')),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Failed to publish: $e')),
      );
    }
  }

  /// Writer archives an expectation: [ExpectationStatus.abandoned]. Shadow drafts stay drafts (visibility unchanged); UI stays on Drafts when applicable.
  Future<void> _archiveOutboxDraft(Expectation expectation) async {
    final currentUserId = Supabase.instance.client.auth.currentUser?.id;
    if (currentUserId == null || expectation.writerUserId != currentUserId) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Only the author can archive this item.')),
      );
      return;
    }
    final ok = await _persistExpectationAbandoned(expectation);
    if (!ok || !mounted) return;
    setState(() {
      if (_pillar == LedgerPillar.expectationsOthers) {
        _othersArchiveCollapsed = false;
        // Keep Drafts tab when archiving a shadow draft; do not imply publish.
        if (expectation.visibility != ExpectationVisibility.shadow) {
          _outboxListingTab = _OutboxListingTab.published;
        }
      }
    });
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Archived.')),
    );
  }

  /// Inbox: author or addressee (person) may mark abandoned; visibility unchanged.
  Future<void> _archiveInboxExpectation(Expectation expectation) async {
    final currentUserId = Supabase.instance.client.auth.currentUser?.id;
    final meId = _myPersonId;
    if (currentUserId == null || meId == null) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Sign in to archive this item.')),
      );
      return;
    }
    final isWriter = expectation.writerUserId == currentUserId;
    final isReceiver =
        expectation.personId.trim().isNotEmpty && expectation.personId == meId;
    if (!isWriter && !isReceiver) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('You cannot archive this item.')),
      );
      return;
    }
    final ok = await _persistExpectationAbandoned(expectation);
    if (!ok || !mounted) return;
    setState(() {
      if (_pillar == LedgerPillar.expectationsMe) {
        _meArchiveCollapsed = false;
      }
    });
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Archived.')),
    );
  }

  /// Tags pillar (Private / Public lists): writer archives a talking point.
  Future<void> _archiveTalkingPointBrowse(Expectation expectation) async {
    final currentUserId = Supabase.instance.client.auth.currentUser?.id;
    if (currentUserId == null || expectation.writerUserId != currentUserId) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Only the author can archive this item.')),
      );
      return;
    }
    final ok = await _persistExpectationAbandoned(expectation);
    if (!ok || !mounted) return;
    setState(() {
      if (_pillar == LedgerPillar.tags) {
        if (_talkingPointsSubView == _TalkingPointsSubView.colleagues) {
          _colleagueArchiveCollapsed = false;
        } else {
          _tagsArchiveCollapsed = false;
        }
      }
    });
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Archived.')),
    );
  }

  /// Private talking-point row (Tags / colleagues): shadow → echo, same as outbox publish.
  Future<void> _publishTalkingPointBrowse(Expectation expectation) async {
    final currentUserId = Supabase.instance.client.auth.currentUser?.id;
    if (currentUserId == null || expectation.writerUserId != currentUserId) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Only the author can publish this item.')),
      );
      return;
    }
    if (expectation.visibility != ExpectationVisibility.shadow) return;
    final now = DateTime.now().toUtc();
    try {
      await Supabase.instance.client.from('expectations').update({
        'expectation_visibility': ExpectationVisibility.echo.index,
        'published_at': now.toIso8601String(),
        'responsible_updated_at': now.toIso8601String(),
      }).eq('id', expectation.id);
      if (!mounted) return;
      setState(() {
        final i = _expectations.indexWhere((e) => e.id == expectation.id);
        if (i >= 0) {
          final e = _expectations[i];
          _expectations[i] = Expectation(
            id: e.id,
            createdAt: e.createdAt,
            writerUserId: e.writerUserId,
            personId: e.personId,
            summary: e.summary,
            deadlineLabel: e.deadlineLabel,
            deadlineAt: e.deadlineAt,
            finishedAt: e.finishedAt,
            responsibleUpdatedAt: now,
            publishedAt: now,
            seenAt: e.seenAt,
            lastChattedSenderAt: e.lastChattedSenderAt,
            lastChattedReceiverAt: e.lastChattedReceiverAt,
            progress: e.progress,
            health: e.health,
            type: e.type,
            status: e.status,
            visibility: ExpectationVisibility.echo,
          );
        }
      });
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Published.')),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Failed to publish: $e')),
      );
    }
  }

  /// DB + local list: status abandoned, [responsible_updated_at] updated. Returns false on failure.
  Future<bool> _persistExpectationAbandoned(Expectation expectation) async {
    final now = DateTime.now().toUtc();
    try {
      await Supabase.instance.client.from('expectations').update({
        'expectation_status': _statusToDb(ExpectationStatus.abandoned),
        'responsible_updated_at': now.toIso8601String(),
      }).eq('id', expectation.id);
      if (!mounted) return false;
      setState(() {
        final i = _expectations.indexWhere((e) => e.id == expectation.id);
        if (i >= 0) {
          final e = _expectations[i];
          _expectations[i] = Expectation(
            id: e.id,
            createdAt: e.createdAt,
            writerUserId: e.writerUserId,
            personId: e.personId,
            summary: e.summary,
            deadlineLabel: e.deadlineLabel,
            deadlineAt: e.deadlineAt,
            finishedAt: e.finishedAt,
            responsibleUpdatedAt: now,
            publishedAt: e.publishedAt,
            seenAt: e.seenAt,
            lastChattedSenderAt: e.lastChattedSenderAt,
            lastChattedReceiverAt: e.lastChattedReceiverAt,
            progress: e.progress,
            health: e.health,
            type: e.type,
            status: ExpectationStatus.abandoned,
            visibility: e.visibility,
          );
        }
      });
      return true;
    } catch (e) {
      if (!mounted) return false;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Failed to archive: $e')),
      );
      return false;
    }
  }

  void _focusComposer() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        _captureFocus.requestFocus();
      }
    });
  }

  void _goAddExpectationCapture() {
    if (_homeQuickCaptureSheetOpen) {
      Navigator.of(context).pop();
    }
    setState(() {
      _homePendingEntry = null;
      _pillar = LedgerPillar.addExpectation;
      _composerMode = _ComposerEntryMode.expectation;
      _expectationPillarQuickChoice = _ExpectationPillarQuickChoice.draft;
    });
    _focusComposer();
  }

  void _goAddTopicCapture() {
    if (_homeQuickCaptureSheetOpen) {
      Navigator.of(context).pop();
    }
    setState(() {
      _homePendingEntry = null;
      _pillar = LedgerPillar.addTopic;
      _composerMode = _ComposerEntryMode.topic;
    });
    _focusComposer();
  }

  void _syncExpectationPillarChoiceFromSaveFocus() {
    if (_pillar != LedgerPillar.addExpectation || !mounted) return;
    if (_composerSavePairFocusA.hasFocus) {
      setState(() {
        _expectationPillarQuickChoice = _ExpectationPillarQuickChoice.draft;
      });
    } else if (_composerSavePairFocusB.hasFocus) {
      setState(() {
        _expectationPillarQuickChoice =
            _ExpectationPillarQuickChoice.sendImmediately;
      });
    }
  }

  @override
  void initState() {
    super.initState();
    _homeComposerSaveRowListenable = Listenable.merge([
      _captureController,
      _homeComposerUiRevision,
    ]);
    _composerSaveRowListenable = Listenable.merge([
      _captureController,
      _captureFocus,
    ]);
    _captureController.addListener(_onCaptureChanged);
    _composerSavePairFocusA.addListener(_syncExpectationPillarChoiceFromSaveFocus);
    _composerSavePairFocusB.addListener(_syncExpectationPillarChoiceFromSaveFocus);
    _loadPeopleFromSupabase();
    _loadExpectationsFromSupabase();
    _loadRecentTagsFromSupabase();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (!_keyboardHookRegistered) {
        _keyboardHookRegistered = true;
        HardwareKeyboard.instance.addHandler(_onHardwareKey);
      }
      if (_pillar != LedgerPillar.home) {
        _captureFocus.requestFocus();
      }
    });
  }

  Future<void> _loadPeopleFromSupabase() async {
    final client = Supabase.instance.client;
    final user = client.auth.currentUser;
    if (user == null) {
      if (!mounted) return;
      setState(() {
        _peopleLoading = false;
        _peopleLoadError = 'No authenticated user.';
        _profileName = 'You';
        _profileTitle = null;
        _myPersonId = null;
        _companyName = null;
      });
      return;
    }
    try {
      final meRows = await client
          .from('people')
          .select('id,company_id,display_name,handle,email,title')
          .eq('auth_user_id', user.id)
          .limit(1);
      if ((meRows as List).isEmpty) {
        if (!mounted) return;
        setState(() {
          _peopleLoading = false;
          _peopleLoadError = 'No linked person/company found for this user.';
          _people.clear();
          _myPersonId = null;
          _companyName = null;
          _profileName = (user.email?.trim().isNotEmpty ?? false)
              ? user.email!.trim()
              : 'You';
          _profileTitle = null;
        });
        return;
      }

      final me = meRows.first as Map;
      final meId = me['id'] as String?;
      final meDisplay = ((me['display_name'] as String?) ?? '').trim();
      final meHandle = ((me['handle'] as String?) ?? '').trim();
      final meEmail = ((me['email'] as String?) ?? '').trim();
      final meTitle = ((me['title'] as String?) ?? '').trim();
      final companyId = me['company_id'] as String;
      String? loadedCompanyName;
      try {
        final companyRows = await client
            .from('companies')
            .select('name')
            .eq('id', companyId)
            .limit(1);
        if ((companyRows as List).isNotEmpty) {
          final raw = companyRows.first['name'];
          if (raw is String && raw.trim().isNotEmpty) {
            loadedCompanyName = raw.trim();
          }
        }
      } catch (_) {
        // Company name is optional for the rail label.
      }
      final rows = await client
          .from('people')
          .select('id,created_at,display_name,handle,auth_user_id,email,title')
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
              authUserId: (r['auth_user_id'] as String?)?.trim(),
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
        _myPersonId = meId;
        _peopleLoading = false;
        _peopleLoadError = null;
        _profileName = meDisplay.isNotEmpty
            ? meDisplay
            : (meHandle.isNotEmpty
                ? meHandle
                : (meEmail.isNotEmpty
                    ? meEmail
                    : ((user.email?.trim().isNotEmpty ?? false)
                        ? user.email!.trim()
                        : 'You')));
        _profileTitle = meTitle.isEmpty ? null : meTitle;
        _companyName = loadedCompanyName;
      });
    } on PostgrestException catch (e) {
      if (!mounted) return;
      setState(() {
        _peopleLoading = false;
        _peopleLoadError = 'Failed to load people: ${e.message}';
        _myPersonId = null;
        _companyName = null;
        _profileName = (user.email?.trim().isNotEmpty ?? false)
            ? user.email!.trim()
            : 'You';
        _profileTitle = null;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _peopleLoading = false;
        _peopleLoadError = 'Failed to load people: $e';
        _myPersonId = null;
        _companyName = null;
        _profileName = (user.email?.trim().isNotEmpty ?? false)
            ? user.email!.trim()
            : 'You';
        _profileTitle = null;
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
          _recentTagsHasMore = false;
        });
        return;
      }

      final companyId = meRows.first['company_id'] as String;
      // Public rail only: published talking points (echo + topic + no addressee),
      // same constraints as [_mergedPublicRailTags] in-memory pool — not shadow/private rows.
      final rows = await client
          .from('expectations')
          .select('summary,created_at,target_person_id')
          .eq('company_id', companyId)
          .eq('expectation_type', ExpectationType.topic.index)
          .eq('expectation_visibility', ExpectationVisibility.echo.index)
          .order('created_at', ascending: false)
          .limit(200);

      final seen = <String>{};
      final tags = <String>[];
      for (final row in (rows as List)) {
        final rawTarget = row['target_person_id'];
        final personKey = rawTarget == null
            ? ''
            : (rawTarget as String).trim();
        if (personKey.isNotEmpty) continue;
        final summary = ((row['summary'] as String?) ?? '').trim();
        if (summary.isEmpty) continue;
        for (final tag in _extractInlineTags(summary)) {
          final key = tag.toLowerCase();
          if (seen.add(key)) {
            tags.add(tag);
          }
          if (tags.length > 20) break;
        }
        if (tags.length > 20) break;
      }

      final hasMore = tags.length > 20;
      final stored = tags.take(20).toList();

      if (!mounted) return;
      setState(() {
        _recentTags
          ..clear()
          ..addAll(stored);
        _recentTagsHasMore = hasMore;
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

  Future<void> _loadExpectationsFromSupabase() async {
    final client = Supabase.instance.client;
    final user = client.auth.currentUser;
    if (user == null) {
      if (!mounted) return;
      setState(() {
        _expectationsLoading = false;
        _expectationsLoadError = 'No authenticated user.';
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
          _expectationsLoading = false;
          _expectationsLoadError = 'No linked person/company found for this user.';
          _expectations.clear();
        });
        return;
      }
      final companyId = meRows.first['company_id'] as String;
      final rows = await client
          .from('expectations')
          .select(
            'id,created_at,writer_user_id,target_person_id,summary,deadline_label,deadline_at,finished_at,responsible_updated_at,published_at,seen_at,last_chatted_sender_at,last_chatted_receiver_at,progress,expectation_status,expectation_health,expectation_visibility,expectation_type',
          )
          .eq('company_id', companyId)
          .order('created_at', ascending: false);

      final mapped = (rows as List).map((r) {
        final statusIdx = (r['expectation_status'] as num?)?.toInt() ?? 0;
        final healthIdx = (r['expectation_health'] as num?)?.toInt() ?? 0;
        final visIdx = (r['expectation_visibility'] as num?)?.toInt() ?? 0;
        final typeIdx = (r['expectation_type'] as num?)?.toInt() ?? 0;
        final status = _statusFromDb(statusIdx);
        final health = _healthFromDb(healthIdx);
        final type = _typeFromDb(typeIdx);
        final visibility =
            (visIdx >= 0 && visIdx < ExpectationVisibility.values.length)
            ? ExpectationVisibility.values[visIdx]
            : ExpectationVisibility.shadow;
        return Expectation(
          id: r['id'] as String,
          createdAt: DateTime.tryParse(r['created_at'] as String? ?? '') ??
              DateTime.now().toUtc(),
          writerUserId: r['writer_user_id'] as String?,
          personId: (r['target_person_id'] as String?) ?? '',
          summary: ((r['summary'] as String?) ?? '').trim(),
          deadlineLabel: ((r['deadline_label'] as String?) ?? 'TBD').trim(),
          deadlineAt: DateTime.tryParse((r['deadline_at'] as String?) ?? ''),
          finishedAt: DateTime.tryParse((r['finished_at'] as String?) ?? ''),
          responsibleUpdatedAt: DateTime.tryParse(
            (r['responsible_updated_at'] as String?) ?? '',
          ),
          publishedAt: DateTime.tryParse((r['published_at'] as String?) ?? '') ??
              (visIdx == ExpectationVisibility.echo.index
                  ? DateTime.tryParse(r['created_at'] as String? ?? '')
                  : null),
          seenAt: DateTime.tryParse((r['seen_at'] as String?) ?? ''),
          lastChattedSenderAt: DateTime.tryParse(
            (r['last_chatted_sender_at'] as String?) ?? '',
          ),
          lastChattedReceiverAt: DateTime.tryParse(
            (r['last_chatted_receiver_at'] as String?) ?? '',
          ),
          progress: (r['progress'] as num?)?.toInt(),
          health: health,
          type: type,
          status: status,
          visibility: visibility,
        );
      }).toList();

      if (!mounted) return;
      setState(() {
        _expectations
          ..clear()
          ..addAll(mapped);
        _expectationsLoading = false;
        _expectationsLoadError = null;
      });
    } on PostgrestException catch (e) {
      if (!mounted) return;
      setState(() {
        _expectationsLoading = false;
        _expectationsLoadError = 'Failed to load expectations: ${e.message}';
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _expectationsLoading = false;
        _expectationsLoadError = 'Failed to load expectations: $e';
      });
    }
  }

  @override
  void dispose() {
    if (_keyboardHookRegistered) {
      HardwareKeyboard.instance.removeHandler(_onHardwareKey);
    }
    _captureController.removeListener(_onCaptureChanged);
    _composerSavePairFocusA.removeListener(_syncExpectationPillarChoiceFromSaveFocus);
    _composerSavePairFocusB.removeListener(_syncExpectationPillarChoiceFromSaveFocus);
    _homeComposerUiRevision.dispose();
    _captureController.dispose();
    _captureFocus.dispose();
    _composerSavePairFocusA.dispose();
    _composerSavePairFocusB.dispose();
    _homeVisSaveFocusA.dispose();
    _homeVisSaveFocusB.dispose();
    _scrollController.dispose();
    _composerToastTimer?.cancel();
    super.dispose();
  }

  bool _shiftDown() {
    final pressed = HardwareKeyboard.instance.logicalKeysPressed;
    return pressed.contains(LogicalKeyboardKey.shiftLeft) ||
        pressed.contains(LogicalKeyboardKey.shiftRight);
  }

  bool _quickCaptureModifierHeld() {
    final pressed = HardwareKeyboard.instance.logicalKeysPressed;
    return pressed.contains(LogicalKeyboardKey.controlLeft) ||
        pressed.contains(LogicalKeyboardKey.controlRight) ||
        pressed.contains(LogicalKeyboardKey.metaLeft) ||
        pressed.contains(LogicalKeyboardKey.metaRight) ||
        pressed.contains(LogicalKeyboardKey.altLeft) ||
        pressed.contains(LogicalKeyboardKey.altRight);
  }

  /// True when the user is typing in a text field (do not steal Q for Quick Capture).
  bool _typingInEditableText() {
    final node = FocusManager.instance.primaryFocus;
    final ctx = node?.context;
    if (ctx == null) return false;
    if (ctx.widget is EditableText) return true;
    return ctx.findAncestorWidgetOfExactType<EditableText>() != null;
  }

  /// True when @/# autocomplete is showing and Enter should complete (not submit / newline).
  bool _composerHasActiveTokenPick() {
    return _uniqueMentionSuggestion != null ||
        _uniqueTagSuggestion != null ||
        _mentionInlineCandidates.length > 1 ||
        _tagInlineCandidates.length > 1;
  }

  /// Tab cycles suggestion chips only when multiple matches exist (unique picks use Enter).
  bool _composerHasMultiTokenPick() {
    return _mentionInlineCandidates.length > 1 ||
        _tagInlineCandidates.length > 1;
  }

  bool _composerHasSavePairButtonsPillar() {
    if (_pillar == LedgerPillar.home) return _homeQuickCaptureSheetOpen;
    return _pillar == LedgerPillar.addTopic ||
        _pillar == LedgerPillar.addExpectation;
  }

  bool _focusInComposerSaveCycleGroup() {
    if (_pillar == LedgerPillar.home && _homePendingEntry != null) {
      return _captureFocus.hasFocus ||
          _homeVisSaveFocusA.hasFocus ||
          _homeVisSaveFocusB.hasFocus;
    }
    return _captureFocus.hasFocus ||
        _composerSavePairFocusA.hasFocus ||
        _composerSavePairFocusB.hasFocus;
  }

  /// (firstButton, secondButton) enabled flags for the two save actions under the composer.
  (bool, bool) _composerSavePairButtonEnabledFlags() {
    final busy = _submitInFlight;
    final t = _captureController.text;
    switch (_pillar) {
      case LedgerPillar.home:
        if (_homePendingEntry == _ComposerEntryMode.topic) {
          final priv = _talkingPointPrivateSubmittable(t) && !busy;
          final pub = _talkingPointPublicSubmittable(t) && !busy;
          return (priv, pub);
        }
        if (_homePendingEntry == _ComposerEntryMode.expectation) {
          final e = _composerCaptureTextIsSubmittable(t) &&
              _talkingPointLineHasPersonMention(t) &&
              !busy;
          return (e, e);
        }
        return (
          _talkingPointPrivateSubmittable(t) && !busy,
          _composerCaptureTextIsSubmittable(t) &&
              _talkingPointLineHasPersonMention(t) &&
              !busy,
        );
      case LedgerPillar.addTopic:
        return (
          _talkingPointPrivateSubmittable(t) && !busy,
          _talkingPointPublicSubmittable(t) && !busy,
        );
      case LedgerPillar.addExpectation:
        final e = _composerCaptureTextIsSubmittable(t) && !busy;
        return (e, e);
      default:
        return (false, false);
    }
  }

  void _cycleComposerSaveFocus({required bool forward}) {
    final (enA, enB) = _composerSavePairButtonEnabledFlags();
    // Build order matches the save [Row]: first [Expanded] = left, second = right (LTR).
    final List<FocusNode> nodes;
    final List<bool> canFocus;
    var cur = 0;

    if (_pillar == LedgerPillar.home && _homePendingEntry != null) {
      nodes = [_captureFocus, _homeVisSaveFocusA, _homeVisSaveFocusB];
      canFocus = [true, enA, enB];
      if (_captureFocus.hasFocus &&
          !_homeVisSaveFocusA.hasFocus &&
          !_homeVisSaveFocusB.hasFocus) {
        cur = 0;
      } else if (_homeVisSaveFocusA.hasFocus) {
        cur = 1;
      } else if (_homeVisSaveFocusB.hasFocus) {
        cur = 2;
      }
    } else {
      nodes = [
        _captureFocus,
        _composerSavePairFocusA,
        _composerSavePairFocusB,
      ];
      canFocus = [true, enA, enB];
      if (_captureFocus.hasFocus &&
          !_composerSavePairFocusA.hasFocus &&
          !_composerSavePairFocusB.hasFocus) {
        cur = 0;
      } else if (_composerSavePairFocusA.hasFocus) {
        cur = 1;
      } else if (_composerSavePairFocusB.hasFocus) {
        cur = 2;
      }
    }

    for (var step = 0; step < 6; step++) {
      cur = forward ? (cur + 1) % 3 : (cur - 1 + 3) % 3;
      if (canFocus[cur]) {
        nodes[cur].requestFocus();
        return;
      }
    }
    _captureFocus.requestFocus();
  }

  /// Tab / Shift+Tab for the composer block: handled here so Flutter's default
  /// [NextFocusIntent] does not pick the wrong button order or jump into the list.
  KeyEventResult _onComposerBlockKeyEvent(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    if (event.logicalKey != LogicalKeyboardKey.tab) {
      return KeyEventResult.ignored;
    }
    if (!_composerHasSavePairButtonsPillar()) {
      return KeyEventResult.ignored;
    }
    if (!_focusInComposerSaveCycleGroup()) {
      return KeyEventResult.ignored;
    }
    if (_composerHasMultiTokenPick() && _captureFocus.hasFocus) {
      _onComposerTabPressed();
      return KeyEventResult.handled;
    }
    _cycleComposerSaveFocus(forward: !_shiftDown());
    return KeyEventResult.handled;
  }

  bool _onHardwareKey(KeyEvent event) {
    if (event is! KeyDownEvent) return false;

    if (event.logicalKey == LogicalKeyboardKey.keyQ &&
        !_shiftDown() &&
        !_quickCaptureModifierHeld()) {
      if (_typingInEditableText()) return false;
      if (_homeQuickCaptureSheetOpen) return true;
      _openHomeQuickCaptureModal();
      return true;
    }

    if (!_composerHasSavePairButtonsPillar()) {
      if (!_captureFocus.hasFocus) return false;
    } else if (!_focusInComposerSaveCycleGroup()) {
      return false;
    }
    if (event.logicalKey == LogicalKeyboardKey.enter && !_shiftDown()) {
      if (_submitInFlight) return true;
      // Let [CommandCaptureBar] CallbackShortcuts handle Enter (return false). Includes
      // unique @/# picks so Home submit / swallow does not run and steal focus.
      if (_composerHasActiveTokenPick() && _captureFocus.hasFocus) {
        return false;
      }
      if (_pillar == LedgerPillar.home) {
        final mode = _homeEnterResolvedComposerMode(_captureController.text);
        if (mode == null) return true;
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted) return;
          setState(() {
            _composerMode = mode;
            _homePendingEntry = mode;
          });
          _homeComposerUiRevision.value++;
          _scheduleFocusFirstHomeVisibilitySaveButton();
        });
        return true;
      }
      if (_pillar == LedgerPillar.addExpectation) {
        final text = _captureController.text;
        if (!_composerCaptureTextIsSubmittable(text) || _submitInFlight) {
          return true;
        }
        final forced =
            _expectationPillarQuickChoice == _ExpectationPillarQuickChoice.draft
                ? ExpectationVisibility.shadow
                : ExpectationVisibility.echo;
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted) return;
          unawaited(_submitCapture(forcedExpectationVisibility: forced));
        });
        return true;
      }
      if (_pillar == LedgerPillar.addTopic) {
        final text = _captureController.text;
        if (!_talkingPointPrivateSubmittable(text) || _submitInFlight) {
          return true;
        }
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted) return;
          unawaited(
            _submitCapture(
              forcedTalkingPointVisibility: ExpectationVisibility.shadow,
            ),
          );
        });
        return true;
      }
      return false;
    }
    return false;
  }

  void _confirmInlineComposerPick() {
    if (_mentionInlineCandidates.length > 1) {
      final p = _mentionInlineCandidates[
          _composerPickIndex % _mentionInlineCandidates.length];
      _insertMention(p);
      return;
    }
    if (_tagInlineCandidates.length > 1) {
      final t =
          _tagInlineCandidates[_composerPickIndex % _tagInlineCandidates.length];
      _insertTag(t);
      return;
    }
    if (_uniqueMentionSuggestion != null) {
      _insertMention(_uniqueMentionSuggestion!);
      return;
    }
    if (_uniqueTagSuggestion != null) {
      _insertTag(_uniqueTagSuggestion!);
    }
  }

  void _onComposerTabPressed() {
    if (!_captureFocus.hasFocus) return;
    final reverse = _shiftDown();

    if (_mentionInlineCandidates.length > 1) {
      final n = _mentionInlineCandidates.length;
      setState(() {
        _composerPickIndex = reverse
            ? (_composerPickIndex - 1 + n) % n
            : (_composerPickIndex + 1) % n;
      });
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _captureFocus.requestFocus();
      });
      return;
    }
    if (_tagInlineCandidates.length > 1) {
      final n = _tagInlineCandidates.length;
      setState(() {
        _composerPickIndex = reverse
            ? (_composerPickIndex - 1 + n) % n
            : (_composerPickIndex + 1) % n;
      });
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _captureFocus.requestFocus();
      });
      return;
    }

    final mention = _uniqueMentionSuggestion;
    final tag = _uniqueTagSuggestion;
    if (mention != null) {
      _insertMention(mention);
    } else if (tag != null) {
      _insertTag(tag);
    }
    _captureFocus.requestFocus();
  }

  void _onCaptureChanged() {
    final value = _captureController.value;
    final selection = value.selection;
    if (!selection.isValid || !selection.isCollapsed) {
      _clearTokenAutocomplete();
      return;
    }
    final caret = selection.baseOffset;
    if (caret < 0 || caret > value.text.length) {
      _clearTokenAutocomplete();
      return;
    }
    final beforeCaret = value.text.substring(0, caret);
    final match = RegExp(r'@([a-zA-Z0-9._-]*)$').firstMatch(beforeCaret);
    final tagMatch = RegExp(r'#([a-zA-Z0-9._-]*)$').firstMatch(beforeCaret);
    if (match == null && tagMatch == null) {
      _clearTokenAutocomplete();
      return;
    }
    if (match != null) {
      final query = (match.group(1) ?? '').toLowerCase();
      final start = match.start;
      final end = caret;
      final handleHits = query.isEmpty
          ? <Person>[]
          : _people
              .where((p) => p.handle.toLowerCase().startsWith(query))
              .toList();
      final broadHits = _people.where((p) {
        final handle = p.handle.toLowerCase();
        final display = p.displayName.toLowerCase();
        return query.isEmpty || handle.startsWith(query) || display.startsWith(query);
      }).toList();
      String? disambiguation;
      Person? unique;
      if (query.isEmpty) {
        unique = null;
        if (_people.isNotEmpty) {
          disambiguation = 'Type after @ to narrow people';
        }
      } else if (handleHits.length == 1) {
        unique = handleHits.single;
      } else if (handleHits.isEmpty && broadHits.length == 1) {
        unique = broadHits.single;
      } else if (handleHits.length > 1) {
        unique = null;
      } else {
        unique = null;
      }
      final alreadyComplete = unique != null && unique.handle.toLowerCase() == query;
      setState(() {
        _activeMentionQuery = query;
        _activeMentionStart = start;
        _activeMentionEnd = end;
        _uniqueMentionSuggestion = alreadyComplete ? null : unique;
        _mentionDisambiguationHint = disambiguation;
        _mentionInlineCandidates = handleHits.length > 1
            ? (List<Person>.from(handleHits)..sort(
                (a, b) => a.handle.toLowerCase().compareTo(b.handle.toLowerCase()),
              ))
            : <Person>[];
        _composerPickIndex = 0;
        _activeTagQuery = null;
        _activeTagStart = null;
        _activeTagEnd = null;
        _uniqueTagSuggestion = null;
        _tagInlineCandidates = [];
      });
      return;
    }
    final query = (tagMatch?.group(1) ?? '').toLowerCase();
    final start = tagMatch!.start;
    final end = caret;
    if (query.isEmpty) {
      _clearTokenAutocomplete();
      return;
    }
    final tagHits = _hashtagAutocompletePool()
        .where((tag) => tag.toLowerCase().startsWith(query))
        .toList();
    tagHits.sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
    String? uniqueTag;
    List<String> tagInline = [];
    if (query.isEmpty) {
      uniqueTag = null;
    } else if (tagHits.length == 1) {
      uniqueTag = tagHits.single;
    } else if (tagHits.length <= 14) {
      uniqueTag = null;
      tagInline = List<String>.from(tagHits);
    } else {
      uniqueTag = null;
    }
    final alreadyComplete = uniqueTag != null && uniqueTag.toLowerCase() == query;
    setState(() {
      _activeTagQuery = query;
      _activeTagStart = start;
      _activeTagEnd = end;
      _uniqueTagSuggestion = alreadyComplete ? null : uniqueTag;
      _tagInlineCandidates = tagInline;
      _composerPickIndex = 0;
      _activeMentionQuery = null;
      _activeMentionStart = null;
      _activeMentionEnd = null;
      _uniqueMentionSuggestion = null;
      _mentionDisambiguationHint = null;
      _mentionInlineCandidates = [];
    });
  }

  void _clearComposerAutocompleteInPlace() {
    _activeMentionQuery = null;
    _activeMentionStart = null;
    _activeMentionEnd = null;
    _uniqueMentionSuggestion = null;
    _mentionDisambiguationHint = null;
    _mentionInlineCandidates = [];
    _activeTagQuery = null;
    _activeTagStart = null;
    _activeTagEnd = null;
    _uniqueTagSuggestion = null;
    _tagInlineCandidates = [];
    _composerPickIndex = 0;
  }

  void _clearTokenAutocomplete() {
    if (_activeMentionQuery == null &&
        _uniqueMentionSuggestion == null &&
        _mentionDisambiguationHint == null &&
        _mentionInlineCandidates.isEmpty &&
        _activeTagQuery == null &&
        _uniqueTagSuggestion == null &&
        _tagInlineCandidates.isEmpty) {
      return;
    }
    setState(_clearComposerAutocompleteInPlace);
  }

  void _insertMention(Person person) {
    final start = _activeMentionStart;
    final end = _activeMentionEnd;
    if (start == null || end == null) return;
    final value = _captureController.value;
    if (start < 0 || end < start || end > value.text.length) return;
    final prefix = value.text.substring(0, start);
    final suffix = value.text.substring(end);
    final replacement = '@${person.handle}';
    final spacer = suffix.startsWith(' ') || suffix.startsWith('\n') ? '' : ' ';
    final nextText = '$prefix$replacement$spacer$suffix';
    final nextCaret = (prefix + replacement + spacer).length;
    _captureController.value = TextEditingValue(
      text: nextText,
      selection: TextSelection.collapsed(offset: nextCaret),
    );
    _clearTokenAutocomplete();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _captureFocus.requestFocus();
    });
  }

  void _insertTag(String tag) {
    final start = _activeTagStart;
    final end = _activeTagEnd;
    if (start == null || end == null) return;
    final value = _captureController.value;
    if (start < 0 || end < start || end > value.text.length) return;
    final prefix = value.text.substring(0, start);
    final suffix = value.text.substring(end);
    final replacement = '#$tag';
    final spacer = suffix.startsWith(' ') || suffix.startsWith('\n') ? '' : ' ';
    final nextText = '$prefix$replacement$spacer$suffix';
    final nextCaret = (prefix + replacement + spacer).length;
    _captureController.value = TextEditingValue(
      text: nextText,
      selection: TextSelection.collapsed(offset: nextCaret),
    );
    _clearTokenAutocomplete();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _captureFocus.requestFocus();
    });
  }

  /// Chip label: icon already shows @ / #; strip a redundant prefix if present.
  static String _composerChipHandleLabel(String handle) {
    final t = handle.trim();
    return t.startsWith('@') ? t.substring(1) : t;
  }

  static String _composerChipTagLabel(String tag) {
    final t = tag.trim();
    return t.startsWith('#') ? t.substring(1) : t;
  }

  Widget _composerMentionPickChip(
    ColorScheme scheme,
    TextStyle? chipStyle,
    Person p,
    int index,
    int total,
  ) {
    final sel = index == (_composerPickIndex % total);
    return InkWell(
      borderRadius: BorderRadius.circular(20),
      onTap: () => _insertMention(p),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 7),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(20),
          color: sel
              ? scheme.primaryContainer.withValues(alpha: 0.65)
              : scheme.surfaceContainerHigh.withValues(alpha: 0.55),
          border: Border.all(
            color: sel
                ? scheme.primary.withValues(alpha: 0.75)
                : scheme.outline.withValues(alpha: 0.22),
            width: sel ? 2 : 1,
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.alternate_email,
              size: 16,
              color: sel ? scheme.onPrimaryContainer : scheme.onSurfaceVariant,
            ),
            const SizedBox(width: 5),
            Text(
              _composerChipHandleLabel(p.handle),
              style: chipStyle?.copyWith(
                color: sel ? scheme.onPrimaryContainer : scheme.onSurface,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _composerTagPickChip(
    ColorScheme scheme,
    TextStyle? chipStyle,
    String tag,
    int index,
    int total,
  ) {
    final sel = index == (_composerPickIndex % total);
    return InkWell(
      borderRadius: BorderRadius.circular(20),
      onTap: () => _insertTag(tag),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 7),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(20),
          color: sel
              ? scheme.primaryContainer.withValues(alpha: 0.65)
              : scheme.surfaceContainerHigh.withValues(alpha: 0.55),
          border: Border.all(
            color: sel
                ? scheme.primary.withValues(alpha: 0.75)
                : scheme.outline.withValues(alpha: 0.22),
            width: sel ? 2 : 1,
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.tag,
              size: 16,
              color: sel ? scheme.onPrimaryContainer : scheme.onSurfaceVariant,
            ),
            const SizedBox(width: 5),
            Text(
              _composerChipTagLabel(tag),
              style: chipStyle?.copyWith(
                color: sel ? scheme.onPrimaryContainer : scheme.onSurface,
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// Shared composer for Home, Add expectation, and Add talking point: one
  /// [CommandCaptureBar], same @/# autocomplete, chips, Tab/Enter, and focus rules.
  Widget _buildComposerCommandCaptureBar(
    ThemeData theme,
    ColorScheme scheme, {
    GlobalKey? homeCaptureHostKey,
  }) {
    final inner = Padding(
      padding: EdgeInsets.symmetric(
        vertical: _pillar == LedgerPillar.home ? 12 : 8,
      ),
      child: CommandCaptureBar(
        controller: _captureController,
        focusNode: _captureFocus,
        accentColor: _pillar.captureAccent,
        hintText: _composerCaptureHintForPillar(),
        suggestionsPanel: _composerTokenSuggestionsPanel(theme, scheme),
        inlinePickActive: _composerHasActiveTokenPick(),
        onInlinePickConfirm: _confirmInlineComposerPick,
        refocusRequestToken:
            _pillar == LedgerPillar.home ? _homeCaptureRefocusToken : null,
      ),
    );
    if (homeCaptureHostKey != null) {
      return KeyedSubtree(key: homeCaptureHostKey, child: inner);
    }
    return inner;
  }

  /// Home capture UI (same state as the screen; shown inside the Quick Capture sheet).
  Widget _buildHomeQuickCaptureModalBody({
    required ThemeData theme,
    required ColorScheme scheme,
  }) {
    return Focus(
      skipTraversal: true,
      canRequestFocus: false,
      descendantsAreFocusable: true,
      onKeyEvent: _onComposerBlockKeyEvent,
      child: Column(
        key: ValueKey<int>(_homeComposerBlockKey),
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  'Quick Capture',
                  style: theme.textTheme.titleLarge?.copyWith(
                    fontWeight: FontWeight.w700,
                    color: scheme.onSurface,
                  ),
                ),
              ),
              IconButton(
                tooltip: 'Close',
                onPressed: () => Navigator.of(context).maybePop(),
                icon: const Icon(Icons.close_rounded),
              ),
            ],
          ),
          const SizedBox(height: 8),
          _HomeComposerLeadBubble(theme: theme, scheme: scheme),
          const SizedBox(height: 18),
          _buildComposerCommandCaptureBar(
            theme,
            scheme,
            homeCaptureHostKey: _homeComposerCaptureHostKey,
          ),
          const SizedBox(height: 16),
          ListenableBuilder(
            listenable: _homeComposerSaveRowListenable,
            builder: (context, _) {
              final value = _captureController.value;
              final homePending = _homePendingEntry;
              final canSaveExpectation =
                  _composerCaptureTextIsSubmittable(value.text);
              final canSaveTalkingPoint =
                  _talkingPointPrivateSubmittable(value.text);
              final hasPerson = _talkingPointLineHasPersonMention(value.text);
              final busy = _submitInFlight;
              final tpEnabled = canSaveTalkingPoint && !busy;
              final expEnabled = canSaveExpectation && hasPerson && !busy;
              final (enA, enB) = _composerSavePairButtonEnabledFlags();

              if (homePending == null) {
                return Row(
                  children: [
                    Expanded(
                      child: _PairedSaveAction(
                        focusNode: _composerSavePairFocusA,
                        enabled: tpEnabled,
                        onPressed: _submitHomeAsTalkingPoint,
                        label: 'Save as Talking Point',
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: _PairedSaveAction(
                        focusNode: _composerSavePairFocusB,
                        enabled: expEnabled,
                        onPressed: _submitHomeAsExpectation,
                        label: 'Save as Expectation',
                      ),
                    ),
                  ],
                );
              }
              if (homePending == _ComposerEntryMode.topic) {
                return Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    ExcludeFocus(
                      child: IconButton(
                        tooltip: 'Choose capture type again',
                        onPressed: busy
                            ? null
                            : () {
                                setState(() {
                                  _homePendingEntry = null;
                                  _composerMode = _composerDefaultMode;
                                });
                                _homeComposerUiRevision.value++;
                              },
                        icon: const Icon(Icons.arrow_back_rounded),
                        visualDensity: VisualDensity.compact,
                      ),
                    ),
                    const SizedBox(width: 4),
                    Expanded(
                      child: _PairedSaveAction(
                        focusNode: _homeVisSaveFocusA,
                        enabled: enA,
                        autofocus: true,
                        onPressed: () => unawaited(
                          _submitCapture(
                            forcedTalkingPointVisibility:
                                ExpectationVisibility.shadow,
                          ),
                        ),
                        label: 'Save privately',
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: _PairedSaveAction(
                        focusNode: _homeVisSaveFocusB,
                        enabled: enB,
                        onPressed: () => unawaited(
                          _submitCapture(
                            forcedTalkingPointVisibility:
                                ExpectationVisibility.echo,
                          ),
                        ),
                        label: 'Save publicly',
                      ),
                    ),
                  ],
                );
              }
              return Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  ExcludeFocus(
                    child: IconButton(
                      tooltip: 'Choose capture type again',
                      onPressed: busy
                          ? null
                          : () {
                              setState(() {
                                _homePendingEntry = null;
                                _composerMode = _composerDefaultMode;
                              });
                              _homeComposerUiRevision.value++;
                            },
                      icon: const Icon(Icons.arrow_back_rounded),
                      visualDensity: VisualDensity.compact,
                    ),
                  ),
                  const SizedBox(width: 4),
                  Expanded(
                    child: _PairedSaveAction(
                      focusNode: _homeVisSaveFocusA,
                      enabled: enA,
                      autofocus: true,
                      onPressed: () => unawaited(
                        _submitCapture(
                          forcedExpectationVisibility:
                              ExpectationVisibility.shadow,
                        ),
                      ),
                      label: 'Save as Draft',
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: _PairedSaveAction(
                      focusNode: _homeVisSaveFocusB,
                      enabled: enB,
                      onPressed: () => unawaited(
                        _submitCapture(
                          forcedExpectationVisibility:
                              ExpectationVisibility.echo,
                        ),
                      ),
                      label: 'Send immediately',
                    ),
                  ),
                ],
              );
            },
          ),
          if (_composerToastMessage != null)
            Container(
              width: double.infinity,
              margin: const EdgeInsets.only(top: 12, bottom: 4),
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
        ],
      ),
    );
  }

  void _openHomeQuickCaptureModal() {
    if (!mounted) return;
    if (_homeQuickCaptureSheetOpen) return;

    final switchToHome = _pillar != LedgerPillar.home;
    setState(() {
      _homeQuickCaptureSheetOpen = true;
      if (switchToHome) {
        _homePendingEntry = null;
        _pillar = LedgerPillar.home;
      }
    });

    final theme = Theme.of(context);
    final barrierLabel =
        MaterialLocalizations.of(context).modalBarrierDismissLabel;

    unawaited(
      showGeneralDialog<void>(
        context: context,
        barrierDismissible: true,
        barrierLabel: barrierLabel,
        barrierColor: theme.colorScheme.scrim.withValues(alpha: 0.45),
        transitionDuration: const Duration(milliseconds: 90),
        pageBuilder: (dialogContext, animation, secondaryAnimation) {
          final mq = MediaQuery.of(dialogContext);
          final dialogTheme = Theme.of(dialogContext);
          return FadeTransition(
            opacity: CurvedAnimation(
              parent: animation,
              curve: Curves.easeOut,
            ),
            child: Center(
              child: Dialog(
                backgroundColor:
                    dialogTheme.colorScheme.surfaceContainerHigh,
                insetPadding:
                    const EdgeInsets.symmetric(horizontal: 28, vertical: 36),
                clipBehavior: Clip.antiAlias,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(20),
                ),
                child: ConstrainedBox(
                  constraints: BoxConstraints(
                    maxWidth: 560,
                    maxHeight: mq.size.height * 0.88,
                  ),
                  child: ListenableBuilder(
                    listenable: _homeComposerSaveRowListenable,
                    builder: (context, _) {
                      return Padding(
                        padding: EdgeInsets.only(
                          bottom:
                              MediaQuery.viewInsetsOf(dialogContext).bottom,
                        ),
                        child: SingleChildScrollView(
                          child: Padding(
                            padding: const EdgeInsets.fromLTRB(20, 20, 20, 24),
                            child: _buildHomeQuickCaptureModalBody(
                              theme: dialogTheme,
                              scheme: dialogTheme.colorScheme,
                            ),
                          ),
                        ),
                      );
                    },
                  ),
                ),
              ),
            ),
          );
        },
      ).whenComplete(() {
        if (!mounted) return;
        setState(() {
          _homeQuickCaptureSheetOpen = false;
        });
      }),
    );
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _pillar != LedgerPillar.home) return;
      _captureFocus.requestFocus();
    });
  }

  String _composerCaptureHintForPillar() {
    if (_pillar == LedgerPillar.addExpectation) {
      return 'Capture an expectation. Use @<name> (or @me) and #hashtags. '
          'While completing @ or #, Tab completes or cycles matches; Enter inserts. '
          'Otherwise Tab moves between the field and the two save buttons (Shift+Tab reverse); '
          'Enter from the field matches the highlighted save (Save as Draft while you type, '
          'or whichever you Tab-selected last).';
    }
    if (_pillar == LedgerPillar.addTopic) {
      return 'Talking-point line: use #hashtags for public threads, or @person for a private colleague note (no # required). '
          'While completing @ or #, Tab completes or cycles matches; Enter inserts. '
          'Otherwise Tab moves between the field, Save privately, and Save publicly; '
          'Enter from the field saves privately (same as Save privately).';
    }
    if (_pillar == LedgerPillar.home) {
      if (_homePendingEntry == _ComposerEntryMode.topic) {
        return 'Choose Save privately or Save publicly (back arrow to re-pick type).';
      }
      if (_homePendingEntry == _ComposerEntryMode.expectation) {
        return 'Choose Save as Draft or Send immediately (back arrow to re-pick type).';
      }
      return 'Type your line. @ and # as needed; expectations need @someone. '
          'Tab completes a pick; Enter inserts while picking, otherwise saves or moves on.';
    }
    return 'Use @people and #tags where helpful.';
  }

  Widget? _composerTokenSuggestionsPanel(ThemeData theme, ColorScheme scheme) {
    if (_uniqueMentionSuggestion == null &&
        _mentionInlineCandidates.isEmpty &&
        (_mentionDisambiguationHint == null || _mentionDisambiguationHint!.isEmpty) &&
        _uniqueTagSuggestion == null &&
        _tagInlineCandidates.isEmpty) {
      return null;
    }
    final chipStyle = theme.textTheme.labelLarge?.copyWith(
      fontFamily: 'monospace',
      fontWeight: FontWeight.w500,
    );
    final hintStyle = theme.textTheme.labelSmall?.copyWith(
      color: scheme.onSurfaceVariant.withValues(alpha: 0.78),
    );
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 0, 12, 10),
      child: ExcludeFocus(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            if (_mentionDisambiguationHint != null &&
                _mentionDisambiguationHint!.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Text(
                  _mentionDisambiguationHint!,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: scheme.onSurfaceVariant.withValues(alpha: 0.92),
                  ),
                ),
              ),
            if (_uniqueMentionSuggestion != null ||
                _mentionInlineCandidates.isNotEmpty ||
                _uniqueTagSuggestion != null ||
                _tagInlineCandidates.isNotEmpty)
              Wrap(
                spacing: 6,
                runSpacing: 6,
                children: [
                  if (_uniqueMentionSuggestion != null)
                    _composerMentionPickChip(
                      scheme,
                      chipStyle,
                      _uniqueMentionSuggestion!,
                      0,
                      1,
                    ),
                  ..._mentionInlineCandidates.asMap().entries.map(
                        (e) => _composerMentionPickChip(
                          scheme,
                          chipStyle,
                          e.value,
                          e.key,
                          _mentionInlineCandidates.length,
                        ),
                      ),
                  if (_uniqueTagSuggestion != null)
                    _composerTagPickChip(
                      scheme,
                      chipStyle,
                      _uniqueTagSuggestion!,
                      0,
                      1,
                    ),
                  ..._tagInlineCandidates.asMap().entries.map(
                        (e) => _composerTagPickChip(
                          scheme,
                          chipStyle,
                          e.value,
                          e.key,
                          _tagInlineCandidates.length,
                        ),
                      ),
                ],
              ),
            if (_uniqueMentionSuggestion != null || _uniqueTagSuggestion != null)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Text('Tab or click to insert', style: hintStyle),
              )
            else if (_mentionInlineCandidates.isNotEmpty || _tagInlineCandidates.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Text(
                  'Tab to cycle selection · Enter to insert · Shift+Tab reverse · '
                  'or click a match',
                  style: hintStyle,
                ),
              ),
          ],
        ),
      ),
    );
  }

  bool _talkingPointCaptureContext() {
    return _pillar == LedgerPillar.addTopic;
  }

  bool _expectationCaptureContext() {
    return _pillar == LedgerPillar.addExpectation;
  }

  void _submitHomeAsTalkingPoint() {
    setState(() {
      _composerMode = _ComposerEntryMode.topic;
      _homePendingEntry = _ComposerEntryMode.topic;
    });
    _homeComposerUiRevision.value++;
    _scheduleFocusFirstHomeVisibilitySaveButton();
  }

  void _submitHomeAsExpectation() {
    setState(() {
      _composerMode = _ComposerEntryMode.expectation;
      _homePendingEntry = _ComposerEntryMode.expectation;
    });
    _homeComposerUiRevision.value++;
    _scheduleFocusFirstHomeVisibilitySaveButton();
  }

  /// Focus the left home visibility action ([_homeVisSaveFocusA]) after the row is shown.
  void _scheduleFocusFirstHomeVisibilitySaveButton() {
    final pending = _homePendingEntry;
    if (pending == null) return;
    void applyLeftFocus() {
      if (!mounted) return;
      if (_homePendingEntry != pending) return;
      if (_pillar != LedgerPillar.home) return;
      _homeVisSaveFocusA.requestFocus();
    }

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      applyLeftFocus();
      WidgetsBinding.instance.addPostFrameCallback((_) {
        applyLeftFocus();
      });
    });
  }

  void _submitExpectationPillarWithChoice(_ExpectationPillarQuickChoice choice) {
    setState(() => _expectationPillarQuickChoice = choice);
    unawaited(_submitCapture(
      forcedExpectationVisibility: choice == _ExpectationPillarQuickChoice.draft
          ? ExpectationVisibility.shadow
          : ExpectationVisibility.echo,
    ));
  }

  /// Enter on Home: only runs when exactly one of the two save actions is valid.
  _ComposerEntryMode? _homeEnterResolvedComposerMode(String text) {
    if (_submitInFlight) return null;
    final tpPrivate = _talkingPointPrivateSubmittable(text);
    final expOk = _composerCaptureTextIsSubmittable(text) &&
        _talkingPointLineHasPersonMention(text);
    final t = text.trim();
    // @-person note without # is a colleague talking point only, not an expectation.
    if (tpPrivate &&
        _talkingPointLineHasPersonMention(t) &&
        !_hashTagRegex.hasMatch(t)) {
      return _ComposerEntryMode.topic;
    }
    if (tpPrivate && !expOk) return _ComposerEntryMode.topic;
    if (!tpPrivate && expOk) return _ComposerEntryMode.expectation;
    return null;
  }

  /// Same rules as [_submitCapture]: need @ or # and at least one word that is not only tokens.
  bool _composerCaptureTextIsSubmittable(String text) {
    final t = text.trim();
    if (t.isEmpty) return false;
    final hasTag = _atTagRegex.hasMatch(t) || _hashTagRegex.hasMatch(t);
    if (!hasTag) return false;
    return _hasContentWord(t);
  }

  /// Talking point can be saved **privately**: at least one # and/or an @person, plus real content.
  bool _talkingPointPrivateSubmittable(String text) {
    final t = text.trim();
    if (t.isEmpty) return false;
    if (!_hasContentWord(t)) return false;
    return _hashTagRegex.hasMatch(t) || _talkingPointLineHasPersonMention(t);
  }

  /// Talking point can be saved **publicly**: needs #, no @-person (colleague notes stay private).
  bool _talkingPointPublicSubmittable(String text) {
    final t = text.trim();
    if (t.isEmpty) return false;
    if (!_hashTagRegex.hasMatch(t)) return false;
    if (_talkingPointLineHasPersonMention(t)) return false;
    return _hasContentWord(t);
  }

  /// True when the line has an @mention (talking points with a person cannot publish).
  bool _talkingPointLineHasPersonMention(String text) {
    return _extractMentionHandle(text.trim()) != null;
  }

  void _releaseSubmitInFlight() {
    _submitInFlight = false;
    _homeComposerUiRevision.value++;
    if (mounted) setState(() {});
  }

  /// Home-only: after neutral reset, return keyboard focus to the capture field (other pillars
  /// keep the generic [CommandCaptureBar] token; home remounts the subtree so we chain here too).
  void _scheduleHomeCaptureFocusAfterNeutralReset() {
    void unfocusSaveRow() {
      _homeVisSaveFocusA.unfocus();
      _homeVisSaveFocusB.unfocus();
      _composerSavePairFocusA.unfocus();
      _composerSavePairFocusB.unfocus();
    }

    void requestCapture() {
      if (!mounted || _pillar != LedgerPillar.home) return;
      unfocusSaveRow();
      final ctx = _homeComposerCaptureHostKey.currentContext;
      if (ctx != null && ctx.mounted) {
        FocusScope.of(ctx).requestFocus(_captureFocus);
      }
      _captureFocus.requestFocus();
    }

    WidgetsBinding.instance.addPostFrameCallback((_) {
      requestCapture();
      WidgetsBinding.instance.addPostFrameCallback((_) {
        requestCapture();
        WidgetsBinding.instance.addPostFrameCallback((_) {
          requestCapture();
          for (final ms in <int>[40, 120, 280]) {
            Future<void>.delayed(Duration(milliseconds: ms), () {
              if (!mounted || _pillar != LedgerPillar.home) return;
              if (!_captureFocus.hasFocus) requestCapture();
            });
          }
        });
      });
    });
  }

  /// Second pass after home capture: remount composer + force save row listenables so the
  /// kind buttons and empty field always match [_homePendingEntry] (see [_homeComposerUiRevision]).
  void _scheduleNeutralHomeComposerAfterHomeSubmit() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _pillar != LedgerPillar.home) return;
      setState(() {
        _homeComposerBlockKey++;
        _homeCaptureRefocusToken++;
        _homePendingEntry = null;
        _composerMode = _composerDefaultMode;
        _clearComposerAutocompleteInPlace();
        _captureController.value = TextEditingValue.empty;
      });
      _homeComposerUiRevision.value++;
      _homeVisSaveFocusA.unfocus();
      _homeVisSaveFocusB.unfocus();
      _composerSavePairFocusA.unfocus();
      _composerSavePairFocusB.unfocus();
      _scheduleHomeCaptureFocusAfterNeutralReset();
    });
  }

  Future<void> _submitCapture({
    ExpectationVisibility? forcedTalkingPointVisibility,
    ExpectationVisibility? forcedExpectationVisibility,
  }) async {
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
    if (!_hasContentWord(text)) {
      _showComposerToast(
        'Please include at least one word besides @mentions and #tags.',
      );
      return;
    }
    final isTalkingPointSubmit = _pillar == LedgerPillar.addTopic ||
        (_pillar == LedgerPillar.home &&
            _composerMode == _ComposerEntryMode.topic);
    final isExpectationSubmitContext = _pillar == LedgerPillar.addExpectation ||
        (_pillar == LedgerPillar.home &&
            _composerMode == _ComposerEntryMode.expectation);
    if (isTalkingPointSubmit && !_hashTagRegex.hasMatch(text)) {
      final colleagueShadowOk =
          forcedTalkingPointVisibility == ExpectationVisibility.shadow &&
              _talkingPointLineHasPersonMention(text) &&
              _hasContentWord(text);
      if (!colleagueShadowOk) {
        _showComposerToast(
          'Talking points need at least one #hashtag to publish, or @person for a private colleague note.',
        );
        return;
      }
    }
    if (_pillar == LedgerPillar.home &&
        _composerMode == _ComposerEntryMode.expectation &&
        _extractMentionHandle(text) == null) {
      _showComposerToast(
        'Link someone with @name or @me before saving as an expectation.',
      );
      return;
    }
    if (forcedTalkingPointVisibility != null &&
        forcedExpectationVisibility != null) {
      _showComposerToast('Choose one save action at a time.');
      return;
    }
    if (forcedTalkingPointVisibility != null && !isTalkingPointSubmit) {
      _showComposerToast('Use the buttons only when capturing a talking point.');
      return;
    }
    if (forcedExpectationVisibility != null && !isExpectationSubmitContext) {
      _showComposerToast('Use the buttons only when capturing an expectation.');
      return;
    }
    _submitInFlight = true;
    _homeComposerUiRevision.value++;
    setState(() {});
    final handle = _extractMentionHandle(text);
    final ExpectationType entryType;
    if (_pillar == LedgerPillar.addExpectation) {
      entryType = ExpectationType.expectation;
    } else if (_pillar == LedgerPillar.addTopic) {
      entryType = ExpectationType.topic;
    } else {
      entryType = _composerMode == _ComposerEntryMode.expectation
          ? ExpectationType.expectation
          : ExpectationType.topic;
    }
    Person? person;
    var shouldAskSubmitMode = true;
    if (handle != null) {
      if (handle.toLowerCase() == 'me') {
        shouldAskSubmitMode = false;
        person = await _resolveCurrentPerson();
        if (person == null) {
          _showComposerToast('Could not resolve @me for the current user.');
          _releaseSubmitInFlight();
          return;
        }
      } else {
        person = _findPersonByHandle(handle);
      }
      if (person == null) {
        final draftWithoutInvite = (entryType == ExpectationType.topic &&
                forcedTalkingPointVisibility ==
                    ExpectationVisibility.shadow) ||
            (entryType == ExpectationType.expectation &&
                forcedExpectationVisibility == ExpectationVisibility.shadow);
        if (draftWithoutInvite) {
          // Draft / personal save: no company person row or invite required.
          shouldAskSubmitMode = false;
        } else {
          shouldAskSubmitMode = false;
          final email = await _askOptionalEmailForHandle(handle);
          if (email == _cancelToken) {
            _releaseSubmitInFlight();
            return;
          }
          try {
            person = await _createPersonFromHandleInSupabase(
              handle,
              email: email,
            );
          } catch (e) {
            _showComposerToast('Could not create @$handle yet: $e');
            _releaseSubmitInFlight();
            return;
          }
        }
      }
    }
    final storedText = _normalizeExpectationTextForStorage(text);
    final parse = parseCaptureLine(text);
    final topicForSomeone =
        entryType == ExpectationType.topic && person != null;

    late final ExpectationVisibility visibility;
    if (topicForSomeone) {
      // Talking point @'d at a person: private note for the author only—never
      // surfaced to the other person (no inbox / no public talking-points feed).
      visibility = ExpectationVisibility.shadow;
    } else if (forcedTalkingPointVisibility != null &&
        entryType == ExpectationType.topic) {
      // Explicit buttons: skip dialog (and skip the no-receiver acknowledge).
      if (person != null &&
          forcedTalkingPointVisibility == ExpectationVisibility.echo) {
        visibility = ExpectationVisibility.shadow;
      } else {
        visibility = forcedTalkingPointVisibility;
      }
    } else if (forcedExpectationVisibility != null &&
        entryType == ExpectationType.expectation) {
      visibility = forcedExpectationVisibility;
    } else {
      final askSubmitDialog = entryType == ExpectationType.expectation ||
          shouldAskSubmitMode;
      final mode = askSubmitDialog
          ? await _askSubmitMode(talkingPoint: entryType == ExpectationType.topic)
          : _ExpectationSubmitMode.inform;
      if (mode == null) {
        _releaseSubmitInFlight();
        return;
      }
      visibility = mode == _ExpectationSubmitMode.draft
          ? ExpectationVisibility.shadow
          : ExpectationVisibility.echo;
    }

    setState(() {
      final tempExpectationId = 'exp_${DateTime.now().millisecondsSinceEpoch}';
      _homeRecent.insert(0, FeedEntry(
        id: 'cap_${DateTime.now().millisecondsSinceEpoch}',
        createdAt: DateTime.now().toUtc(),
        body: text,
        parse: parse,
        linkedExpectationId: person != null ? tempExpectationId : null,
        isUserCapture: true,
      ));
      final target = person;
      _expectations.insert(
        0,
        Expectation(
          id: tempExpectationId,
          createdAt: DateTime.now().toUtc(),
          writerUserId: Supabase.instance.client.auth.currentUser?.id,
          personId: target?.id ?? '',
          summary: storedText,
          deadlineLabel: 'TBD',
          deadlineAt: null,
          finishedAt: null,
          responsibleUpdatedAt: DateTime.now().toUtc(),
          publishedAt: visibility == ExpectationVisibility.echo
              ? DateTime.now().toUtc()
              : null,
          seenAt: null,
          lastChattedSenderAt: null,
          lastChattedReceiverAt: null,
          progress: 0,
          health: ExpectationHealth.unknown,
          type: entryType,
          status: ExpectationStatus.pending,
          visibility: visibility,
        ),
      );
      // Reset home save row before [clear].
      _clearComposerAutocompleteInPlace();
      _homePendingEntry = null;
      _composerMode = _pillar == LedgerPillar.addExpectation
          ? _ComposerEntryMode.expectation
          : _pillar == LedgerPillar.addTopic
              ? _ComposerEntryMode.topic
              : _composerDefaultMode;
      _captureController.clear();
    });
    if (_pillar == LedgerPillar.home) {
      _homeComposerUiRevision.value++;
    }
    try {
      final persistedExpectationId = await _persistExpectationToSupabase(
        text: storedText,
        visibility: visibility,
        type: entryType,
        target: person,
      );
      if (mounted) {
        setState(() {
          if (_homeRecent.isNotEmpty) {
            final first = _homeRecent.first;
            _homeRecent[0] = FeedEntry(
              id: first.id,
              createdAt: first.createdAt,
              body: first.body,
              parse: first.parse,
              linkedExpectationId: persistedExpectationId,
              isUserCapture: first.isUserCapture,
            );
          }
        });
      }
      await _loadExpectationsFromSupabase();
      if (mounted && entryType == ExpectationType.topic) {
        await _loadRecentTagsFromSupabase();
      }
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
    _releaseSubmitInFlight();
    if (_pillar == LedgerPillar.home) {
      _scheduleNeutralHomeComposerAfterHomeSubmit();
    }
  }

  Future<Person?> _resolveCurrentPerson() async {
    final user = Supabase.instance.client.auth.currentUser;
    if (user == null) return null;
    try {
      final existing = await Supabase.instance.client
          .from('people')
          .select('id,created_at,display_name,handle,auth_user_id,email,title')
          .eq('auth_user_id', user.id)
          .limit(1);
      if ((existing as List).isEmpty) return null;
      final row = existing.first as Map;
      final createdAt = DateTime.tryParse((row['created_at'] as String?) ?? '') ??
          DateTime.now().toUtc();
      final resolved = Person(
        id: row['id'] as String,
        createdAt: createdAt,
        displayName: ((row['display_name'] as String?) ?? '').trim(),
        handle: ((row['handle'] as String?) ?? '').trim(),
        authUserId: (row['auth_user_id'] as String?)?.trim(),
        email: ((row['email'] as String?) ?? '').trim().isEmpty
            ? null
            : ((row['email'] as String?) ?? '').trim(),
        title: ((row['title'] as String?) ?? '').trim().isEmpty
            ? null
            : ((row['title'] as String?) ?? '').trim(),
      );
      final idx = _people.indexWhere((p) => p.id == resolved.id);
      if (idx >= 0) {
        _people[idx] = resolved;
      } else {
        _people.add(resolved);
      }
      return resolved;
    } catch (_) {
      return null;
    }
  }

  static const _cancelToken = '__cancel__';
  static final RegExp _mentionRegex = RegExp(r'@([a-zA-Z0-9._-]+)');
  static final RegExp _leadingMentionRegex = RegExp(r'^\s*@([a-zA-Z0-9._-]+)\b\s*');
  static final RegExp _atTagRegex = RegExp(r'@([a-zA-Z0-9._-]+)');
  static final RegExp _hashTagRegex = RegExp(r'#([a-zA-Z0-9._-]+)');
  static final RegExp _allHashTagsRegex = RegExp(r'#([a-zA-Z0-9._-]+)');
  static final RegExp _wordCharRegex = RegExp(r'[a-zA-Z0-9]');
  static final RegExp _uuidRegex = RegExp(
    r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[1-5][0-9a-fA-F]{3}-[89abAB][0-9a-fA-F]{3}-[0-9a-fA-F]{12}$',
  );
  static final RegExp _emailRegex = RegExp(r'^[^\s@]+@[^\s@]+\.[^\s@]+$');

  Future<String?> _askInviteEmailDialog({Person? person}) async {
    final handle = person?.handle.trim();
    final initialEmail = (person?.email ?? '').trim();
    final controller = TextEditingController(text: initialEmail);
    String? error;
    final result = await showDialog<String>(
      context: context,
      barrierDismissible: false,
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setLocalState) {
            return AlertDialog(
              title: Text(
                (handle != null && handle.isNotEmpty)
                    ? 'Invite @$handle'
                    : 'Invite person',
              ),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    (handle != null && handle.isNotEmpty)
                        ? 'Send a personalized invite email for @$handle.'
                        : 'Invite people from your organisation directly to their personal email or distribution lists.',
                  ),
                  const SizedBox(height: 10),
                  TextField(
                    controller: controller,
                    autofocus: true,
                    decoration: InputDecoration(
                      hintText: 'name@company.com',
                      errorText: error,
                    ),
                    onSubmitted: (_) {
                      final value = controller.text.trim();
                      if (_emailRegex.hasMatch(value)) {
                        Navigator.of(context).pop(value);
                      } else {
                        setLocalState(() {
                          error = 'Please enter a valid email address.';
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
                    if (_emailRegex.hasMatch(value)) {
                      Navigator.of(context).pop(value);
                    } else {
                      setLocalState(() {
                        error = 'Please enter a valid email address.';
                      });
                    }
                  },
                  child: const Text('Send invite'),
                ),
              ],
            );
          },
        );
      },
    );
    if (!context.mounted) {
      controller.dispose();
    } else {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        controller.dispose();
      });
    }
    if (result == _cancelToken) return null;
    return result?.trim();
  }

  Future<void> _openInviteFlow({String? personId}) async {
    Person? person;
    if (personId != null) {
      for (final p in _people) {
        if (p.id == personId) {
          person = p;
          break;
        }
      }
    }
    if (person != null && (person.authUserId ?? '').trim().isNotEmpty) {
      _showComposerToast('This person already has an account.');
      return;
    }
    final email = await _askInviteEmailDialog(person: person);
    if (email == null || !_emailRegex.hasMatch(email)) return;
    try {
      final client = Supabase.instance.client;
      final user = client.auth.currentUser;
      if (user == null) {
        throw Exception('No authenticated user.');
      }
      final meRows = await client
          .from('people')
          .select('company_id')
          .eq('auth_user_id', user.id)
          .limit(1);
      if ((meRows as List).isEmpty) {
        throw Exception('No linked person/company for this user.');
      }
      final companyId = meRows.first['company_id'] as String;
      if (person != null) {
        await client.from('people').update({'email': email}).eq('id', person.id);
      }
      final expiresAt = DateTime.now()
          .toUtc()
          .add(const Duration(days: 14))
          .toIso8601String();
      final inviteKind = person == null ? 'generic' : 'personalized:${person.id}';
      final tokenHash =
          '$inviteKind:${DateTime.now().microsecondsSinceEpoch}-${user.id}-${email.toLowerCase()}';
      await client.from('invites').insert({
        'company_id': companyId,
        'email': email,
        'role': 0,
        'status': 0,
        'token_hash': tokenHash,
        'invited_by_user_id': user.id,
        'expires_at': expiresAt,
      });
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            person == null
                ? 'Generic invite created for $email.'
                : 'Personalized invite created for @${
                    person.handle
                  } ($email).',
          ),
        ),
      );
      await _loadPeopleFromSupabase();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Failed to create invite: $e')),
      );
    }
  }

  bool _hasContentWord(String input) {
    final tokens = input.trim().split(RegExp(r'\s+'));
    for (final raw in tokens) {
      final t = raw.trim();
      if (t.isEmpty) continue;
      if (t.startsWith('@') || t.startsWith('#')) continue;
      if (_wordCharRegex.hasMatch(t)) return true;
    }
    return false;
  }

  String _normalizeExpectationTextForStorage(String input) {
    final trimmed = input.trim();
    if (trimmed.isEmpty) return trimmed;
    var normalized = trimmed.replaceFirst(_leadingMentionRegex, '').trim();
    if (normalized.isEmpty) {
      return trimmed;
    }
    final first = normalized[0];
    final upperFirst = first.toUpperCase();
    if (first != upperFirst) {
      normalized = '$upperFirst${normalized.substring(1)}';
    }
    return normalized;
  }

  Future<String> _persistExpectationToSupabase({
    required String text,
    required ExpectationVisibility visibility,
    required ExpectationType type,
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
    final companyId = meRows.first['company_id'] as String;

    final targetPersonId = (target != null && _uuidRegex.hasMatch(target.id))
        ? target.id
        : null;
    final title = text.length > 80 ? '${text.substring(0, 80)}...' : text;

    final inserted = await client.from('expectations').insert({
      'company_id': companyId,
      'writer_user_id': user.id,
      'target_person_id': targetPersonId,
      'title': title,
      'summary': text,
      'deadline_label': 'TBD',
      'responsible_updated_at': DateTime.now().toUtc().toIso8601String(),
      'progress': 0,
      'expectation_status': _statusToDb(ExpectationStatus.pending),
      'expectation_health': _healthToDb(ExpectationHealth.unknown),
      'expectation_type': _typeToDb(type),
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
    return expectationId;
  }

  void _showComposerToast(String message) {
    if (!mounted) return;
    _composerToastTimer?.cancel();
    _homeComposerUiRevision.value++;
    setState(() => _composerToastMessage = message);
    _composerToastTimer = Timer(const Duration(seconds: 4), () {
      if (!mounted) return;
      _homeComposerUiRevision.value++;
      setState(() => _composerToastMessage = null);
    });
  }

  Future<void> _refreshCurrentPillar() async {
    if (_refreshInFlight) return;
    setState(() => _refreshInFlight = true);
    try {
      switch (_pillar) {
        case LedgerPillar.people:
          await _loadPeopleFromSupabase();
          break;
        case LedgerPillar.tags:
          await _loadRecentTagsFromSupabase();
          break;
        case LedgerPillar.home:
        case LedgerPillar.addExpectation:
        case LedgerPillar.addTopic:
        case LedgerPillar.expectationsMe:
        case LedgerPillar.expectationsOthers:
          // Expectations views depend on both people + expectations + recent tags.
          await _loadPeopleFromSupabase();
          await _loadExpectationsFromSupabase();
          await _loadRecentTagsFromSupabase();
          break;
      }
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Refreshed')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Refresh failed: $e')),
        );
      }
    } finally {
      if (mounted) setState(() => _refreshInFlight = false);
    }
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

  Future<Person> _createPersonFromHandleInSupabase(
    String handle, {
    String? email,
  }) async {
    final client = Supabase.instance.client;
    final user = client.auth.currentUser;
    if (user == null) {
      throw Exception('No authenticated user.');
    }
    final normalized = handle.trim();
    if (normalized.isEmpty) {
      throw Exception('Invalid empty handle.');
    }
    final emailTrimmed = (email ?? '').trim();
    final normalizedEmail = emailTrimmed.isEmpty ? null : emailTrimmed;

    final meRows = await client
        .from('people')
        .select('id,company_id')
        .eq('auth_user_id', user.id)
        .limit(1);
    if ((meRows as List).isEmpty) {
      throw Exception('No linked person/company for this user.');
    }
    final companyId = meRows.first['company_id'] as String;

    Map<String, dynamic>? personRow;
    try {
      personRow = await client
          .from('people')
          .insert({
            'company_id': companyId,
            'display_name': normalized,
            'handle': normalized,
            'email': normalizedEmail,
          })
          .select('id,created_at,display_name,handle,auth_user_id,email,title')
          .single();
    } on PostgrestException {
      final existing = await client
          .from('people')
          .select('id,created_at,display_name,handle,auth_user_id,email,title')
          .eq('company_id', companyId)
          .ilike('handle', normalized)
          .limit(1);
      if ((existing as List).isEmpty) rethrow;
      personRow = Map<String, dynamic>.from(existing.first as Map);
      if (normalizedEmail != null &&
          ((personRow['email'] as String?)?.trim().isNotEmpty != true)) {
        final updated = await client
            .from('people')
            .update({'email': normalizedEmail})
            .eq('id', personRow['id'] as String)
            .select('id,created_at,display_name,handle,auth_user_id,email,title')
            .single();
        personRow = Map<String, dynamic>.from(updated);
      }
    }

    if (normalizedEmail != null) {
      final expiresAt = DateTime.now()
          .toUtc()
          .add(const Duration(days: 14))
          .toIso8601String();
      final tokenHash =
          '${DateTime.now().microsecondsSinceEpoch}-${user.id}-${normalized.toLowerCase()}';
      await client.from('invites').insert({
        'company_id': companyId,
        'email': normalizedEmail,
        'role': 0,
        'status': 0,
        'token_hash': tokenHash,
        'invited_by_user_id': user.id,
        'expires_at': expiresAt,
      });
    }

    final person = Person(
      id: personRow['id'] as String,
      createdAt: DateTime.tryParse(personRow['created_at'] as String? ?? '') ??
          DateTime.now().toUtc(),
      displayName: (personRow['display_name'] as String?)?.trim().isNotEmpty ==
              true
          ? (personRow['display_name'] as String).trim()
          : normalized,
      handle: ((personRow['handle'] as String?) ?? normalized).trim(),
      authUserId: (personRow['auth_user_id'] as String?)?.trim(),
      email: (personRow['email'] as String?)?.trim(),
      title: (personRow['title'] as String?)?.trim(),
    );

    final existingIdx = _people.indexWhere(
      (p) => p.handle.toLowerCase() == person.handle.toLowerCase(),
    );
    setState(() {
      if (existingIdx >= 0) {
        _people[existingIdx] = person;
      } else {
        _people.add(person);
      }
      _people.sort(
        (a, b) => a.displayName.toLowerCase().compareTo(b.displayName.toLowerCase()),
      );
    });
    return person;
  }

  Future<_ExpectationSubmitMode?> _askSubmitMode({
    bool talkingPoint = false,
  }) async {
    return showDialog<_ExpectationSubmitMode>(
      context: context,
      builder: (_) {
        var selectedIndex = 0;
        return StatefulBuilder(
          builder: (context, setLocalState) {
            void confirmSelection() {
              Navigator.of(context).pop(
                selectedIndex == 0
                    ? _ExpectationSubmitMode.draft
                    : _ExpectationSubmitMode.inform,
              );
            }

            final primaryLabel =
                talkingPoint ? 'Keep private' : 'Save as Draft';
            final secondaryLabel =
                talkingPoint ? 'Publish' : 'Send immediately';

            return Focus(
              autofocus: true,
              skipTraversal: true,
              canRequestFocus: true,
              onKeyEvent: (node, event) {
                if (event is! KeyDownEvent) {
                  return KeyEventResult.ignored;
                }
                if (event.logicalKey == LogicalKeyboardKey.tab) {
                  final shiftDown = HardwareKeyboard.instance.logicalKeysPressed
                          .contains(LogicalKeyboardKey.shiftLeft) ||
                      HardwareKeyboard.instance.logicalKeysPressed
                          .contains(LogicalKeyboardKey.shiftRight);
                  setLocalState(() {
                    if (shiftDown) {
                      selectedIndex = (selectedIndex - 1 + 2) % 2;
                    } else {
                      selectedIndex = (selectedIndex + 1) % 2;
                    }
                  });
                  return KeyEventResult.handled;
                }
                if (event.logicalKey == LogicalKeyboardKey.enter) {
                  confirmSelection();
                  return KeyEventResult.handled;
                }
                return KeyEventResult.ignored;
              },
              child: AlertDialog(
                title: Text(
                  talkingPoint ? 'Save talking point' : 'Save expectation',
                ),
                content: Text(
                  talkingPoint
                      ? 'Keep this private while you refine it, or publish so it '
                          'appears under Public for others.'
                      : 'Save as a draft to keep refining it yourself, or send '
                          'immediately so others can see it.',
                ),
                actions: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.end,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      ExcludeFocus(
                        child: TextButton(
                          onPressed: () => Navigator.of(context).pop(),
                          child: const Text('Cancel'),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Flexible(
                        child: ConstrainedBox(
                          constraints: const BoxConstraints(maxWidth: 360),
                          child: ExcludeFocus(
                            child: Row(
                              children: [
                                Expanded(
                                  child: selectedIndex == 0
                                      ? FilledButton(
                                          onPressed: () =>
                                              Navigator.of(context).pop(
                                            _ExpectationSubmitMode.draft,
                                          ),
                                          child: Text(primaryLabel),
                                        )
                                      : FilledButton.tonal(
                                          onPressed: () =>
                                              Navigator.of(context).pop(
                                            _ExpectationSubmitMode.draft,
                                          ),
                                          child: Text(primaryLabel),
                                        ),
                                ),
                                const SizedBox(width: 10),
                                Expanded(
                                  child: selectedIndex == 1
                                      ? FilledButton(
                                          onPressed: () =>
                                              Navigator.of(context).pop(
                                            _ExpectationSubmitMode.inform,
                                          ),
                                          child: Text(secondaryLabel),
                                        )
                                      : FilledButton.tonal(
                                          onPressed: () =>
                                              Navigator.of(context).pop(
                                            _ExpectationSubmitMode.inform,
                                          ),
                                          child: Text(secondaryLabel),
                                        ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            );
          },
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
                  child: const Text('Continue anyway'),
                ),
              ],
            );
          },
        );
      },
    );
    if (!context.mounted) {
      controller.dispose();
    } else {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        controller.dispose();
      });
    }
    return result;
  }

  Future<void> _openExpectationDetails({
    required Expectation e,
    required Person? person,
  }) async {
    await showDialog<bool>(
      context: context,
      builder: (context) {
        return Dialog(
          insetPadding: const EdgeInsets.symmetric(horizontal: 24, vertical: 20),
          child: ConstrainedBox(
            constraints: BoxConstraints(
              maxWidth: 760,
              maxHeight: _isDiscussionPoint(e) ? 720 : 900,
            ),
            child: _ExpectationDetailsPanel(
              expectation: e,
              person: person,
              canEdit: true,
              onInvitePerson: (personId) => _openInviteFlow(personId: personId),
            ),
          ),
        );
      },
    );
    if (mounted) {
      await _loadExpectationsFromSupabase();
    }
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
          TextButton(
            onPressed: _openHomeQuickCaptureModal,
            child: const Text('Quick Capture'),
          ),
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
            tooltip: 'Refresh',
            onPressed: _refreshInFlight ? null : _refreshCurrentPillar,
            icon: _refreshInFlight
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.refresh),
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
                recentTags: _mergedPublicRailTags(),
                recentTagsHasMore: _recentTagsHasMore,
                privateRailTags: _privateRailTagsFromExpectations(),
                onPrivateRailTag: _onPrivateRailTagSelect,
                tagsLoading: _tagsLoading,
                tagsLoadError: _tagsLoadError,
                onRetryTags: () {
                  _loadRecentTagsFromSupabase();
                },
                talkingPointsSubView: _talkingPointsSubView,
                colleagueCloudEntries: _colleagueTalkingPointCloudEntries(),
                colleagueFilterPersonId: _colleagueFilterPersonId,
                onColleagueFilterSelect: (id) {
                  setState(() => _colleagueFilterPersonId = id);
                },
                onColleagueRailPersonTap: _openColleaguesFilteredToPerson,
                footerDirectoryTitle:
                    (_companyName ?? '').trim().isNotEmpty
                        ? _companyName!.trim()
                        : LedgerPillar.people.title,
                profileName: _profileName,
                profileTitle: _profileTitle,
                onLogout: () async {
                  await Supabase.instance.client.auth.signOut();
                },
                onSelect: (p) {
                  if (_homeQuickCaptureSheetOpen) {
                    Navigator.of(context).pop();
                  }
                  setState(() {
                    _homePendingEntry = null;
                    _pillar = p;
                    if (p == LedgerPillar.tags) {
                      _talkingPointsSubView = _TalkingPointsSubView.meetingsOrTags;
                      _colleagueFilterPersonId = null;
                    }
                    if (p == LedgerPillar.addExpectation) {
                      _composerMode = _ComposerEntryMode.expectation;
                      _expectationPillarQuickChoice =
                          _ExpectationPillarQuickChoice.draft;
                    } else if (p == LedgerPillar.addTopic) {
                      _composerMode = _ComposerEntryMode.topic;
                    }
                  });
                  if (p == LedgerPillar.addExpectation ||
                      p == LedgerPillar.addTopic) {
                    _focusComposer();
                  } else {
                    _captureFocus.unfocus();
                  }
                },
                onOpenExpectationCapture: _goAddExpectationCapture,
                onOpenTopicCapture: _goAddTopicCapture,
                onTalkingPointsBrowse: _openTalkingPointsSubView,
                onTagSelect: _openTagPillar,
                onInviteTap: () => _openInviteFlow(),
              ),
            ),
            Expanded(
              child: GestureDetector(
                behavior: HitTestBehavior.translucent,
                onTap: () {
                  if (_pillar == LedgerPillar.addExpectation ||
                      _pillar == LedgerPillar.addTopic) {
                    _focusComposer();
                  }
                },
                child: ResponsiveCenteredBody(
                  maxWidth: 800,
                  alwaysApplyMaxWidth: true,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      _PillarHeader(pillar: _pillar, theme: theme),
                      SizedBox(
                        height: _pillar == LedgerPillar.home ? 20 : 12,
                      ),
                      if (_pillar == LedgerPillar.addExpectation ||
                          _pillar == LedgerPillar.addTopic) ...[
                        Focus(
                          skipTraversal: true,
                          canRequestFocus: false,
                          descendantsAreFocusable: true,
                          onKeyEvent: _onComposerBlockKeyEvent,
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                        _buildComposerCommandCaptureBar(
                          theme,
                          scheme,
                          homeCaptureHostKey: null,
                        ),
                        if (_talkingPointCaptureContext()) ...[
                          const SizedBox(height: 6),
                          ListenableBuilder(
                            listenable: _composerSaveRowListenable,
                            builder: (context, _) {
                              final value = _captureController.value;
                              final personalOk =
                                  _talkingPointPrivateSubmittable(value.text);
                              final publicOk =
                                  _talkingPointPublicSubmittable(value.text);
                              final busy = _submitInFlight;
                              final personalEnabled = personalOk && !busy;
                              final publicEnabled = publicOk && !busy;
                              final fieldFocused = _captureFocus.hasFocus;
                              return Row(
                                children: [
                                  Expanded(
                                    child: _PairedSaveAction(
                                      focusNode: _composerSavePairFocusA,
                                      enabled: personalEnabled,
                                      emphasizeAsKeyboardDefault:
                                          personalEnabled && fieldFocused,
                                      onPressed: () => _submitCapture(
                                        forcedTalkingPointVisibility:
                                            ExpectationVisibility.shadow,
                                      ),
                                      label: 'Save privately',
                                    ),
                                  ),
                                  const SizedBox(width: 10),
                                  Expanded(
                                    child: _PairedSaveAction(
                                      focusNode: _composerSavePairFocusB,
                                      enabled: publicEnabled,
                                      onPressed: () => _submitCapture(
                                        forcedTalkingPointVisibility:
                                            ExpectationVisibility.echo,
                                      ),
                                      label: 'Save publicly',
                                    ),
                                  ),
                                ],
                              );
                            },
                          ),
                        ],
                        if (_expectationCaptureContext()) ...[
                          const SizedBox(height: 6),
                          ListenableBuilder(
                            listenable: _composerSaveRowListenable,
                            builder: (context, _) {
                              final value = _captureController.value;
                              final canSave =
                                  _composerCaptureTextIsSubmittable(value.text);
                              final enabled = canSave && !_submitInFlight;
                              final fieldFocused = _captureFocus.hasFocus;
                              final draftEnterDefault =
                                  _expectationPillarQuickChoice ==
                                  _ExpectationPillarQuickChoice.draft;
                              return Row(
                                children: [
                                  Expanded(
                                    child: _PairedSaveAction(
                                      focusNode: _composerSavePairFocusA,
                                      enabled: enabled,
                                      emphasizeAsKeyboardDefault: enabled &&
                                          fieldFocused &&
                                          draftEnterDefault,
                                      onPressed: () =>
                                          _submitExpectationPillarWithChoice(
                                        _ExpectationPillarQuickChoice.draft,
                                      ),
                                      label: 'Save as Draft',
                                    ),
                                  ),
                                  const SizedBox(width: 10),
                                  Expanded(
                                    child: _PairedSaveAction(
                                      focusNode: _composerSavePairFocusB,
                                      enabled: enabled,
                                      emphasizeAsKeyboardDefault: enabled &&
                                          fieldFocused &&
                                          !draftEnterDefault,
                                      onPressed: () =>
                                          _submitExpectationPillarWithChoice(
                                        _ExpectationPillarQuickChoice
                                            .sendImmediately,
                                      ),
                                      label: 'Send immediately',
                                    ),
                                  ),
                                ],
                              );
                            },
                          ),
                        ],
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
                          ),
                        ),
                      ],
                      if (_pillar == LedgerPillar.addExpectation ||
                          _pillar == LedgerPillar.addTopic) ...[
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
                        child: ExcludeFocus(
                          excluding: _composerHasSavePairButtonsPillar(),
                          child: ListView(
                            controller: _scrollController,
                            padding: _pillar == LedgerPillar.home
                                ? const EdgeInsets.fromLTRB(0, 4, 12, 32)
                                : const EdgeInsets.only(right: 12, bottom: 16),
                            children: _threadChildren(
                              theme: theme,
                              scheme: scheme,
                              people: _people,
                              expectations: _expectations,
                              peopleById: peopleById,
                              onOpenExpectationDetails: (e, p) =>
                                  _openExpectationDetails(e: e, person: p),
                            ),
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
    required void Function(Expectation e, Person? person) onOpenExpectationDetails,
  }) {
    final out = <Widget>[];
    final mePerson = _myPersonId == null
        ? null
        : (() {
            for (final p in people) {
              if (p.id == _myPersonId) return p;
            }
            return null;
          })();
    switch (_pillar) {
      case LedgerPillar.home:
        out.add(
          _HomeDashboardPanel(
            theme: theme,
            scheme: scheme,
            displayName: _profileName,
            companyName: _companyName,
          ),
        );
        out.add(const SizedBox(height: 28));
        out.add(_HomeUseCasesGuide(theme: theme, scheme: scheme));
        break;

      case LedgerPillar.addExpectation:
      case LedgerPillar.addTopic:
        if (_expectationsLoading) {
          out.add(const _ExpectationsLoadingCard());
          break;
        }
        if (_expectationsLoadError != null) {
          out.add(
            _ExpectationsErrorCard(
              message: _expectationsLoadError!,
              onRetry: _loadExpectationsFromSupabase,
            ),
          );
          break;
        }
        final currentUserId = Supabase.instance.client.auth.currentUser?.id;
        final wantType = _pillar == LedgerPillar.addExpectation
            ? ExpectationType.expectation
            : ExpectationType.topic;
        final authored = expectations
            .where(
              (x) =>
                  x.type == wantType &&
                  currentUserId != null &&
                  x.writerUserId == currentUserId,
            )
            .toList()
          ..sort((a, b) => b.createdAt.compareTo(a.createdAt));
        for (final x in authored) {
          out.add(
            _ExpectationOthersTile(
              expectation: x,
              person: peopleById[x.personId],
              theme: theme,
              scheme: scheme,
              hasUnreadChat: _hasUnreadChat(x),
              onTagPressed: _openTagPillar,
              onDelete: () => _deleteExpectationFromList(x),
              onOpenDetails: () => onOpenExpectationDetails(x, peopleById[x.personId]),
              composerRecentListing: true,
            ),
          );
        }
        if (authored.isEmpty) {
          out.add(
            Padding(
              padding: const EdgeInsets.only(top: 8, bottom: 16),
              child: Text(
                _pillar == LedgerPillar.addExpectation
                    ? 'No expectations authored by you yet. Capture one above.'
                    : 'No talking points authored by you yet. Capture one above.',
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: scheme.onSurfaceVariant,
                  height: 1.4,
                ),
              ),
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
          out.add(
            _PeopleTileGrid(
              people: people,
              theme: theme,
              scheme: scheme,
              onPersonTap: (person) {
                setState(() {
                  _pillar = LedgerPillar.expectationsOthers;
                  _othersPersonFilter = person.id;
                });
              },
            ),
          );
        }
        break;

      case LedgerPillar.tags:
        if (_expectationsLoading) {
          out.add(const _ExpectationsLoadingCard());
          break;
        }
        if (_expectationsLoadError != null) {
          out.add(
            _ExpectationsErrorCard(
              message: _expectationsLoadError!,
              onRetry: _loadExpectationsFromSupabase,
            ),
          );
          break;
        }

        final currentUserIdTags = Supabase.instance.client.auth.currentUser?.id;
        // All of your private talking points (shadow topics), regardless of whether
        // they @-mention a specific person. The rail @ cloud still only surfaces
        // person-linked topics, but the listing itself should include general
        // private #tag lines as well.
        final colleagueTopics = (expectations
                .where(
                  (x) =>
                      x.type == ExpectationType.topic &&
                      currentUserIdTags != null &&
                      x.writerUserId == currentUserIdTags &&
                      x.visibility == ExpectationVisibility.shadow,
                )
                .toList()
              ..sort((a, b) => b.createdAt.compareTo(a.createdAt)));
        final colleagueCloudEntries = _colleagueTalkingPointCloudEntries();
        final publicTagged = expectations.where((x) {
          if (x.visibility != ExpectationVisibility.echo) return false;
          if (x.type != ExpectationType.topic) return false;
          if (x.personId.trim().isNotEmpty) return false;
          return _extractInlineTags(x.summary).isNotEmpty;
        }).toList();
        final availableTags = publicTagged
            .expand((e) => _extractInlineTags(e.summary))
            .map((t) => t.toLowerCase())
            .toSet()
            .toList()
          ..sort();
        final effectiveMeetingsTag =
            availableTags.contains(_tagsSelectedTag) ? _tagsSelectedTag : null;
        final availablePrivateTags = expectations
            .where(
              (x) =>
                  x.type == ExpectationType.topic &&
                  currentUserIdTags != null &&
                  x.writerUserId == currentUserIdTags &&
                  x.visibility == ExpectationVisibility.shadow &&
                  _extractInlineTags(x.summary).isNotEmpty,
            )
            .expand((e) => _extractInlineTags(e.summary))
            .map((t) => t.toLowerCase())
            .toSet()
            .toList()
          ..sort();
        final effectivePrivateTag = availablePrivateTags.contains(_tagsSelectedTag)
            ? _tagsSelectedTag
            : null;

        if (_talkingPointsSubView == _TalkingPointsSubView.meetingsOrTags) {
          out.add(
            Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  const Spacer(),
                  _ExpectationsOthersFiltersBar(
                    showStatus: false,
                    showTag: true,
                    showPerson: false,
                    selectedStatus: null,
                    selectedTag: effectiveMeetingsTag,
                    selectedPersonId: null,
                    tags: availableTags,
                    people: const [],
                    tagFieldWidth: 240,
                    onStatusChanged: (_) {},
                    onTagChanged: (v) {
                      setState(() {
                        _tagsSelectedTag = v;
                        _talkingPointsSubView =
                            _TalkingPointsSubView.meetingsOrTags;
                      });
                    },
                    onPersonChanged: (_) {},
                  ),
                ],
              ),
            ),
          );
        }

        if (_talkingPointsSubView == _TalkingPointsSubView.colleagues) {
          if (availablePrivateTags.isNotEmpty) {
            out.add(
              Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    const Spacer(),
                    _ExpectationsOthersFiltersBar(
                      showStatus: false,
                      showTag: true,
                      showPerson: false,
                      selectedStatus: null,
                      selectedTag: effectivePrivateTag,
                      selectedPersonId: null,
                      tags: availablePrivateTags,
                      people: const [],
                      tagFieldWidth: 240,
                      onStatusChanged: (_) {},
                      onTagChanged: (v) {
                        setState(() {
                          _tagsSelectedTag = v;
                          _talkingPointsSubView =
                              _TalkingPointsSubView.colleagues;
                        });
                      },
                      onPersonChanged: (_) {},
                    ),
                  ],
                ),
              ),
            );
          }
          final colleaguePersonIds = {
              for (final c in colleagueCloudEntries) c.person.id,
            };
            final effectiveTalkingPointPerson =
                _colleagueFilterPersonId != null &&
                        colleaguePersonIds.contains(_colleagueFilterPersonId!)
                    ? _colleagueFilterPersonId
                    : null;
            var filtered = effectiveTalkingPointPerson == null
                ? colleagueTopics
                : colleagueTopics
                    .where((x) => x.personId == effectiveTalkingPointPerson)
                    .toList();
            if (effectivePrivateTag != null) {
              filtered = filtered
                  .where(
                    (x) => _extractInlineTags(x.summary)
                        .map((t) => t.toLowerCase())
                        .contains(effectivePrivateTag),
                  )
                  .toList();
            }
            final activeColleague = filtered
                .where(
                  (x) =>
                      x.status != ExpectationStatus.finished &&
                      x.status != ExpectationStatus.abandoned,
                )
                .toList();
            final archiveColleague = filtered
                .where(
                  (x) =>
                      x.status == ExpectationStatus.finished ||
                      x.status == ExpectationStatus.abandoned,
                )
                .toList();
            out.add(
              _ExpectationsOthersSection(
                title: 'Active',
                emptyText: effectiveTalkingPointPerson == null
                    ? 'No active private talking points yet.'
                    : 'No active private talking points for this person.',
                items: activeColleague,
                peopleById: peopleById,
                theme: theme,
                scheme: scheme,
                collapsed: false,
                hasUnreadChat: _hasUnreadChat,
                onTagPressed: _openTagPillar,
                onOpenDetails: (e, p) => onOpenExpectationDetails(e, p),
                onDeleteExpectation: _deleteExpectationFromList,
                onToggleCollapsed: () {},
                talkingPointsBrowseListing: true,
                onArchiveTalkingPoint: _archiveTalkingPointBrowse,
                onPublishTalkingPoint: _publishTalkingPointBrowse,
              ),
            );
            out.add(const SizedBox(height: 12));
            out.add(
              _ExpectationsOthersSection(
                title: 'Archive',
                emptyText: effectiveTalkingPointPerson == null
                    ? 'No archived private talking points yet.'
                    : 'No archived private talking points for this person.',
                items: archiveColleague,
                peopleById: peopleById,
                theme: theme,
                scheme: scheme,
                collapsed: _colleagueArchiveCollapsed,
                hasUnreadChat: _hasUnreadChat,
                onTagPressed: _openTagPillar,
                onOpenDetails: (e, p) => onOpenExpectationDetails(e, p),
                onDeleteExpectation: _deleteExpectationFromList,
                onToggleCollapsed: () {
                  setState(() {
                    _colleagueArchiveCollapsed = !_colleagueArchiveCollapsed;
                  });
                },
                talkingPointsBrowseListing: true,
                onArchiveTalkingPoint: _archiveTalkingPointBrowse,
                onPublishTalkingPoint: _publishTalkingPointBrowse,
              ),
            );
          break;
        }
        // Public (#tags, echo, no @person)
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
          // Public is already implied by this subview; avoid an extra "Public" heading.
          final activeTag = effectiveMeetingsTag;
          final filtered = activeTag == null
              ? publicTagged
              : publicTagged.where((x) {
                  return _extractInlineTags(x.summary)
                      .map((t) => t.toLowerCase())
                      .contains(activeTag);
                }).toList();
          final inflow = filtered
              .where((x) =>
                  x.status != ExpectationStatus.finished &&
                  x.status != ExpectationStatus.abandoned)
              .toList();
          final archive = filtered
              .where((x) =>
                  x.status == ExpectationStatus.finished ||
                  x.status == ExpectationStatus.abandoned)
              .toList();
          out.add(
            _ExpectationsOthersSection(
              title: 'Active',
              emptyText: activeTag == null
                  ? 'No published talking points yet.'
                  : 'No active talking points for #$activeTag.',
              items: inflow,
              peopleById: peopleById,
              theme: theme,
              scheme: scheme,
              collapsed: false,
              hasUnreadChat: _hasUnreadChat,
              onTagPressed: _openTagPillar,
              onOpenDetails: (e, p) => _openExpectationDetails(e: e, person: p),
              onDeleteExpectation: _deleteExpectationFromList,
              onToggleCollapsed: () {},
              talkingPointsBrowseListing: true,
              onArchiveTalkingPoint: _archiveTalkingPointBrowse,
              onPublishTalkingPoint: _publishTalkingPointBrowse,
            ),
          );
          out.add(const SizedBox(height: 12));
          out.add(
            _ExpectationsOthersSection(
              title: 'Archive',
              emptyText: activeTag == null
                  ? 'No archived published talking points.'
                  : 'No archive for #$activeTag.',
              items: archive,
              peopleById: peopleById,
              theme: theme,
              scheme: scheme,
              collapsed: _tagsArchiveCollapsed,
              hasUnreadChat: _hasUnreadChat,
              onTagPressed: _openTagPillar,
              onOpenDetails: (e, p) => _openExpectationDetails(e: e, person: p),
              onDeleteExpectation: _deleteExpectationFromList,
              onToggleCollapsed: () {
                setState(() => _tagsArchiveCollapsed = !_tagsArchiveCollapsed);
              },
              talkingPointsBrowseListing: true,
              onArchiveTalkingPoint: _archiveTalkingPointBrowse,
              onPublishTalkingPoint: _publishTalkingPointBrowse,
            ),
          );
        }
        break;

      case LedgerPillar.expectationsMe:
        if (_expectationsLoading) {
          out.add(const _ExpectationsLoadingCard());
          break;
        }
        if (_expectationsLoadError != null) {
          out.add(
            _ExpectationsErrorCard(
              message: _expectationsLoadError!,
              onRetry: _loadExpectationsFromSupabase,
            ),
          );
          break;
        }
        if (mePerson != null) {
          final currentUserId = Supabase.instance.client.auth.currentUser?.id;
          final towardsMe = expectations
              .where(
                (x) =>
                    x.personId == mePerson.id &&
                    x.type == ExpectationType.expectation,
              )
              .toList();
          final towardsMeForTab = towardsMe
              .where((x) => _inboxTabMatchesWriter(x, currentUserId))
              .toList();
          final availableTags = towardsMeForTab
              .expand((e) => _extractInlineTags(e.summary))
              .toSet()
              .toList()
            ..sort();
          final writersInvolved = towardsMeForTab
              .map((e) => _writerPersonForExpectation(e, people))
              .whereType<Person>()
              .toList();
          final personOptions = {
            for (final p in writersInvolved) p.id: p,
          }.values.toList()
            ..sort((a, b) => a.displayName.toLowerCase().compareTo(b.displayName.toLowerCase()));
          final effectiveInboxTag = availableTags.contains(_inboxTagFilter)
              ? _inboxTagFilter
              : null;
          final effectiveInboxPerson = personOptions.any((p) => p.id == _inboxPersonFilter)
              ? _inboxPersonFilter
              : null;
          final filteredTowardsMe = towardsMeForTab.where((x) {
            final statusMatch =
                _inboxStatusFilter == null || x.status == _inboxStatusFilter;
            final tagMatch = effectiveInboxTag == null
                ? true
                : _extractInlineTags(x.summary)
                      .map((t) => t.toLowerCase())
                      .contains(effectiveInboxTag.toLowerCase());
            final writer = _writerPersonForExpectation(x, people);
            final personMatch = effectiveInboxPerson == null ||
                writer?.id == effectiveInboxPerson;
            return statusMatch && tagMatch && personMatch;
          }).toList();
          out.add(
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  SegmentedButton<_InboxListingTab>(
                    style: SegmentedButton.styleFrom(
                      visualDensity: VisualDensity.compact,
                      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 10),
                      surfaceTintColor: Colors.transparent,
                      selectedBackgroundColor: _pillarAccentBarColor(
                        LedgerPillar.expectationsMe,
                        theme,
                      ),
                      selectedForegroundColor:
                          ThemeData.estimateBrightnessForColor(
                                    LedgerPillar.expectationsMe.captureAccent,
                                  ) ==
                                  Brightness.dark
                              ? Colors.white
                              : scheme.onSurface,
                      foregroundColor: scheme.onSurfaceVariant,
                      backgroundColor: scheme.surfaceContainerHighest
                          .withValues(alpha: 0.55),
                    ),
                    segments: const [
                      ButtonSegment<_InboxListingTab>(
                        value: _InboxListingTab.fromOthers,
                        label: Text('From Others'),
                        icon: Icon(Icons.group_outlined, size: 18),
                      ),
                      ButtonSegment<_InboxListingTab>(
                        value: _InboxListingTab.personal,
                        label: Text('Personal'),
                        icon: Icon(Icons.person_outlined, size: 18),
                      ),
                    ],
                    selected: {_inboxListingTab},
                    onSelectionChanged: _onInboxListingTabChanged,
                  ),
                  const Spacer(),
                  _ExpectationsOthersFiltersBar(
                    selectedStatus: _inboxStatusFilter,
                    selectedTag: effectiveInboxTag,
                    selectedPersonId: effectiveInboxPerson,
                    tags: availableTags,
                    people: personOptions,
                    onStatusChanged: (v) {
                      setState(() => _inboxStatusFilter = v);
                    },
                    onTagChanged: (v) {
                      setState(() => _inboxTagFilter = v);
                    },
                    onPersonChanged: (v) {
                      setState(() => _inboxPersonFilter = v);
                    },
                  ),
                ],
              ),
            ),
          );
          final now = DateTime.now().toUtc();
          final twoWeeksAgo = now.subtract(const Duration(days: 14));
          final isTerminal = (Expectation x) =>
              x.status == ExpectationStatus.finished ||
              x.status == ExpectationStatus.abandoned;
          final inboundPublished = filteredTowardsMe
              .where((x) => x.visibility == ExpectationVisibility.echo)
              .toList();
          final shadowIncoming = filteredTowardsMe
              .where(
                (x) =>
                    x.visibility == ExpectationVisibility.shadow &&
                    !isTerminal(x),
              )
              .toList();
          final echoOngoing =
              inboundPublished.where((x) => !isTerminal(x)).toList();
          final ongoingIds = <String>{};
          final ongoing = <Expectation>[];
          for (final e in [...shadowIncoming, ...echoOngoing]) {
            if (ongoingIds.add(e.id)) ongoing.add(e);
          }
          final recentlyFinished = inboundPublished
              .where(
                (x) =>
                    x.status == ExpectationStatus.finished &&
                    _finishedReferenceAt(x).isAfter(twoWeeksAgo),
              )
              .toList();
          final archive = filteredTowardsMe.where(isTerminal).toList();
          out.add(
            _ExpectationsOthersSection(
              title: 'Active',
              emptyText: 'No active expectations in your inbox yet.',
              infoTooltip:
                  'Active items include unpublished incoming drafts and published expectations that are still active.',
              items: ongoing,
              peopleById: peopleById,
              theme: theme,
              scheme: scheme,
              collapsed: _meOngoingCollapsed,
              hasUnreadChat: _hasUnreadChat,
              onTagPressed: _openTagPillar,
              personForItem: (e) => _writerPersonForExpectation(e, people),
              onOpenDetails: (e, p) =>
                  _openExpectationDetails(e: e, person: p),
              onDeleteExpectation: _deleteExpectationFromList,
              onToggleCollapsed: () {
                setState(() => _meOngoingCollapsed = !_meOngoingCollapsed);
              },
              inboxHoverListing: true,
              inboxHoverIncludeDelete:
                  _inboxListingTab == _InboxListingTab.personal,
              inboxReceiverPersonId: mePerson.id,
              onArchiveInbox: _archiveInboxExpectation,
            ),
          );
          if (recentlyFinished.isNotEmpty) {
            out.add(const SizedBox(height: 12));
            out.add(
              _ExpectationsOthersSection(
                title: 'Finished',
                emptyText: 'No recently finished expectations (last 2 weeks).',
                items: recentlyFinished,
                peopleById: peopleById,
                theme: theme,
                scheme: scheme,
                collapsed: _meFinishedCollapsed,
                hasUnreadChat: _hasUnreadChat,
                onTagPressed: _openTagPillar,
                personForItem: (e) => _writerPersonForExpectation(e, people),
                onOpenDetails: (e, p) =>
                    _openExpectationDetails(e: e, person: p),
                onDeleteExpectation: _deleteExpectationFromList,
                onToggleCollapsed: () {
                  setState(() => _meFinishedCollapsed = !_meFinishedCollapsed);
                },
                inboxHoverListing: true,
                inboxHoverIncludeDelete:
                    _inboxListingTab == _InboxListingTab.personal,
                inboxReceiverPersonId: mePerson.id,
                onArchiveInbox: _archiveInboxExpectation,
              ),
            );
          }
          out.add(const SizedBox(height: 12));
          out.add(
            _ExpectationsOthersSection(
              title: 'Archive',
              emptyText: 'No archived expectations.',
              items: archive,
              peopleById: peopleById,
              theme: theme,
              scheme: scheme,
              collapsed: _meArchiveCollapsed,
              hasUnreadChat: _hasUnreadChat,
              onTagPressed: _openTagPillar,
              personForItem: (e) => _writerPersonForExpectation(e, people),
              onOpenDetails: (e, p) =>
                  _openExpectationDetails(e: e, person: p),
              onDeleteExpectation: _deleteExpectationFromList,
              onToggleCollapsed: () {
                setState(() => _meArchiveCollapsed = !_meArchiveCollapsed);
              },
            ),
          );
        }
        break;

      case LedgerPillar.expectationsOthers:
        final meId = mePerson?.id;
        final currentUserId = Supabase.instance.client.auth.currentUser?.id;
        if (_expectationsLoading) {
          out.add(const _ExpectationsLoadingCard());
          break;
        }
        if (_expectationsLoadError != null) {
          out.add(
            _ExpectationsErrorCard(
              message: _expectationsLoadError!,
              onRetry: _loadExpectationsFromSupabase,
            ),
          );
          break;
        }
        final towardsOthers = expectations.where((x) {
          if (x.type != ExpectationType.expectation) return false;
          if (currentUserId != null && x.writerUserId != currentUserId) return false;
          if (meId == null) return true;
          return x.personId != meId;
        }).toList();
        final availableTags = towardsOthers
            .expand((e) => _extractInlineTags(e.summary))
            .toSet()
            .toList()
          ..sort();
        final peopleInvolved = towardsOthers
            .map((e) => peopleById[e.personId])
            .whereType<Person>()
            .toList();
        final personOptions = {
          for (final p in peopleInvolved) p.id: p,
        }.values.toList()
          ..sort((a, b) => a.displayName.toLowerCase().compareTo(b.displayName.toLowerCase()));
        final effectiveTagFilter = availableTags.contains(_othersTagFilter)
            ? _othersTagFilter
            : null;
        final effectivePersonFilter = personOptions.any((p) => p.id == _othersPersonFilter)
            ? _othersPersonFilter
            : null;
        final filteredTowardsOthers = towardsOthers.where((x) {
          final statusMatch =
              _othersStatusFilter == null || x.status == _othersStatusFilter;
          final tagMatch = effectiveTagFilter == null
              ? true
              : _extractInlineTags(x.summary)
                    .map((t) => t.toLowerCase())
                    .contains(effectiveTagFilter.toLowerCase());
          final personMatch =
              effectivePersonFilter == null || x.personId == effectivePersonFilter;
          return statusMatch && tagMatch && personMatch;
        }).toList();
        out.add(
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                SegmentedButton<_OutboxListingTab>(
                  style: SegmentedButton.styleFrom(
                    visualDensity: VisualDensity.compact,
                    padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 10),
                    surfaceTintColor: Colors.transparent,
                    selectedBackgroundColor: _pillarAccentBarColor(
                      LedgerPillar.expectationsOthers,
                      theme,
                    ),
                    selectedForegroundColor:
                        ThemeData.estimateBrightnessForColor(
                                  LedgerPillar.expectationsOthers.captureAccent,
                                ) ==
                                Brightness.dark
                            ? Colors.white
                            : scheme.onSurface,
                    foregroundColor: scheme.onSurfaceVariant,
                    backgroundColor: scheme.surfaceContainerHighest
                        .withValues(alpha: 0.55),
                  ),
                  segments: const [
                    ButtonSegment<_OutboxListingTab>(
                      value: _OutboxListingTab.published,
                      label: Text('Published'),
                      icon: Icon(Icons.public_outlined, size: 18),
                    ),
                    ButtonSegment<_OutboxListingTab>(
                      value: _OutboxListingTab.drafts,
                      label: Text('Drafts'),
                      icon: Icon(Icons.edit_note_outlined, size: 18),
                    ),
                  ],
                  selected: {_outboxListingTab},
                  onSelectionChanged: _onOutboxListingTabChanged,
                ),
                const Spacer(),
                _ExpectationsOthersFiltersBar(
                  selectedStatus: _othersStatusFilter,
                  selectedTag: effectiveTagFilter,
                  selectedPersonId: effectivePersonFilter,
                  tags: availableTags,
                  people: personOptions,
                  onStatusChanged: (v) {
                    setState(() => _othersStatusFilter = v);
                  },
                  onTagChanged: (v) {
                    setState(() => _othersTagFilter = v);
                  },
                  onPersonChanged: (v) {
                    setState(() => _othersPersonFilter = v);
                  },
                ),
              ],
            ),
          ),
        );
        final now = DateTime.now().toUtc();
        final twoWeeksAgo = now.subtract(const Duration(days: 14));
        final isTerminal = (Expectation x) =>
            x.status == ExpectationStatus.finished ||
            x.status == ExpectationStatus.abandoned;
        if (_outboxListingTab == _OutboxListingTab.drafts) {
          final draftsOnly = filteredTowardsOthers
              .where(
                (x) =>
                    x.visibility == ExpectationVisibility.shadow &&
                    !isTerminal(x),
              )
              .toList();
          out.add(
            _ExpectationsOthersSection(
              title: 'Drafts',
              emptyText: 'No draft expectations yet.',
              infoTooltip:
                  'Drafts are only visible to you until you publish them to the receiver.',
              items: draftsOnly,
              peopleById: peopleById,
              theme: theme,
              scheme: scheme,
              collapsed: _othersDraftsCollapsed,
              hasUnreadChat: _hasUnreadChat,
              onTagPressed: _openTagPillar,
              onOpenDetails: (e, p) => _openExpectationDetails(e: e, person: p),
              onDeleteExpectation: _deleteExpectationFromList,
              onToggleCollapsed: () {
                setState(() => _othersDraftsCollapsed = !_othersDraftsCollapsed);
              },
              outboxDraftsListing: true,
              onPublishDraft: _publishOutboxDraft,
              onArchiveDraft: _archiveOutboxDraft,
            ),
          );
          final archiveDrafts = filteredTowardsOthers
              .where(
                (x) =>
                    x.visibility == ExpectationVisibility.shadow &&
                    isTerminal(x),
              )
              .toList();
          out.add(const SizedBox(height: 12));
          out.add(
            _ExpectationsOthersSection(
              title: 'Archive',
              emptyText: 'No archived drafts yet.',
              items: archiveDrafts,
              peopleById: peopleById,
              theme: theme,
              scheme: scheme,
              collapsed: _othersArchiveCollapsed,
              hasUnreadChat: _hasUnreadChat,
              onTagPressed: _openTagPillar,
              onOpenDetails: (e, p) => _openExpectationDetails(e: e, person: p),
              onDeleteExpectation: _deleteExpectationFromList,
              onToggleCollapsed: () {
                setState(
                  () => _othersArchiveCollapsed = !_othersArchiveCollapsed,
                );
              },
            ),
          );
        } else {
          final publishedPool = filteredTowardsOthers
              .where((x) => x.visibility == ExpectationVisibility.echo)
              .toList();
          final published = publishedPool
              .where((x) => !isTerminal(x))
              .toList();
          final recentlyFinished = publishedPool
              .where(
                (x) =>
                    x.status == ExpectationStatus.finished &&
                    _finishedReferenceAt(x).isAfter(twoWeeksAgo),
              )
              .toList();
          final archive = filteredTowardsOthers
              .where(
                (x) =>
                    x.visibility == ExpectationVisibility.echo && isTerminal(x),
              )
              .toList();
          out.add(
            _ExpectationsOthersSection(
              title: 'Active',
              emptyText: 'No active expectations towards others yet.',
              infoTooltip:
                  'Active items are published and can be seen by you and your receiver, but nobody else',
              items: published,
              peopleById: peopleById,
              theme: theme,
              scheme: scheme,
              collapsed: _othersPublishedCollapsed,
              hasUnreadChat: _hasUnreadChat,
              onTagPressed: _openTagPillar,
              onOpenDetails: (e, p) => _openExpectationDetails(e: e, person: p),
              onDeleteExpectation: _deleteExpectationFromList,
              onToggleCollapsed: () {
                setState(
                  () => _othersPublishedCollapsed = !_othersPublishedCollapsed,
                );
              },
              outboxPublishedListing: true,
              onArchiveDraft: _archiveOutboxDraft,
            ),
          );
          if (recentlyFinished.isNotEmpty) {
            out.add(const SizedBox(height: 12));
            out.add(
              _ExpectationsOthersSection(
                title: 'Finished',
                emptyText: 'No recently finished expectations (last 2 weeks).',
                items: recentlyFinished,
                peopleById: peopleById,
                theme: theme,
                scheme: scheme,
                collapsed: _othersFinishedCollapsed,
                hasUnreadChat: _hasUnreadChat,
                onTagPressed: _openTagPillar,
                onOpenDetails: (e, p) => _openExpectationDetails(e: e, person: p),
                onDeleteExpectation: _deleteExpectationFromList,
                onToggleCollapsed: () {
                  setState(
                    () => _othersFinishedCollapsed = !_othersFinishedCollapsed,
                  );
                },
                outboxPublishedListing: true,
                onArchiveDraft: _archiveOutboxDraft,
              ),
            );
          }
          out.add(const SizedBox(height: 12));
          out.add(
            _ExpectationsOthersSection(
              title: 'Archive',
              emptyText: 'No archived expectations.',
              items: archive,
              peopleById: peopleById,
              theme: theme,
              scheme: scheme,
              collapsed: _othersArchiveCollapsed,
              hasUnreadChat: _hasUnreadChat,
              onTagPressed: _openTagPillar,
              onOpenDetails: (e, p) => _openExpectationDetails(e: e, person: p),
              onDeleteExpectation: _deleteExpectationFromList,
              onToggleCollapsed: () {
                setState(
                  () => _othersArchiveCollapsed = !_othersArchiveCollapsed,
                );
              },
            ),
          );
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
      };

  static String _labelFor(AppThemeVariant v) => switch (v) {
        AppThemeVariant.light => 'Light',
        AppThemeVariant.dark => 'Dark',
      };
}

enum _OutboxListingTab {
  published,
  drafts,
}

enum _InboxListingTab {
  fromOthers,
  personal,
}

enum _ComposerEntryMode {
  topic,
  expectation,
}

/// Save Expectation pillar: which action Enter / Tab emphasis use (default draft).
enum _ExpectationPillarQuickChoice {
  draft,
  sendImmediately,
}

enum _ExpectationSubmitMode {
  draft,
  inform,
}

enum _TalkingPointsSubView {
  colleagues,
  meetingsOrTags,
}

/// One colleague with how many @-linked talking points (for cloud sizing).
class _ColleagueCloudEntry {
  const _ColleagueCloudEntry({required this.person, required this.count});
  final Person person;
  final int count;
}

/// @-handle chips for the rail (Private view uses the main dropdown; rail is quick filter).
class _ColleagueAtNameCloud extends StatelessWidget {
  const _ColleagueAtNameCloud({
    required this.entries,
    required this.selectedPersonId,
    required this.onSelectPerson,
    this.maxChips = 20,
    this.onPersonTapFromRail,
  });

  final List<_ColleagueCloudEntry> entries;
  final String? selectedPersonId;
  final ValueChanged<String?> onSelectPerson;
  final int maxChips;
  final void Function(String personId)? onPersonTapFromRail;

  @override
  Widget build(BuildContext context) {
    if (entries.isEmpty) return const SizedBox.shrink();
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final limit = maxChips.clamp(1, 1 << 20);
    final shown = entries.take(limit).toList();
    final more = entries.length > limit;
    return Wrap(
      alignment: WrapAlignment.start,
      spacing: 6,
      runSpacing: 6,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        for (final e in shown)
          LedgerTagChip(
            tag: e.person.handle,
            tokenPrefix: '@',
            unselectedLabelColor: LedgerListingAccents.topic,
            selected: selectedPersonId == e.person.id,
            selectionAccent: LedgerListingAccents.topic,
            onPressed: () {
              if (onPersonTapFromRail != null) {
                onPersonTapFromRail!(e.person.id);
              } else if (selectedPersonId == e.person.id) {
                onSelectPerson(null);
              } else {
                onSelectPerson(e.person.id);
              }
            },
          ),
        if (more)
          Text(
            '…',
            style: theme.textTheme.labelSmall?.copyWith(
              color: scheme.onSurfaceVariant,
              fontWeight: FontWeight.w600,
            ),
          ),
      ],
    );
  }
}

class _PillarRail extends StatelessWidget {
  const _PillarRail({
    required this.expanded,
    required this.selected,
    required this.recentTags,
    required this.recentTagsHasMore,
    required this.privateRailTags,
    required this.onPrivateRailTag,
    required this.tagsLoading,
    required this.tagsLoadError,
    required this.onRetryTags,
    required this.talkingPointsSubView,
    required this.colleagueCloudEntries,
    required this.colleagueFilterPersonId,
    required this.onColleagueFilterSelect,
    required this.onColleagueRailPersonTap,
    required this.footerDirectoryTitle,
    required this.profileName,
    required this.profileTitle,
    required this.onLogout,
    required this.onSelect,
    required this.onOpenExpectationCapture,
    required this.onOpenTopicCapture,
    required this.onTalkingPointsBrowse,
    required this.onTagSelect,
    required this.onInviteTap,
  });

  static const double _widthExpanded = 280;
  static const double _widthCollapsed = 72;
  /// Aligns heading “+” with [ListTile] trailing (see Talking points tile [contentPadding]).
  static const double _railPlusRightInset = 16;
  static const double _railPlusDiameter = 32;
  /// Trailing Invite / Logout share this width so their right edges align.
  static const double _footerActionSlotWidth = 96;

  static const List<LedgerPillar> _sidebarOrder = [
    LedgerPillar.expectationsMe,
    LedgerPillar.expectationsOthers,
  ];

  final bool expanded;
  final LedgerPillar selected;
  final List<String> recentTags;
  final bool recentTagsHasMore;
  final List<String> privateRailTags;
  final ValueChanged<String> onPrivateRailTag;
  final bool tagsLoading;
  final String? tagsLoadError;
  final VoidCallback onRetryTags;
  final _TalkingPointsSubView talkingPointsSubView;
  final List<_ColleagueCloudEntry> colleagueCloudEntries;
  final String? colleagueFilterPersonId;
  final ValueChanged<String?> onColleagueFilterSelect;
  final ValueChanged<String> onColleagueRailPersonTap;
  /// Shown on the footer directory row (company name from DB, or "People").
  final String footerDirectoryTitle;
  final String profileName;
  final String? profileTitle;
  final Future<void> Function() onLogout;
  final ValueChanged<LedgerPillar> onSelect;
  final VoidCallback onOpenExpectationCapture;
  final VoidCallback onOpenTopicCapture;
  final ValueChanged<_TalkingPointsSubView> onTalkingPointsBrowse;
  final ValueChanged<String> onTagSelect;
  final Future<void> Function() onInviteTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final colleagueRailCloudChild = colleagueCloudEntries.isEmpty
        ? const SizedBox.shrink()
        : _ColleagueAtNameCloud(
            entries: colleagueCloudEntries,
            selectedPersonId: colleagueFilterPersonId,
            onSelectPerson: onColleagueFilterSelect,
            maxChips: 20,
            onPersonTapFromRail: onColleagueRailPersonTap,
          );
    final railColor = theme.drawerTheme.backgroundColor ??
        scheme.surfaceContainerLow;
    return AnimatedContainer(
      duration: const Duration(milliseconds: 220),
      curve: Curves.easeOutCubic,
      width: expanded ? _widthExpanded : _widthCollapsed,
      child: Material(
        color: railColor,
        child: Column(
          children: [
            Expanded(
              child: ListView(
                padding: const EdgeInsets.symmetric(vertical: 8),
                children: [
                  if (expanded) ...[
                    ListTile(
                      leading: const Icon(Icons.home_outlined),
                      title: const Text('Home'),
                      selected: selected == LedgerPillar.home,
                      selectedTileColor: LedgerPillar.home.captureAccent
                          .withValues(alpha: 0.14),
                      onTap: () => onSelect(LedgerPillar.home),
                    ),
                    _railSectionHeading(
                      context,
                      'Expectations',
                      primary: true,
                      sectionAccent: LedgerListingAccents.expectation,
                      onTitleTap: onOpenExpectationCapture,
                      titleSelected: selected == LedgerPillar.addExpectation,
                      selectedAccent: LedgerListingAccents.expectation,
                      trailing: _railHomeCaptureCircle(
                        scheme,
                        onOpenExpectationCapture,
                        tooltip: 'Add expectation',
                        fillColor: LedgerPillar.addExpectation.captureAccent,
                      ),
                    ),
                    for (final p in _sidebarOrder)
                      _expandedPillarTile(
                        context,
                        p: p,
                        selected: selected,
                        onSelect: onSelect,
                      ),
                    const SizedBox(height: 10),
                    _railSectionHeading(
                      context,
                      LedgerPillar.tags.title,
                      primary: false,
                      sectionAccent: LedgerListingAccents.topic,
                      onTitleTap: onOpenTopicCapture,
                      titleSelected: selected == LedgerPillar.addTopic,
                      selectedAccent: LedgerListingAccents.topic,
                      trailing: _railHomeCaptureCircle(
                        scheme,
                        onOpenTopicCapture,
                        tooltip: 'Add talking point',
                        fillColor: LedgerPillar.addTopic.captureAccent,
                      ),
                    ),
                    ListTile(
                      dense: true,
                      contentPadding: const EdgeInsets.fromLTRB(20, 0, 12, 0),
                      leading: Icon(
                        Icons.lock_outline,
                        size: 20,
                        color: LedgerListingAccents.topic,
                      ),
                      title: const Text('Private'),
                      selected: selected == LedgerPillar.tags &&
                          talkingPointsSubView ==
                              _TalkingPointsSubView.colleagues,
                      selectedTileColor:
                          LedgerListingAccents.topic.withValues(alpha: 0.12),
                      onTap: () =>
                          onTalkingPointsBrowse(_TalkingPointsSubView.colleagues),
                    ),
                    Padding(
                      padding: const EdgeInsets.fromLTRB(12, 0, 12, 6),
                      child: colleagueRailCloudChild,
                    ),
                    if (privateRailTags.isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
                        child: Wrap(
                          spacing: 6,
                          runSpacing: 6,
                          crossAxisAlignment: WrapCrossAlignment.center,
                          children: [
                            for (final tag in privateRailTags)
                              LedgerTagChip(
                                tag: tag,
                                onPressed: () => onPrivateRailTag(tag),
                              ),
                          ],
                        ),
                      ),
                    ListTile(
                      dense: true,
                      contentPadding: const EdgeInsets.fromLTRB(20, 0, 12, 0),
                      leading: Icon(
                        Icons.public_outlined,
                        size: 20,
                        color: LedgerListingAccents.topic,
                      ),
                      title: const Text('Public'),
                      selected: selected == LedgerPillar.tags &&
                          talkingPointsSubView ==
                              _TalkingPointsSubView.meetingsOrTags,
                      selectedTileColor:
                          LedgerListingAccents.topic.withValues(alpha: 0.12),
                      onTap: () =>
                          onTalkingPointsBrowse(_TalkingPointsSubView.meetingsOrTags),
                    ),
                    Padding(
                      padding: const EdgeInsets.fromLTRB(12, 4, 12, 4),
                      child: tagsLoading
                          ? const SizedBox(
                              height: 2,
                              child: LinearProgressIndicator(minHeight: 2),
                            )
                          : tagsLoadError != null
                          ? Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  tagsLoadError!,
                                  style: theme.textTheme.bodySmall?.copyWith(
                                    color: scheme.error,
                                  ),
                                ),
                                TextButton(
                                  onPressed: onRetryTags,
                                  child: const Text('Retry'),
                                ),
                              ],
                            )
                          : (recentTags.isNotEmpty || recentTagsHasMore)
                          ? Wrap(
                              spacing: 6,
                              runSpacing: 6,
                              crossAxisAlignment: WrapCrossAlignment.center,
                              children: [
                                for (final tag in recentTags)
                                  LedgerTagChip(
                                    tag: tag,
                                    onPressed: () => onTagSelect(tag),
                                  ),
                                if (recentTagsHasMore)
                                  Text(
                                    '…',
                                    style: theme.textTheme.labelSmall?.copyWith(
                                      color: scheme.onSurfaceVariant,
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                              ],
                            )
                          : const SizedBox.shrink(),
                    ),
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
                      p: LedgerPillar.tags,
                      selected: selected,
                      onSelect: onSelect,
                    ),
                  ],
                ],
              ),
            ),
            if (!expanded)
              Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: IconButton(
                  tooltip: 'Invite',
                  onPressed: onInviteTap,
                  icon: const Icon(Icons.person_add_alt_1_outlined),
                ),
              ),
            const Divider(height: 1),
            if (expanded)
              Padding(
                padding: const EdgeInsets.fromLTRB(8, 6, 8, 10),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    _railFooterDirectoryRow(
                      context,
                      title: footerDirectoryTitle,
                      subtitle: LedgerPillar.people.description,
                      accent: LedgerPillar.people.accent,
                      selected: selected == LedgerPillar.people,
                      onTap: () => onSelect(LedgerPillar.people),
                      onInviteTap: onInviteTap,
                    ),
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 8),
                      child: Divider(
                        height: 1,
                        thickness: 1,
                        color: scheme.outlineVariant.withValues(alpha: 0.55),
                      ),
                    ),
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.center,
                      children: [
                        CircleAvatar(
                          radius: 16,
                          child: Text(
                            profileName.trim().isNotEmpty
                                ? profileName.trim()[0].toUpperCase()
                                : '?',
                          ),
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                profileName.startsWith('@')
                                    ? profileName
                                    : '@$profileName',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: theme.textTheme.bodyMedium?.copyWith(
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                              if ((profileTitle ?? '').trim().isNotEmpty)
                                Text(
                                  profileTitle!.trim(),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: theme.textTheme.bodySmall?.copyWith(
                                    color: scheme.onSurfaceVariant,
                                  ),
                                ),
                            ],
                          ),
                        ),
                        SizedBox(
                          width: _footerActionSlotWidth,
                          child: Align(
                            alignment: Alignment.centerRight,
                            child: TextButton(
                              onPressed: onLogout,
                              style: TextButton.styleFrom(
                                padding: EdgeInsets.zero,
                                minimumSize: const Size(0, 0),
                                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                                visualDensity: VisualDensity.compact,
                              ),
                              child: const Text('Logout'),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              )
            else
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 6),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    _collapsedPillarDot(
                      context,
                      p: LedgerPillar.people,
                      selected: selected,
                      onSelect: onSelect,
                      tooltipTitle: footerDirectoryTitle,
                    ),
                    IconButton(
                      tooltip: 'Logout',
                      onPressed: onLogout,
                      icon: const Icon(Icons.logout),
                    ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }

  /// Footer row above profile: icon in same 32px slot as [CircleAvatar] (r=16).
  Widget _railFooterDirectoryRow(
    BuildContext context, {
    required String title,
    required String subtitle,
    required Color accent,
    required bool selected,
    required VoidCallback onTap,
    required Future<void> Function() onInviteTap,
  }) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Material(
      color: selected ? accent.withValues(alpha: 0.12) : Colors.transparent,
      borderRadius: BorderRadius.circular(10),
      clipBehavior: Clip.antiAlias,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Expanded(
            child: InkWell(
              onTap: onTap,
              borderRadius: BorderRadius.circular(10),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 6),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    SizedBox(
                      width: 32,
                      height: 32,
                      child: Icon(
                        Icons.group_outlined,
                        size: 20,
                        color: accent,
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            title,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.titleSmall?.copyWith(
                              fontWeight: FontWeight.w700,
                              color: scheme.onSurface,
                            ),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            subtitle,
                            maxLines: 3,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: scheme.onSurfaceVariant,
                              height: 1.25,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
          SizedBox(
            width: _footerActionSlotWidth,
            child: Align(
              alignment: Alignment.centerRight,
              child: TextButton.icon(
                onPressed: onInviteTap,
                style: TextButton.styleFrom(
                  visualDensity: VisualDensity.compact,
                  padding: EdgeInsets.zero,
                  minimumSize: Size.zero,
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  foregroundColor: scheme.primary,
                ),
                icon: const Icon(Icons.person_add_alt_1_outlined, size: 16),
                label: const Text('Invite'),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _railSectionHeading(
    BuildContext context,
    String label, {
    bool primary = false,
    Color? sectionAccent,
    Widget? trailing,
    VoidCallback? onTitleTap,
    bool titleSelected = false,
    Color? selectedAccent,
  }) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final defaultColor = scheme.onSurfaceVariant;
    final textColor = titleSelected && selectedAccent != null
        ? selectedAccent
        : defaultColor;
    final baseStyle = theme.textTheme.titleMedium ??
        theme.textTheme.titleSmall ??
        const TextStyle(fontSize: 16, fontWeight: FontWeight.w600);
    final textStyle = baseStyle.copyWith(
      color: textColor,
      fontWeight: FontWeight.w600,
      height: 1.2,
    );
    Widget titleWidget = Text(label, style: textStyle);
    if (onTitleTap != null) {
      titleWidget = InkWell(
        onTap: onTitleTap,
        borderRadius: BorderRadius.circular(6),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 4, horizontal: 2),
          child: titleWidget,
        ),
      );
    }
    final labelRow = Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        if (sectionAccent != null) ...[
          Container(
            width: 3,
            height: 20,
            decoration: BoxDecoration(
              color: sectionAccent,
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          const SizedBox(width: 10),
        ],
        Expanded(child: titleWidget),
        if (trailing != null) trailing,
      ],
    );
    return Padding(
      padding: EdgeInsets.fromLTRB(
        20,
        primary ? 16 : 10,
        trailing != null ? _railPlusRightInset : 20,
        6,
      ),
      child: trailing == null && sectionAccent == null
          ? titleWidget
          : labelRow,
    );
  }

  /// Filled circle with “+”; used for Expectations and Talking points headings.
  Widget _railHomeCaptureCircle(
    ColorScheme scheme,
    VoidCallback onPressed, {
    String tooltip = 'Add',
    Color? fillColor,
  }) {
    final fill = fillColor ?? scheme.primary;
    final iconColor = ThemeData.estimateBrightnessForColor(fill) ==
            Brightness.dark
        ? Colors.white
        : const Color(0xFF1B1D21);
    return Tooltip(
      message: tooltip,
      child: Material(
        color: fill,
        shape: const CircleBorder(),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onPressed,
          customBorder: const CircleBorder(),
          child: SizedBox(
            width: _railPlusDiameter,
            height: _railPlusDiameter,
            child: Icon(
              Icons.add,
              size: 20,
              color: iconColor,
            ),
          ),
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
      LedgerPillar.addExpectation => Icons.flag_outlined,
      LedgerPillar.addTopic => Icons.forum_outlined,
      LedgerPillar.expectationsMe => Icons.south_west_outlined,
      LedgerPillar.expectationsOthers => Icons.north_east_outlined,
      LedgerPillar.people => Icons.group_outlined,
      LedgerPillar.tags => Icons.tag_outlined,
    };
    return ListTile(
      leading: Icon(icon, size: 18, color: p.accent),
      title: Text(p.title),
      subtitle: p == LedgerPillar.home ||
              p == LedgerPillar.addExpectation ||
              p == LedgerPillar.addTopic
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
    String? tooltipTitle,
  }) {
    final scheme = Theme.of(context).colorScheme;
    final tipTitle = tooltipTitle ?? p.title;
    final icon = switch (p) {
      LedgerPillar.home => Icons.home_outlined,
      LedgerPillar.addExpectation => Icons.flag_outlined,
      LedgerPillar.addTopic => Icons.forum_outlined,
      LedgerPillar.expectationsMe => Icons.south_west_outlined,
      LedgerPillar.expectationsOthers => Icons.north_east_outlined,
      LedgerPillar.people => Icons.group_outlined,
      LedgerPillar.tags => Icons.tag_outlined,
    };
    return Tooltip(
      message: '$tipTitle\n${p.description}',
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

class _PeopleGlassCard extends StatelessWidget {
  const _PeopleGlassCard({
    required this.person,
    required this.theme,
    required this.scheme,
    required this.onTap,
  });

  final Person person;
  final ThemeData theme;
  final ColorScheme scheme;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(14),
        child: _Glass(
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
        ),
      ),
    );
  }
}

class _PeopleTileGrid extends StatelessWidget {
  const _PeopleTileGrid({
    required this.people,
    required this.theme,
    required this.scheme,
    required this.onPersonTap,
  });

  final List<Person> people;
  final ThemeData theme;
  final ColorScheme scheme;
  final ValueChanged<Person> onPersonTap;

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
                child: _PeopleGlassCard(
                  person: p,
                  theme: theme,
                  scheme: scheme,
                  onTap: () => onPersonTap(p),
                ),
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
          Text('Loading talking points...'),
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

class _ExpectationsLoadingCard extends StatelessWidget {
  const _ExpectationsLoadingCard();

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
          Text('Loading expectations from Supabase...'),
        ],
      ),
    );
  }
}

class _ExpectationsErrorCard extends StatelessWidget {
  const _ExpectationsErrorCard({
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

/// Same paint as the main title “|” bar — keep tab highlights visually identical.
Color _pillarAccentBarColor(LedgerPillar pillar, ThemeData theme) {
  var base = pillar.captureAccent;
  if (pillar == LedgerPillar.home && theme.brightness == Brightness.light) {
    base = Color.lerp(base, theme.colorScheme.onSurface, 0.28)!;
  }
  return base.withValues(alpha: 0.94);
}

class _PillarHeader extends StatelessWidget {
  const _PillarHeader({required this.pillar, required this.theme});

  final LedgerPillar pillar;
  final ThemeData theme;

  @override
  Widget build(BuildContext context) {
    final scheme = theme.colorScheme;
    final barColor = _pillarAccentBarColor(pillar, theme);
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
                  color: barColor,
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
          if (pillar.description.trim().isNotEmpty) ...[
            const SizedBox(height: 8),
            Text(
              pillar.description,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: scheme.onSurfaceVariant,
                height: 1.35,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// Save row under the composer. Three idle tiers: disabled (gray), Enter-default
/// (stronger light blue), secondary enabled (paler blue). Hover or Tab focus on this
/// button uses full [ColorScheme.primary]. Tab order is driven in [_onHardwareKey].
class _PairedSaveAction extends StatelessWidget {
  const _PairedSaveAction({
    required this.focusNode,
    required this.enabled,
    required this.onPressed,
    required this.label,
    this.autofocus = false,
    /// Stronger light-blue idle state while the capture field is focused (Enter default).
    /// Does not move focus. Hover/Tab on this button still upgrades to [ColorScheme.primary].
    this.emphasizeAsKeyboardDefault = false,
  });

  final FocusNode focusNode;
  final bool enabled;
  final VoidCallback onPressed;
  final String label;
  final bool autofocus;
  final bool emphasizeAsKeyboardDefault;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return FilledButton(
      focusNode: focusNode,
      autofocus: autofocus,
      onPressed: enabled ? onPressed : null,
      style: ButtonStyle(
        visualDensity: VisualDensity.compact,
        backgroundColor: WidgetStateProperty.resolveWith((states) {
          // 1) Disabled — dark gray
          if (!enabled) {
            return scheme.surfaceContainerHighest.withValues(alpha: 0.45);
          }
          // 4) Hover or Tab on *this* button — strongest (clearly above Enter-default idle)
          if (states.contains(WidgetState.focused) ||
              states.contains(WidgetState.hovered)) {
            return scheme.primary;
          }
          // 3) Enter-default idle (e.g. Save privately while field focused): mid blue —
          // stronger than secondary enabled, softer than hover/focus
          if (emphasizeAsKeyboardDefault) {
            return Color.lerp(
              scheme.primaryContainer,
              scheme.primary,
              0.30,
            )!;
          }
          // 2) Secondary enabled idle (e.g. Save publicly) — palest blue
          return Color.lerp(
            scheme.primaryContainer,
            scheme.surface,
            0.42,
          )!;
        }),
        foregroundColor: WidgetStateProperty.resolveWith((states) {
          if (!enabled) {
            return scheme.onSurface.withValues(alpha: 0.38);
          }
          if (states.contains(WidgetState.focused) ||
              states.contains(WidgetState.hovered)) {
            return Colors.white;
          }
          if (emphasizeAsKeyboardDefault) {
            return Color.lerp(
              scheme.onPrimaryContainer,
              scheme.onPrimary,
              0.35,
            )!;
          }
          return scheme.onPrimaryContainer.withValues(alpha: 0.86);
        }),
      ),
      child: Text(label),
    );
  }
}

/// Home pillar: short intro and placeholder for “waiting” items (dashboard).
class _HomeDashboardPanel extends StatelessWidget {
  const _HomeDashboardPanel({
    required this.theme,
    required this.scheme,
    required this.displayName,
    this.companyName,
  });

  final ThemeData theme;
  final ColorScheme scheme;
  final String displayName;
  final String? companyName;

  @override
  Widget build(BuildContext context) {
    final muted = scheme.onSurfaceVariant;
    final company = companyName?.trim();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Welcome back, $displayName',
          style: theme.textTheme.titleMedium?.copyWith(
            fontWeight: FontWeight.w700,
            color: scheme.onSurface,
          ),
        ),
        if (company != null && company.isNotEmpty) ...[
          const SizedBox(height: 6),
          Text(
            company,
            style: theme.textTheme.bodySmall?.copyWith(
              color: muted,
              height: 1.35,
            ),
          ),
        ],
        const SizedBox(height: 16),
        Text(
          'Use Quick Capture for a talking point or expectation. This space '
          'can surface priorities and waiting items later.',
          style: theme.textTheme.bodyMedium?.copyWith(
            color: muted,
            height: 1.45,
          ),
        ),
        const SizedBox(height: 20),
        Container(
          width: double.infinity,
          padding: const EdgeInsets.fromLTRB(16, 18, 16, 18),
          decoration: BoxDecoration(
            color: scheme.surfaceContainerHigh.withValues(alpha: 0.45),
            borderRadius: BorderRadius.circular(14),
            border: Border.all(
              color: scheme.outlineVariant.withValues(alpha: 0.45),
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Waiting on you',
                style: theme.textTheme.titleSmall?.copyWith(
                  fontWeight: FontWeight.w700,
                  color: scheme.onSurface,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                'Nothing highlighted yet—check Inbox for expectations others '
                'sent you, or Outbox for what you have open with the team.',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: muted,
                  height: 1.4,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _HomeComposerLeadBubble extends StatelessWidget {
  const _HomeComposerLeadBubble({
    required this.theme,
    required this.scheme,
  });

  final ThemeData theme;
  final ColorScheme scheme;

  @override
  Widget build(BuildContext context) {
    final accent = LedgerPillar.home.captureAccent;
    final baseStyle = theme.textTheme.bodyMedium!.copyWith(
      color: scheme.onSurfaceVariant,
      height: 1.5,
    );
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(16, 18, 16, 18),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHigh.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: accent.withValues(alpha: 0.28)),
      ),
      child: Text.rich(
        TextSpan(
          style: baseStyle,
          children: [
            const TextSpan(
              text: 'Talking point = quick note; expectation = commitment to '
                  'someone. Pick the mode below, one line, then ',
            ),
            TextSpan(
              text: 'Enter',
              style: baseStyle.copyWith(
                fontWeight: FontWeight.w700,
                color: scheme.onSurface,
                fontFamily: 'monospace',
              ),
            ),
            const TextSpan(text: '.'),
          ],
        ),
      ),
    );
  }
}

class _HomeUseCasesGuide extends StatelessWidget {
  const _HomeUseCasesGuide({
    required this.theme,
    required this.scheme,
  });

  final ThemeData theme;
  final ColorScheme scheme;

  @override
  Widget build(BuildContext context) {
    final muted = scheme.onSurfaceVariant;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.only(bottom: 20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Examples',
                style: theme.textTheme.titleSmall?.copyWith(
                  fontWeight: FontWeight.w700,
                  color: scheme.onSurface,
                ),
              ),
              const SizedBox(height: 6),
              Text(
                'Three starter lines.',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: muted,
                  height: 1.35,
                ),
              ),
            ],
          ),
        ),
        _HomeGuideCard(
          theme: theme,
          scheme: scheme,
          accent: LedgerListingAccents.topic,
          icon: Icons.forum_outlined,
          title: 'Talking point',
          body: 'Prep or reminder—not a tracked ask.',
          example: '@sam Points for #weeklymeeting: budget + hiring timeline.',
        ),
        _HomeGuideCard(
          theme: theme,
          scheme: scheme,
          accent: LedgerListingAccents.expectation,
          icon: Icons.flag_outlined,
          title: 'Expectation',
          body: 'For someone (@me ok); shows in Inbox/Outbox.',
          example: '@alex Ship #billing fix to staging by Wed EOD.',
        ),
        _HomeGuideCard(
          theme: theme,
          scheme: scheme,
          accent: scheme.tertiary,
          icon: Icons.label_outline,
          title: 'Tags & drafts',
          body: '#tags group threads; draft, then publish when ready.',
          example: '@me #weeklymeeting follow-ups from last session.',
        ),
      ],
    );
  }
}

class _HomeGuideCard extends StatelessWidget {
  const _HomeGuideCard({
    required this.theme,
    required this.scheme,
    required this.accent,
    required this.icon,
    required this.title,
    required this.body,
    required this.example,
  });

  final ThemeData theme;
  final ColorScheme scheme;
  final Color accent;
  final IconData icon;
  final String title;
  final String body;
  final String example;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 18),
      child: Container(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(14),
          color: scheme.surfaceContainerHigh.withValues(alpha: 0.35),
          border: Border.all(
            color: accent.withValues(alpha: 0.3),
          ),
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(14),
          child: IntrinsicHeight(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Container(
                  width: 4,
                  color: accent.withValues(alpha: 0.85),
                ),
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(14, 16, 14, 16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          crossAxisAlignment: CrossAxisAlignment.center,
                          children: [
                            Icon(icon, size: 18, color: accent),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Text(
                                title,
                                style: theme.textTheme.titleSmall?.copyWith(
                                  fontWeight: FontWeight.w700,
                                  color: scheme.onSurface,
                                ),
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 10),
                        Text(
                          body,
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: scheme.onSurfaceVariant,
                            height: 1.45,
                          ),
                        ),
                        const SizedBox(height: 12),
                        Container(
                          width: double.infinity,
                          padding: const EdgeInsets.symmetric(
                            horizontal: 12,
                            vertical: 12,
                          ),
                          decoration: BoxDecoration(
                            color: scheme.surfaceContainerHighest
                                .withValues(alpha: 0.5),
                            borderRadius: BorderRadius.circular(10),
                            border: Border.all(
                              color: accent.withValues(alpha: 0.2),
                            ),
                          ),
                          child: Text(
                            example,
                            style: TextStyle(
                              fontFamily: 'monospace',
                              fontSize: 12,
                              height: 1.4,
                              color: scheme.onSurface.withValues(alpha: 0.9),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
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

class _RecentCaptureTile extends StatefulWidget {
  const _RecentCaptureTile({
    required this.entry,
    required this.scheme,
    required this.theme,
    required this.people,
    this.linkedExpectation,
    this.onOpenDetails,
  });

  final FeedEntry entry;
  final ColorScheme scheme;
  final ThemeData theme;
  final List<Person> people;
  final Expectation? linkedExpectation;
  final VoidCallback? onOpenDetails;

  @override
  State<_RecentCaptureTile> createState() => _RecentCaptureTileState();
}

class _RecentCaptureTileState extends State<_RecentCaptureTile> {
  static final RegExp _mentionRegex = RegExp(r'@([a-zA-Z0-9._-]+)');
  bool _expanded = false;
  bool _canExpand = false;

  String _targetLabel() {
    final parseHandle = widget.entry.parse?.personHandle?.trim();
    final mentionHandle =
        _mentionRegex.firstMatch(widget.entry.body)?.group(1)?.trim();
    final handle =
        (parseHandle?.isNotEmpty ?? false) ? parseHandle! : mentionHandle;
    if (handle == null || handle.isEmpty) return 'General';
    for (final person in widget.people) {
      if (person.handle.toLowerCase() == handle.toLowerCase()) {
        return person.displayName;
      }
    }
    return '@$handle';
  }

  void _syncOverflowState({
    required double maxWidth,
    required TextStyle? style,
  }) {
    if (maxWidth <= 0) return;
    final tp = TextPainter(
      text: TextSpan(text: widget.entry.body, style: style),
      maxLines: 2,
      textDirection: Directionality.of(context),
    )..layout(maxWidth: maxWidth);
    final canExpand = tp.didExceedMaxLines;
    if (canExpand == _canExpand && (canExpand || !_expanded)) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      setState(() {
        _canExpand = canExpand;
        if (!canExpand) {
          _expanded = false;
        }
      });
    });
  }

  @override
  Widget build(BuildContext context) {
    final who = _targetLabel();
    final initials = who.trim().isNotEmpty ? who.trim()[0].toUpperCase() : '?';
    final summaryStyle = widget.theme.textTheme.bodyMedium?.copyWith(
      color: widget.scheme.onSurfaceVariant,
      height: 1.35,
      fontFamily: 'monospace',
      fontSize: 14,
    );
    final parse = widget.entry.parse;
    final showPersonalIndicator =
        widget.linkedExpectation?.visibility == ExpectationVisibility.shadow;
    final rowSurface = widget.linkedExpectation == null
        ? widget.scheme.surfaceContainerHighest.withValues(alpha: 0.32)
        : _ledgerListingRowSurface(
            expectation: widget.linkedExpectation!,
            brightness: widget.theme.brightness,
          );
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      child: Material(
        color: rowSurface,
        borderRadius: BorderRadius.circular(10),
        child: InkWell(
          borderRadius: BorderRadius.circular(10),
          onTap: widget.onOpenDetails,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 9),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
              CircleAvatar(
                radius: 16,
                backgroundColor:
                    widget.scheme.primaryContainer.withValues(alpha: 0.6),
                child: Text(
                  initials,
                  style: widget.theme.textTheme.labelMedium?.copyWith(
                    color: widget.scheme.onPrimaryContainer,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      who,
                      style: widget.theme.textTheme.titleSmall?.copyWith(
                        fontWeight: FontWeight.w700,
                        color: widget.scheme.onSurface,
                      ),
                    ),
                    const SizedBox(height: 6),
                    LayoutBuilder(
                      builder: (context, constraints) {
                        _syncOverflowState(
                          maxWidth: constraints.maxWidth,
                          style: summaryStyle,
                        );
                        return Text(
                          widget.entry.body,
                          maxLines: _expanded ? null : 2,
                          overflow: _expanded
                              ? TextOverflow.visible
                              : TextOverflow.ellipsis,
                          style: summaryStyle,
                        );
                      },
                    ),
                    if (parse != null && parse.hasAnySignal) ...[
                      const SizedBox(height: 8),
                      Wrap(
                        spacing: 8,
                        runSpacing: 6,
                        children: [
                          if (parse.personHandle != null)
                            _MiniTag('!${parse.personHandle}', widget.scheme),
                          if (parse.goalTag != null)
                            _MiniTag('#${parse.goalTag}', widget.scheme),
                          if (parse.deadlineHint != null)
                            _MiniTag(parse.deadlineHint!, widget.scheme),
                        ],
                      ),
                    ],
                  ],
                ),
              ),
              const SizedBox(width: 8),
              Column(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  if (showPersonalIndicator)
                    Tooltip(
                      message: 'Personal',
                      child: Icon(
                        Icons.visibility_off_outlined,
                        size: 16,
                        color: widget.scheme.onSurfaceVariant,
                      ),
                    )
                  else
                    Tooltip(
                      message: _timeLabel(widget.entry.createdAt),
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 7,
                          vertical: 2,
                        ),
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(999),
                          color: widget.scheme.surfaceContainerHigh
                              .withValues(alpha: 0.65),
                        ),
                        child: Text(
                          _timeLabel(widget.entry.createdAt),
                          style: widget.theme.textTheme.labelSmall?.copyWith(
                            color: widget.scheme.onSurfaceVariant,
                            fontFamily: 'monospace',
                          ),
                        ),
                      ),
                    ),
                  if (_canExpand) ...[
                    const SizedBox(height: 4),
                    IconButton(
                      tooltip: _expanded ? 'Collapse' : 'Expand',
                      visualDensity: VisualDensity.compact,
                      onPressed: () => setState(() => _expanded = !_expanded),
                      icon: Icon(
                        _expanded
                            ? Icons.keyboard_arrow_up
                            : Icons.keyboard_arrow_down,
                        color: widget.scheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ],
              ),
              ],
            ),
          ),
        ),
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

String _deadlineDistanceLabel(Expectation e) {
  final due = e.deadlineAt;
  if (due == null) {
    final label = e.deadlineLabel.trim();
    if (label.isEmpty || label.toUpperCase() == 'TBD') return '∞';
    return label;
  }
  final now = DateTime.now();
  final localDue = due.toLocal();
  final dueDate = DateTime(localDue.year, localDue.month, localDue.day);
  final nowDate = DateTime(now.year, now.month, now.day);
  final days = dueDate.difference(nowDate).inDays;
  if (days < 0) return '${days.abs()}d late';
  if (days == 0) return 'today';
  final weeks = days ~/ 7;
  final remDays = days % 7;
  if (weeks > 0 && remDays > 0) return '${weeks}w ${remDays}d';
  if (weeks > 0) return '${weeks}w';
  return '${days}d';
}

String _exactDateTimeLabel(DateTime dt) {
  final l = dt.toLocal();
  return '${l.year}-${l.month.toString().padLeft(2, '0')}-${l.day.toString().padLeft(2, '0')} '
      '${l.hour.toString().padLeft(2, '0')}:${l.minute.toString().padLeft(2, '0')}';
}

/// Calendar-day based, for "Created" in detail view.
String _createdRelativeLabel(DateTime createdAt) {
  final now = DateTime.now();
  final local = createdAt.toLocal();
  final today = DateTime(now.year, now.month, now.day);
  final day = DateTime(local.year, local.month, local.day);
  final diffDays = today.difference(day).inDays;
  if (diffDays < 0) return 'in ${diffDays.abs()} day${diffDays.abs() == 1 ? '' : 's'}';
  if (diffDays == 0) return 'today';
  if (diffDays == 1) return '1 day ago';
  if (diffDays < 7) return '$diffDays days ago';
  final weeks = diffDays ~/ 7;
  if (weeks == 1) return '1 week ago';
  return '$weeks weeks ago';
}

String _chatRelativeLabel(DateTime createdAt) {
  final now = DateTime.now();
  final local = createdAt.toLocal();
  final today = DateTime(now.year, now.month, now.day);
  final day = DateTime(local.year, local.month, local.day);
  final diffDays = today.difference(day).inDays;
  if (diffDays <= 0) return 'today';
  if (diffDays == 1) return '1 day ago';
  if (diffDays < 7) return '$diffDays days ago';
  final weeks = diffDays ~/ 7;
  if (weeks == 1) return '1 week ago';
  return '$weeks weeks ago';
}

String _deadlineTooltip(Expectation e) {
  if (e.deadlineAt != null) {
    return 'Due: ${_exactDateTimeLabel(e.deadlineAt!)}';
  }
  final label = e.deadlineLabel.trim();
  if (label.isEmpty || label.toUpperCase() == 'TBD') {
    return 'No deadline';
  }
  return 'Deadline: $label';
}

DateTime _finishedReferenceAt(Expectation e) {
  return (e.seenAt ?? e.publishedAt ?? e.createdAt).toUtc();
}

ExpectationType _typeFromDb(int value) {
  return switch (value) {
    1 => ExpectationType.topic,
    _ => ExpectationType.expectation,
  };
}

int _typeToDb(ExpectationType type) {
  return switch (type) {
    ExpectationType.expectation => 0,
    ExpectationType.topic => 1,
  };
}

ExpectationStatus _statusFromDb(int value) {
  return switch (value) {
    0 => ExpectationStatus.pending,
    1 => ExpectationStatus.accepted, // legacy: contracted
    2 => ExpectationStatus.finished, // legacy: breached/closed
    3 => ExpectationStatus.abandoned,
    _ => ExpectationStatus.pending,
  };
}

int _statusToDb(ExpectationStatus status) {
  return switch (status) {
    ExpectationStatus.pending => 0,
    ExpectationStatus.accepted => 1,
    ExpectationStatus.finished => 2,
    ExpectationStatus.abandoned => 3,
  };
}

ExpectationHealth _healthFromDb(int value) {
  return switch (value) {
    1 => ExpectationHealth.onTrack,
    2 => ExpectationHealth.atRisk,
    3 => ExpectationHealth.offTrack,
    _ => ExpectationHealth.unknown,
  };
}

int _healthToDb(ExpectationHealth health) {
  return switch (health) {
    ExpectationHealth.unknown => 0,
    ExpectationHealth.onTrack => 1,
    ExpectationHealth.atRisk => 2,
    ExpectationHealth.offTrack => 3,
  };
}

(String, Color) _healthMeta(ExpectationHealth health) {
  return switch (health) {
    ExpectationHealth.onTrack => ('On track', Colors.greenAccent.shade200),
    ExpectationHealth.atRisk => ('At risk', Colors.redAccent.shade100),
    ExpectationHealth.offTrack => ('Off track', Colors.orangeAccent.shade200),
    ExpectationHealth.unknown => ('Undefined', Colors.blueGrey.shade400),
  };
}

(String, Color) _statusMeta(ExpectationStatus status) {
  return switch (status) {
    ExpectationStatus.pending => ('Pending', Colors.orangeAccent.shade200),
    ExpectationStatus.accepted => ('Accepted', Colors.lightBlueAccent.shade200),
    ExpectationStatus.finished => ('Finished', Colors.lightGreenAccent.shade200),
    ExpectationStatus.abandoned => ('Abandoned', Colors.redAccent.shade100),
  };
}

IconData _seenIcon(Expectation e) {
  if (e.seenAt != null) return Icons.visibility_outlined;
  return Icons.visibility_off_outlined;
}

String _seenTooltip(Expectation e) {
  if (e.seenAt != null) {
    return 'Seen: ${_exactDateTimeLabel(e.seenAt!)}';
  }
  if (e.publishedAt != null) {
    return 'Published: ${_exactDateTimeLabel(e.publishedAt!)}';
  }
  return 'Personal';
}

bool _isDiscussionPoint(Expectation e) {
  return e.type == ExpectationType.topic;
}

final RegExp _inlineTagRegex = RegExp(r'#([a-zA-Z0-9._-]+)');

/// Inline `@handle` and `#hashtag` runs in private talking-point summaries (browse list).
final RegExp _privateTalkingInlineTokenRegex =
    RegExp(r'(@[a-zA-Z0-9._-]+|#[a-zA-Z0-9._-]+)');

List<String> _extractInlineTags(String input) {
  return _inlineTagRegex
      .allMatches(input)
      .map((m) => (m.group(1) ?? '').trim())
      .where((t) => t.isNotEmpty)
      .toSet()
      .toList();
}

TextSpan _richPrivateTalkingSummarySpan({
  required String summary,
  required TextStyle baseStyle,
  required Color mentionColor,
  required Color hashtagColor,
}) {
  final mentionStyle =
      baseStyle.copyWith(color: mentionColor, fontWeight: FontWeight.w600);
  final hashtagStyle =
      baseStyle.copyWith(color: hashtagColor, fontWeight: FontWeight.w600);
  final children = <InlineSpan>[];
  var start = 0;
  for (final m in _privateTalkingInlineTokenRegex.allMatches(summary)) {
    if (m.start > start) {
      children.add(TextSpan(
        text: summary.substring(start, m.start),
        style: baseStyle,
      ));
    }
    final token = m.group(0)!;
    children.add(TextSpan(
      text: token,
      style: token.startsWith('@') ? mentionStyle : hashtagStyle,
    ));
    start = m.end;
  }
  if (start < summary.length) {
    children.add(TextSpan(text: summary.substring(start), style: baseStyle));
  }
  if (children.isEmpty) {
    return TextSpan(text: summary, style: baseStyle);
  }
  return TextSpan(style: baseStyle, children: children);
}

class _ExpectationsOthersSection extends StatelessWidget {
  const _ExpectationsOthersSection({
    required this.title,
    required this.emptyText,
    required this.items,
    required this.peopleById,
    required this.theme,
    required this.scheme,
    required this.collapsed,
    required this.hasUnreadChat,
    this.onTagPressed,
    required this.onOpenDetails,
    this.onDeleteExpectation,
    this.infoTooltip,
    required this.onToggleCollapsed,
    this.personForItem,
    this.outboxDraftsListing = false,
    this.outboxPublishedListing = false,
    this.onPublishDraft,
    this.onArchiveDraft,
    this.inboxHoverListing = false,
    this.inboxHoverIncludeDelete = false,
    this.inboxReceiverPersonId,
    this.onArchiveInbox,
    this.talkingPointsBrowseListing = false,
    this.onArchiveTalkingPoint,
    this.onPublishTalkingPoint,
  });

  final String title;
  final String emptyText;
  final List<Expectation> items;
  final Map<String, Person> peopleById;
  final ThemeData theme;
  final ColorScheme scheme;
  final bool collapsed;
  final bool Function(Expectation expectation) hasUnreadChat;
  final ValueChanged<String>? onTagPressed;
  final void Function(Expectation expectation, Person? person) onOpenDetails;
  final Future<void> Function(Expectation expectation)? onDeleteExpectation;
  final String? infoTooltip;
  final VoidCallback onToggleCollapsed;
  /// When set (e.g. inbox), overrides [peopleById]\[[Expectation.personId]] for tiles.
  final Person? Function(Expectation e)? personForItem;
  /// Outbox drafts: deadline rail + hover Publish / Archive / Delete instead of permanent trash icon.
  final bool outboxDraftsListing;
  /// Outbox published (echo) active rows: hover Archive / Delete instead of permanent trash icon.
  final bool outboxPublishedListing;
  final Future<void> Function(Expectation expectation)? onPublishDraft;
  final Future<void> Function(Expectation expectation)? onArchiveDraft;
  /// Inbox Active/Finished: hover Archive (author or addressee); optional Delete on Personal only.
  final bool inboxHoverListing;
  final bool inboxHoverIncludeDelete;
  final String? inboxReceiverPersonId;
  final Future<void> Function(Expectation expectation)? onArchiveInbox;
  /// Tags pillar (Private / Public lists): hover Archive + owner Delete.
  final bool talkingPointsBrowseListing;
  final Future<void> Function(Expectation expectation)? onArchiveTalkingPoint;
  /// Private shadow talking points: hover Publish before Archive / Delete.
  final Future<void> Function(Expectation expectation)? onPublishTalkingPoint;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: Row(
                children: [
                  Flexible(
                    child: Text(
                      title,
                      style: theme.textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w700,
                        color: scheme.onSurface,
                      ),
                    ),
                  ),
                  if (infoTooltip != null) ...[
                    const SizedBox(width: 6),
                    Tooltip(
                      message: infoTooltip!,
                      child: Icon(
                        Icons.info_outline,
                        size: 16,
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ],
              ),
            ),
            IconButton(
              tooltip: collapsed ? 'Show $title' : 'Hide $title',
              onPressed: onToggleCollapsed,
              icon: Icon(
                collapsed
                    ? Icons.visibility_off_outlined
                    : Icons.visibility_outlined,
                size: 20,
                color: scheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
        if (!collapsed) ...[
          const SizedBox(height: 6),
          if (items.isEmpty)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Text(
                emptyText,
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
              ),
            )
          else
            ...items.map(
              (e) {
                final person =
                    personForItem?.call(e) ?? peopleById[e.personId];
                return _ExpectationOthersTile(
                  expectation: e,
                  person: person,
                  theme: theme,
                  scheme: scheme,
                  hasUnreadChat: hasUnreadChat(e),
                  onTagPressed: onTagPressed,
                  onOpenDetails: () => onOpenDetails(e, person),
                  onDelete: onDeleteExpectation == null
                      ? null
                      : () => onDeleteExpectation!(e),
                  outboxDraftsListing: outboxDraftsListing,
                  outboxPublishedListing: outboxPublishedListing,
                  onPublishDraft: onPublishDraft,
                  onArchiveDraft: onArchiveDraft,
                  inboxHoverListing: inboxHoverListing,
                  inboxHoverIncludeDelete: inboxHoverIncludeDelete,
                  inboxReceiverPersonId: inboxReceiverPersonId,
                  onArchiveInbox: onArchiveInbox,
                  talkingPointsBrowseListing: talkingPointsBrowseListing,
                  onArchiveTalkingPoint: onArchiveTalkingPoint,
                  onPublishTalkingPoint: onPublishTalkingPoint,
                );
              },
            ),
        ],
      ],
    );
  }
}

class _ExpectationsOthersFiltersBar extends StatelessWidget {
  const _ExpectationsOthersFiltersBar({
    required this.selectedStatus,
    required this.selectedTag,
    required this.selectedPersonId,
    required this.tags,
    required this.people,
    required this.onStatusChanged,
    required this.onTagChanged,
    required this.onPersonChanged,
    this.showStatus = true,
    this.showTag = true,
    this.showPerson = true,
    /// Wider Person field when Status/Tag are hidden (e.g. Private). Defaults to 220.
    this.personFieldWidth,
    /// Wider Tag field when Status/Person are hidden (e.g. Public). Defaults to 220.
    this.tagFieldWidth,
  });

  final ExpectationStatus? selectedStatus;
  final String? selectedTag;
  final String? selectedPersonId;
  final List<String> tags;
  final List<Person> people;
  final ValueChanged<ExpectationStatus?> onStatusChanged;
  final ValueChanged<String?> onTagChanged;
  final ValueChanged<String?> onPersonChanged;
  final bool showStatus;
  final bool showTag;
  final bool showPerson;
  final double? personFieldWidth;
  final double? tagFieldWidth;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    InputDecoration deco({
      required String label,
      required bool active,
    }) {
      final activeBorder = OutlineInputBorder(
        borderSide: BorderSide(
          color: scheme.primary.withValues(alpha: 0.85),
          width: 1.4,
        ),
      );
      return InputDecoration(
        labelText: label,
        isDense: true,
        contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        filled: true,
        fillColor: active
            ? scheme.primaryContainer.withValues(alpha: 0.18)
            : scheme.surfaceContainerHighest.withValues(alpha: 0.35),
        border: const OutlineInputBorder(),
        enabledBorder: active ? activeBorder : const OutlineInputBorder(),
        focusedBorder: active
            ? activeBorder
            : OutlineInputBorder(
                borderSide: BorderSide(
                  color: scheme.primary.withValues(alpha: 0.85),
                  width: 1.2,
                ),
              ),
      );
    }

    final tagW = showTag
        ? ((!showStatus && !showPerson)
            ? (tagFieldWidth ?? 220)
            : 145.0)
        : 0.0;

    final personW = showPerson
        ? (!showStatus && !showTag
            ? (personFieldWidth ?? 220)
            : 155.0)
        : 0.0;

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (showStatus) ...[
          SizedBox(
            width: 145,
            child: DropdownButtonFormField<ExpectationStatus?>(
              value: selectedStatus,
              isExpanded: true,
              style: theme.textTheme.bodySmall,
              decoration: deco(
                label: 'Status',
                active: selectedStatus != null,
              ),
              items: [
                const DropdownMenuItem<ExpectationStatus?>(
                  value: null,
                  child: Text('All statuses'),
                ),
                ...ExpectationStatus.values.map(
                  (s) => DropdownMenuItem<ExpectationStatus?>(
                    value: s,
                    child: Text(_statusMeta(s).$1),
                  ),
                ),
              ],
              onChanged: onStatusChanged,
            ),
          ),
          if (showTag || showPerson) const SizedBox(width: 8),
        ],
        if (showTag) ...[
          SizedBox(
            width: tagW,
            child: DropdownButtonFormField<String?>(
              value: selectedTag,
              isExpanded: true,
              style: theme.textTheme.bodySmall,
              decoration: deco(
                label: 'Tag',
                active: selectedTag != null,
              ),
              items: [
                const DropdownMenuItem<String?>(
                  value: null,
                  child: Text('All tags'),
                ),
                ...tags.map(
                  (t) => DropdownMenuItem<String?>(
                    value: t,
                    child: Text('#$t'),
                  ),
                ),
              ],
              onChanged: onTagChanged,
            ),
          ),
          if (showPerson) const SizedBox(width: 8),
        ],
        if (showPerson)
          SizedBox(
            width: personW,
            child: DropdownButtonFormField<String?>(
              value: selectedPersonId,
              isExpanded: true,
              style: theme.textTheme.bodySmall,
              decoration: deco(
                label: 'Person',
                active: selectedPersonId != null,
              ),
              items: [
                const DropdownMenuItem<String?>(
                  value: null,
                  child: Text('All people'),
                ),
                ...people.map(
                  (p) => DropdownMenuItem<String?>(
                    value: p.id,
                    child: Text(
                      p.displayName.trim().isNotEmpty
                          ? p.displayName.trim()
                          : '@${p.handle}',
                    ),
                  ),
                ),
              ],
              onChanged: onPersonChanged,
            ),
          ),
      ],
    );
  }
}

class _ExpectationOthersTile extends StatefulWidget {
  const _ExpectationOthersTile({
    required this.expectation,
    required this.person,
    required this.theme,
    required this.scheme,
    required this.hasUnreadChat,
    this.onTagPressed,
    required this.onOpenDetails,
    this.onDelete,
    this.outboxDraftsListing = false,
    this.outboxPublishedListing = false,
    this.onPublishDraft,
    this.onArchiveDraft,
    this.inboxHoverListing = false,
    this.inboxHoverIncludeDelete = false,
    this.inboxReceiverPersonId,
    this.onArchiveInbox,
    this.composerRecentListing = false,
    this.talkingPointsBrowseListing = false,
    this.onArchiveTalkingPoint,
    this.onPublishTalkingPoint,
  });

  final Expectation expectation;
  final Person? person;
  final ThemeData theme;
  final ColorScheme scheme;
  final bool hasUnreadChat;
  final ValueChanged<String>? onTagPressed;
  final VoidCallback onOpenDetails;
  final Future<void> Function()? onDelete;
  final bool outboxDraftsListing;
  final bool outboxPublishedListing;
  final Future<void> Function(Expectation expectation)? onPublishDraft;
  final Future<void> Function(Expectation expectation)? onArchiveDraft;
  final bool inboxHoverListing;
  final bool inboxHoverIncludeDelete;
  final String? inboxReceiverPersonId;
  final Future<void> Function(Expectation expectation)? onArchiveInbox;
  /// Add Expectation / Add talking point — Recent: hover Delete (no under-avatar trash).
  final bool composerRecentListing;
  /// Tags pillar talking-point lists: hover Archive (non-terminal) + Delete when author.
  final bool talkingPointsBrowseListing;
  final Future<void> Function(Expectation expectation)? onArchiveTalkingPoint;
  final Future<void> Function(Expectation expectation)? onPublishTalkingPoint;

  @override
  State<_ExpectationOthersTile> createState() => _ExpectationOthersTileState();
}

class _ExpectationOthersTileState extends State<_ExpectationOthersTile> {
  bool _expanded = false;
  bool _canExpand = false;
  bool _deleting = false;
  bool _publishing = false;
  bool _archiving = false;
  bool _hoverOutboxDraftRow = false;
  bool _hoverOutboxPublishedRow = false;
  bool _hoverInboxRow = false;
  bool _hoverComposerRecentRow = false;
  bool _hoverTalkingPointsBrowseRow = false;

  Color _rowBackgroundColor() {
    return _ledgerListingRowSurface(
      expectation: widget.expectation,
      brightness: widget.theme.brightness,
    );
  }

  void _syncOverflowState({
    required double maxWidth,
    required TextStyle? style,
    InlineSpan? summarySpan,
  }) {
    if (maxWidth <= 0) return;
    final span = summarySpan ??
        TextSpan(text: widget.expectation.summary, style: style);
    final tp = TextPainter(
      text: span,
      maxLines: 2,
      textDirection: Directionality.of(context),
    )..layout(maxWidth: maxWidth);
    final canExpand = tp.didExceedMaxLines;
    if (canExpand == _canExpand && (canExpand || !_expanded)) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      setState(() {
        _canExpand = canExpand;
        if (!canExpand) {
          _expanded = false;
        }
      });
    });
  }

  @override
  Widget build(BuildContext context) {
    final who = widget.person?.displayName ??
        (widget.expectation.personId.trim().isEmpty
            ? 'General'
            : widget.expectation.personId);
    final initials = who.trim().isNotEmpty ? who.trim()[0].toUpperCase() : '?';
    final summaryStyle = widget.theme.textTheme.bodyMedium?.copyWith(
      color: widget.scheme.onSurfaceVariant,
      height: 1.35,
    );
    final tags = _extractInlineTags(widget.expectation.summary);
    final (healthLabel, healthColor) = _healthMeta(widget.expectation.health);
    final isDiscussionPoint = _isDiscussionPoint(widget.expectation);
    final colorPrivateTalkingSummaryTokens = widget.talkingPointsBrowseListing &&
        isDiscussionPoint &&
        widget.expectation.visibility == ExpectationVisibility.shadow;
    final showWarningIndicator =
        !isDiscussionPoint &&
        (widget.expectation.health == ExpectationHealth.unknown ||
            widget.expectation.status == ExpectationStatus.pending);
    final draftDeadlineRail = widget.outboxDraftsListing &&
        !isDiscussionPoint &&
        widget.expectation.status != ExpectationStatus.finished;
    final showUpperDeadlinePill = widget.expectation.status !=
            ExpectationStatus.finished &&
        widget.expectation.deadlineAt != null &&
        !draftDeadlineRail;
    final currentUserId = Supabase.instance.client.auth.currentUser?.id;
    final isWriter = widget.expectation.writerUserId != null &&
        widget.expectation.writerUserId == currentUserId;
    final canDelete = widget.onDelete != null && isWriter;
    final rowBackground = _rowBackgroundColor();
    final showOutboxDraftHoverBar = widget.outboxDraftsListing &&
        _hoverOutboxDraftRow &&
        canDelete &&
        widget.onPublishDraft != null &&
        widget.onArchiveDraft != null;
    final showOutboxPublishedHoverBar = widget.outboxPublishedListing &&
        _hoverOutboxPublishedRow &&
        canDelete &&
        widget.onArchiveDraft != null &&
        widget.onDelete != null;
    final recvId = widget.inboxReceiverPersonId?.trim() ?? '';
    final canArchiveInbox = widget.inboxHoverListing &&
        widget.onArchiveInbox != null &&
        (isWriter ||
            (recvId.isNotEmpty &&
                widget.expectation.personId.trim() == recvId));
    final showInboxHoverBar = widget.inboxHoverListing &&
        _hoverInboxRow &&
        canArchiveInbox;
    final showInboxDeleteInHover = widget.inboxHoverIncludeDelete &&
        canDelete &&
        widget.onDelete != null;
    final showComposerRecentHoverBar = widget.composerRecentListing &&
        _hoverComposerRecentRow &&
        canDelete &&
        widget.onDelete != null;
    final isTerminalTpBrowse =
        widget.expectation.status == ExpectationStatus.finished ||
            widget.expectation.status == ExpectationStatus.abandoned;
    final canTpBrowseArchive = widget.talkingPointsBrowseListing &&
        widget.onArchiveTalkingPoint != null &&
        isWriter &&
        !isTerminalTpBrowse;
    final canTpBrowsePublish = widget.talkingPointsBrowseListing &&
        widget.onPublishTalkingPoint != null &&
        isWriter &&
        !isTerminalTpBrowse &&
        widget.expectation.visibility == ExpectationVisibility.shadow;
    final showTalkingPointsBrowseHoverBar = widget.talkingPointsBrowseListing &&
        _hoverTalkingPointsBrowseRow &&
        (canTpBrowsePublish || canTpBrowseArchive || canDelete);
    final card = Material(
      color: rowBackground,
      borderRadius: BorderRadius.circular(10),
      child: InkWell(
        borderRadius: BorderRadius.circular(10),
        onTap: widget.onOpenDetails,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 9),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
                  Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      CircleAvatar(
                        radius: 16,
                        backgroundColor: widget.scheme.primaryContainer.withValues(alpha: 0.6),
                        child: Text(
                          initials,
                          style: widget.theme.textTheme.labelMedium?.copyWith(
                            color: widget.scheme.onPrimaryContainer,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                      if (canDelete &&
                          !widget.outboxDraftsListing &&
                          !widget.outboxPublishedListing &&
                          !widget.inboxHoverListing &&
                          !widget.composerRecentListing &&
                          !widget.talkingPointsBrowseListing) ...[
                        const SizedBox(height: 22),
                        Tooltip(
                          message: 'Delete expectation',
                          child: IconButton(
                            visualDensity: VisualDensity.compact,
                            constraints: const BoxConstraints.tightFor(width: 26, height: 26),
                            padding: EdgeInsets.zero,
                            onPressed: _deleting
                                ? null
                                : () async {
                                    setState(() => _deleting = true);
                                    try {
                                      await widget.onDelete!.call();
                                    } finally {
                                      if (mounted) {
                                        setState(() => _deleting = false);
                                      }
                                    }
                                  },
                            icon: _deleting
                                ? SizedBox(
                                    width: 14,
                                    height: 14,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2,
                                      color: widget.scheme.onSurfaceVariant.withValues(alpha: 0.75),
                                    ),
                                  )
                                : Icon(
                                    Icons.delete_outline,
                                    size: 16,
                                    color: widget.scheme.onSurfaceVariant.withValues(alpha: 0.75),
                                  ),
                          ),
                        ),
                      ],
                    ],
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          who,
                          style: widget.theme.textTheme.titleSmall?.copyWith(
                            fontWeight: FontWeight.w700,
                            color: widget.scheme.onSurface,
                          ),
                        ),
                        const SizedBox(height: 6),
                        LayoutBuilder(
                          builder: (context, constraints) {
                            final richSummary = summaryStyle != null &&
                                    colorPrivateTalkingSummaryTokens
                                ? _richPrivateTalkingSummarySpan(
                                    summary: widget.expectation.summary,
                                    baseStyle: summaryStyle,
                                    mentionColor: LedgerListingAccents.topic,
                                    hashtagColor: widget.scheme.onSurfaceVariant,
                                  )
                                : null;
                            _syncOverflowState(
                              maxWidth: constraints.maxWidth,
                              style: summaryStyle,
                              summarySpan: richSummary,
                            );
                            if (richSummary != null) {
                              return Text.rich(
                                richSummary,
                                maxLines: _expanded ? null : 2,
                                overflow: _expanded
                                    ? TextOverflow.visible
                                    : TextOverflow.ellipsis,
                              );
                            }
                            return Text(
                              widget.expectation.summary,
                              maxLines: _expanded ? null : 2,
                              overflow: _expanded
                                  ? TextOverflow.visible
                                  : TextOverflow.ellipsis,
                              style: summaryStyle,
                            );
                          },
                        ),
                        if (tags.isNotEmpty) ...[
                          const SizedBox(height: 8),
                          Wrap(
                            spacing: 6,
                            runSpacing: 6,
                            children: [
                              for (final t in tags)
                                LedgerTagChip(
                                  tag: t,
                                  onPressed: widget.onTagPressed == null
                                      ? null
                                      : () => widget.onTagPressed!(t),
                                ),
                            ],
                          ),
                        ],
                      ],
                    ),
                  ),
                  const SizedBox(width: 8),
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.center,
                    children: [
                      if (showUpperDeadlinePill)
                        Tooltip(
                          message: _deadlineTooltip(widget.expectation),
                          child: Container(
                            padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                            decoration: BoxDecoration(
                              borderRadius: BorderRadius.circular(999),
                              color: widget.scheme.surfaceContainerHigh.withValues(alpha: 0.65),
                            ),
                            child: Text(
                              _deadlineDistanceLabel(widget.expectation),
                              style: widget.theme.textTheme.labelSmall?.copyWith(
                                color: widget.scheme.onSurfaceVariant,
                                fontFamily: 'monospace',
                              ),
                            ),
                          ),
                        ),
                      if (showUpperDeadlinePill) const SizedBox(height: 8),
                      Container(
                        constraints: draftDeadlineRail
                            ? const BoxConstraints(minWidth: 40, maxWidth: 96)
                            : const BoxConstraints.tightFor(width: 36),
                        padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 2),
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(10),
                          color: widget.scheme.surfaceContainerHighest.withValues(alpha: 0.22),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.center,
                          children: [
                            if (draftDeadlineRail)
                              Tooltip(
                                message: _deadlineTooltip(widget.expectation),
                                child: Padding(
                                  padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 2),
                                  child: Text(
                                    _deadlineDistanceLabel(widget.expectation),
                                    textAlign: TextAlign.center,
                                    maxLines: 2,
                                    style: widget.theme.textTheme.labelSmall?.copyWith(
                                      color: widget.scheme.onSurfaceVariant,
                                      fontFamily: 'monospace',
                                      height: 1.2,
                                    ),
                                  ),
                                ),
                              )
                            else if (!isDiscussionPoint &&
                                widget.expectation.status != ExpectationStatus.finished)
                              Tooltip(
                                message: showWarningIndicator
                                    ? (widget.expectation.health == ExpectationHealth.unknown
                                        ? 'Warning: Health is undefined'
                                        : 'Warning: Status is pending')
                                    : 'Health: $healthLabel',
                                child: showWarningIndicator
                                    ? Icon(
                                        Icons.warning_amber_rounded,
                                        size: 16,
                                        color: Colors.amberAccent.shade200,
                                      )
                                    : Container(
                                        width: 10,
                                        height: 10,
                                        decoration: BoxDecoration(
                                          color: healthColor,
                                          shape: BoxShape.circle,
                                        ),
                                      ),
                              ),
                            if (draftDeadlineRail ||
                                (!isDiscussionPoint &&
                                    widget.expectation.status != ExpectationStatus.finished))
                              const SizedBox(height: 8),
                            if (widget.expectation.visibility == ExpectationVisibility.shadow)
                              Tooltip(
                                message: _seenTooltip(widget.expectation),
                                child: Icon(
                                  Icons.visibility_off_outlined,
                                  size: 16,
                                  color: widget.scheme.onSurfaceVariant,
                                ),
                              ),
                            if (widget.hasUnreadChat) ...[
                              const SizedBox(height: 8),
                              Tooltip(
                                message: 'New chat activity',
                                child: Icon(
                                  Icons.mark_chat_unread_outlined,
                                  size: 16,
                                  color: widget.scheme.primary,
                                ),
                              ),
                            ],
                            if (widget.expectation.visibility == ExpectationVisibility.echo &&
                                widget.expectation.progress != null &&
                                !showWarningIndicator) ...[
                              const SizedBox(height: 8),
                              Tooltip(
                                message:
                                    'Progress: ${(widget.expectation.progress ?? 0).clamp(0, 100)}%',
                                child: SizedBox(
                                  width: 30,
                                  child: ClipRRect(
                                    borderRadius: BorderRadius.circular(999),
                                    child: LinearProgressIndicator(
                                      value: ((widget.expectation.progress ?? 0).clamp(0, 100)) /
                                          100.0,
                                      minHeight: 4,
                                      backgroundColor: widget.scheme.surfaceContainerHigh
                                          .withValues(alpha: 0.65),
                                    ),
                                  ),
                                ),
                              ),
                            ],
                            if (_canExpand) ...[
                              const SizedBox(height: 4),
                              IconButton(
                                tooltip: _expanded ? 'Collapse' : 'Expand',
                                visualDensity: VisualDensity.compact,
                                constraints: const BoxConstraints.tightFor(width: 24, height: 24),
                                padding: EdgeInsets.zero,
                                onPressed: () => setState(() => _expanded = !_expanded),
                                icon: Icon(
                                  _expanded ? Icons.keyboard_arrow_up : Icons.keyboard_arrow_down,
                                  size: 18,
                                  color: widget.scheme.onSurfaceVariant,
                                ),
                              ),
                            ],
                          ],
                        ),
                      ),
                    ],
                  ),
              ],
            ),
          ),
        ),
    );

    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      child: MouseRegion(
        onEnter: (_) {
          if (widget.outboxDraftsListing) {
            setState(() => _hoverOutboxDraftRow = true);
          }
          if (widget.outboxPublishedListing) {
            setState(() => _hoverOutboxPublishedRow = true);
          }
          if (widget.inboxHoverListing) {
            setState(() => _hoverInboxRow = true);
          }
          if (widget.composerRecentListing) {
            setState(() => _hoverComposerRecentRow = true);
          }
          if (widget.talkingPointsBrowseListing) {
            setState(() => _hoverTalkingPointsBrowseRow = true);
          }
        },
        onExit: (_) {
          if (widget.outboxDraftsListing) {
            setState(() => _hoverOutboxDraftRow = false);
          }
          if (widget.outboxPublishedListing) {
            setState(() => _hoverOutboxPublishedRow = false);
          }
          if (widget.inboxHoverListing) {
            setState(() => _hoverInboxRow = false);
          }
          if (widget.composerRecentListing) {
            setState(() => _hoverComposerRecentRow = false);
          }
          if (widget.talkingPointsBrowseListing) {
            setState(() => _hoverTalkingPointsBrowseRow = false);
          }
        },
        child: Stack(
          clipBehavior: Clip.none,
          children: [
            card,
            if (showOutboxDraftHoverBar)
              Positioned(
                top: 4,
                right: 8,
                child: Material(
                  elevation: 4,
                  borderRadius: BorderRadius.circular(10),
                  color: widget.scheme.surfaceContainerHigh.withValues(alpha: 0.97),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
                    child: Wrap(
                      spacing: 0,
                      runSpacing: 0,
                      alignment: WrapAlignment.end,
                      children: [
                        TextButton(
                          onPressed: (_publishing || _archiving || _deleting)
                              ? null
                              : () async {
                                  setState(() => _publishing = true);
                                  try {
                                    await widget.onPublishDraft!(widget.expectation);
                                  } finally {
                                    if (mounted) {
                                      setState(() => _publishing = false);
                                    }
                                  }
                                },
                          child: _publishing
                              ? SizedBox(
                                  width: 18,
                                  height: 18,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                    color: widget.scheme.primary,
                                  ),
                                )
                              : Text(
                                  'Publish',
                                  style: widget.theme.textTheme.labelLarge?.copyWith(
                                    fontWeight: FontWeight.w700,
                                    color: widget.scheme.primary,
                                  ),
                                ),
                        ),
                        TextButton(
                          onPressed: (_publishing || _archiving || _deleting)
                              ? null
                              : () async {
                                  setState(() => _archiving = true);
                                  try {
                                    await widget.onArchiveDraft!(widget.expectation);
                                  } finally {
                                    if (mounted) {
                                      setState(() => _archiving = false);
                                    }
                                  }
                                },
                          child: _archiving
                              ? SizedBox(
                                  width: 18,
                                  height: 18,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                    color: widget.scheme.onSurfaceVariant,
                                  ),
                                )
                              : Text(
                                  'Archive',
                                  style: widget.theme.textTheme.labelLarge?.copyWith(
                                    fontWeight: FontWeight.w700,
                                    color: widget.scheme.onSurfaceVariant,
                                  ),
                                ),
                        ),
                        TextButton(
                          onPressed: (_publishing || _archiving || _deleting)
                              ? null
                              : () async {
                                  setState(() => _deleting = true);
                                  try {
                                    await widget.onDelete!.call();
                                  } finally {
                                    if (mounted) {
                                      setState(() => _deleting = false);
                                    }
                                  }
                                },
                          child: _deleting
                              ? SizedBox(
                                  width: 18,
                                  height: 18,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                    color: widget.scheme.error,
                                  ),
                                )
                              : Text(
                                  'Delete',
                                  style: widget.theme.textTheme.labelLarge?.copyWith(
                                    fontWeight: FontWeight.w600,
                                    color: widget.scheme.error,
                                  ),
                                ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            if (showOutboxPublishedHoverBar)
              Positioned(
                top: 4,
                right: 8,
                child: Material(
                  elevation: 4,
                  borderRadius: BorderRadius.circular(10),
                  color: widget.scheme.surfaceContainerHigh.withValues(alpha: 0.97),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
                    child: Wrap(
                      spacing: 0,
                      runSpacing: 0,
                      alignment: WrapAlignment.end,
                      children: [
                        TextButton(
                          onPressed: (_archiving || _deleting)
                              ? null
                              : () async {
                                  setState(() => _archiving = true);
                                  try {
                                    await widget.onArchiveDraft!(widget.expectation);
                                  } finally {
                                    if (mounted) {
                                      setState(() => _archiving = false);
                                    }
                                  }
                                },
                          child: _archiving
                              ? SizedBox(
                                  width: 18,
                                  height: 18,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                    color: widget.scheme.onSurfaceVariant,
                                  ),
                                )
                              : Text(
                                  'Archive',
                                  style: widget.theme.textTheme.labelLarge?.copyWith(
                                    fontWeight: FontWeight.w700,
                                    color: widget.scheme.onSurfaceVariant,
                                  ),
                                ),
                        ),
                        TextButton(
                          onPressed: (_archiving || _deleting)
                              ? null
                              : () async {
                                  setState(() => _deleting = true);
                                  try {
                                    await widget.onDelete!.call();
                                  } finally {
                                    if (mounted) {
                                      setState(() => _deleting = false);
                                    }
                                  }
                                },
                          child: _deleting
                              ? SizedBox(
                                  width: 18,
                                  height: 18,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                    color: widget.scheme.error,
                                  ),
                                )
                              : Text(
                                  'Delete',
                                  style: widget.theme.textTheme.labelLarge?.copyWith(
                                    fontWeight: FontWeight.w600,
                                    color: widget.scheme.error,
                                  ),
                                ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            if (showInboxHoverBar)
              Positioned(
                top: 4,
                right: 8,
                child: Material(
                  elevation: 4,
                  borderRadius: BorderRadius.circular(10),
                  color: widget.scheme.surfaceContainerHigh.withValues(alpha: 0.97),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
                    child: Wrap(
                      spacing: 0,
                      runSpacing: 0,
                      alignment: WrapAlignment.end,
                      children: [
                        TextButton(
                          onPressed: (_archiving || _deleting)
                              ? null
                              : () async {
                                  setState(() => _archiving = true);
                                  try {
                                    await widget.onArchiveInbox!(widget.expectation);
                                  } finally {
                                    if (mounted) {
                                      setState(() => _archiving = false);
                                    }
                                  }
                                },
                          child: _archiving
                              ? SizedBox(
                                  width: 18,
                                  height: 18,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                    color: widget.scheme.onSurfaceVariant,
                                  ),
                                )
                              : Text(
                                  'Archive',
                                  style: widget.theme.textTheme.labelLarge?.copyWith(
                                    fontWeight: FontWeight.w700,
                                    color: widget.scheme.onSurfaceVariant,
                                  ),
                                ),
                        ),
                        if (showInboxDeleteInHover)
                          TextButton(
                            onPressed: (_archiving || _deleting)
                                ? null
                                : () async {
                                    setState(() => _deleting = true);
                                    try {
                                      await widget.onDelete!.call();
                                    } finally {
                                      if (mounted) {
                                        setState(() => _deleting = false);
                                      }
                                    }
                                  },
                            child: _deleting
                                ? SizedBox(
                                    width: 18,
                                    height: 18,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2,
                                      color: widget.scheme.error,
                                    ),
                                  )
                                : Text(
                                    'Delete',
                                    style: widget.theme.textTheme.labelLarge?.copyWith(
                                      fontWeight: FontWeight.w600,
                                      color: widget.scheme.error,
                                    ),
                                  ),
                          ),
                      ],
                    ),
                  ),
                ),
              ),
            if (showComposerRecentHoverBar)
              Positioned(
                top: 4,
                right: 8,
                child: Material(
                  elevation: 4,
                  borderRadius: BorderRadius.circular(10),
                  color: widget.scheme.surfaceContainerHigh.withValues(alpha: 0.97),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
                    child: TextButton(
                      onPressed: _deleting
                          ? null
                          : () async {
                              setState(() => _deleting = true);
                              try {
                                await widget.onDelete!.call();
                              } finally {
                                if (mounted) {
                                  setState(() => _deleting = false);
                                }
                              }
                            },
                      child: _deleting
                          ? SizedBox(
                              width: 18,
                              height: 18,
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                color: widget.scheme.error,
                              ),
                            )
                          : Text(
                              'Delete',
                              style: widget.theme.textTheme.labelLarge?.copyWith(
                                fontWeight: FontWeight.w600,
                                color: widget.scheme.error,
                              ),
                            ),
                    ),
                  ),
                ),
              ),
            if (showTalkingPointsBrowseHoverBar)
              Positioned(
                top: 4,
                right: 8,
                child: Material(
                  elevation: 4,
                  borderRadius: BorderRadius.circular(10),
                  color: widget.scheme.surfaceContainerHigh.withValues(alpha: 0.97),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
                    child: Wrap(
                      spacing: 0,
                      runSpacing: 0,
                      alignment: WrapAlignment.end,
                      children: [
                        if (canTpBrowsePublish)
                          TextButton(
                            onPressed: (_publishing || _archiving || _deleting)
                                ? null
                                : () async {
                                    setState(() => _publishing = true);
                                    try {
                                      await widget.onPublishTalkingPoint!(
                                        widget.expectation,
                                      );
                                    } finally {
                                      if (mounted) {
                                        setState(() => _publishing = false);
                                      }
                                    }
                                  },
                            child: _publishing
                                ? SizedBox(
                                    width: 18,
                                    height: 18,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2,
                                      color: widget.scheme.primary,
                                    ),
                                  )
                                : Text(
                                    'Publish',
                                    style: widget.theme.textTheme.labelLarge?.copyWith(
                                      fontWeight: FontWeight.w700,
                                      color: widget.scheme.primary,
                                    ),
                                  ),
                          ),
                        if (canTpBrowseArchive)
                          TextButton(
                            onPressed: (_publishing || _archiving || _deleting)
                                ? null
                                : () async {
                                    setState(() => _archiving = true);
                                    try {
                                      await widget.onArchiveTalkingPoint!(
                                        widget.expectation,
                                      );
                                    } finally {
                                      if (mounted) {
                                        setState(() => _archiving = false);
                                      }
                                    }
                                  },
                            child: _archiving
                                ? SizedBox(
                                    width: 18,
                                    height: 18,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2,
                                      color: widget.scheme.onSurfaceVariant,
                                    ),
                                  )
                                : Text(
                                    'Archive',
                                    style: widget.theme.textTheme.labelLarge?.copyWith(
                                      fontWeight: FontWeight.w700,
                                      color: widget.scheme.onSurfaceVariant,
                                    ),
                                  ),
                          ),
                        if (canDelete)
                          TextButton(
                            onPressed: (_publishing || _archiving || _deleting)
                                ? null
                                : () async {
                                    setState(() => _deleting = true);
                                    try {
                                      await widget.onDelete!.call();
                                    } finally {
                                      if (mounted) {
                                        setState(() => _deleting = false);
                                      }
                                    }
                                  },
                            child: _deleting
                                ? SizedBox(
                                    width: 18,
                                    height: 18,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2,
                                      color: widget.scheme.error,
                                    ),
                                  )
                                : Text(
                                    'Delete',
                                    style: widget.theme.textTheme.labelLarge?.copyWith(
                                      fontWeight: FontWeight.w600,
                                      color: widget.scheme.error,
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
}

String _listingStateKey(Expectation e) {
  if (e.status == ExpectationStatus.finished) return 'finished';
  if (e.status == ExpectationStatus.abandoned) return 'abandoned';
  if (e.visibility == ExpectationVisibility.echo) return 'published';
  return 'unpublished';
}

Color _ledgerListingRowSurface({
  required Expectation expectation,
  required Brightness brightness,
}) {
  final state = _listingStateKey(expectation);
  final accent = expectation.type == ExpectationType.topic
      ? LedgerListingAccents.topic
      : LedgerListingAccents.expectation;
  final base = brightness == Brightness.dark
      ? const Color(0xFF13151A)
      : const Color(0xFFF4F5F7);
  final mix = switch (state) {
    'unpublished' => 0.12,
    'published' => 0.22,
    'finished' => 0.32,
    'abandoned' => 0.11,
    _ => 0.12,
  };
  var color = Color.lerp(base, accent, mix)!;
  if (state == 'abandoned') {
    color = Color.lerp(
      color,
      const Color(0xFFE85D5D),
      brightness == Brightness.dark ? 0.14 : 0.11,
    )!;
  } else if (state == 'finished') {
    color = Color.lerp(
      color,
      const Color(0xFF52B788),
      brightness == Brightness.dark ? 0.11 : 0.09,
    )!;
  }
  return color;
}

class _PendingAttachment {
  const _PendingAttachment({
    required this.fileName,
    required this.fileUrl,
  });

  final String fileName;
  final String fileUrl;
}

class _ExpectationMessageVm {
  const _ExpectationMessageVm({
    required this.id,
    required this.senderPersonId,
    required this.senderLabel,
    required this.messageText,
    required this.createdAt,
    required this.attachments,
  });

  final String id;
  final String senderPersonId;
  final String senderLabel;
  final String messageText;
  final DateTime createdAt;
  final List<_PendingAttachment> attachments;
}

class _ExpectationDetailsPanel extends StatefulWidget {
  const _ExpectationDetailsPanel({
    required this.expectation,
    required this.person,
    required this.canEdit,
    this.onInvitePerson,
  });

  final Expectation expectation;
  final Person? person;
  final bool canEdit;
  final Future<void> Function(String? personId)? onInvitePerson;

  @override
  State<_ExpectationDetailsPanel> createState() => _ExpectationDetailsPanelState();
}

class _ExpectationDetailsPanelState extends State<_ExpectationDetailsPanel> {
  static final RegExp _tagsRegex = RegExp(r'#([a-zA-Z0-9._-]+)');
  static const int _messageTypeChat = 0;
  static const int _messageTypeChangeLog = 1;
  late final TextEditingController _descriptionController;
  late final TextEditingController _messageController;
  late ExpectationStatus _status;
  late ExpectationHealth _health;
  DateTime? _deadlineAt;
  late String _deadlineLabel;
  late ExpectationVisibility _visibility;
  int? _progress;
  bool _editingDescription = false;
  bool _saving = false;
  bool _deleting = false;
  bool _inviting = false;
  bool _messagesLoading = true;
  bool _sendingMessage = false;
  bool _uploadingAttachment = false;
  String? _messagesError;
  String? _myPersonId;
  String? _companyId;
  String? _myActorLabel;
  String _senderLabel = 'Unknown sender';
  final List<_ExpectationMessageVm> _messages = [];
  final List<_PendingAttachment> _pendingAttachments = [];
  bool _hasSavedChanges = false;
  late String _savedSummary;
  late ExpectationStatus _savedStatus;
  late ExpectationHealth _savedHealth;
  DateTime? _savedDeadlineAt;
  late String _savedDeadlineLabel;
  late ExpectationVisibility _savedVisibility;
  int? _savedProgress;

  @override
  void initState() {
    super.initState();
    _descriptionController = TextEditingController(text: widget.expectation.summary);
    _descriptionController.addListener(_onDescriptionChanged);
    _messageController = TextEditingController();
    _status = widget.expectation.status;
    _health = widget.expectation.health;
    _deadlineAt = widget.expectation.deadlineAt;
    _deadlineLabel = widget.expectation.deadlineLabel;
    _visibility = widget.expectation.visibility;
    _progress = widget.expectation.progress;
    _savedSummary = widget.expectation.summary.trim();
    _savedStatus = widget.expectation.status;
    _savedHealth = widget.expectation.health;
    _savedDeadlineAt = widget.expectation.deadlineAt;
    _savedDeadlineLabel = widget.expectation.deadlineLabel.trim();
    _savedVisibility = widget.expectation.visibility;
    _savedProgress = widget.expectation.progress;
    _senderLabel = _initialSenderLabel();
    _loadSenderLabel();
    _loadConversation();
  }

  void _onDescriptionChanged() {
    if (!mounted) return;
    setState(() {});
  }

  @override
  void dispose() {
    _descriptionController.removeListener(_onDescriptionChanged);
    _descriptionController.dispose();
    _messageController.dispose();
    super.dispose();
  }

  bool get _dirty =>
      _descriptionController.text.trim() != _savedSummary ||
      _status != _savedStatus ||
      _health != _savedHealth ||
      _deadlineAt != _savedDeadlineAt ||
      _deadlineLabel.trim() != _savedDeadlineLabel ||
      _visibility != _savedVisibility ||
      _progress != _savedProgress;

  /// Private @-person talking point (never published to tag feed).
  bool get _isColleagueTalkingPoint =>
      widget.expectation.type == ExpectationType.topic &&
      widget.expectation.personId.trim().isNotEmpty;

  Future<bool> _ensureActorContext() async {
    if (_myPersonId != null && _companyId != null) return true;
    final client = Supabase.instance.client;
    final user = client.auth.currentUser;
    if (user == null) return false;
    final meRows = await client
        .from('people')
        .select('id,company_id,display_name,handle')
        .eq('auth_user_id', user.id)
        .limit(1);
    if ((meRows as List).isEmpty) return false;
    final me = meRows.first as Map;
    _myPersonId = me['id'] as String;
    _companyId = me['company_id'] as String;
    final display = ((me['display_name'] as String?) ?? '').trim();
    final handle = ((me['handle'] as String?) ?? '').trim();
    _myActorLabel = display.isNotEmpty
        ? display
        : (handle.isNotEmpty ? '@$handle' : null);
    return true;
  }

  Future<String> _insertExpectationMessage({
    required String text,
    required int type,
  }) async {
    final client = Supabase.instance.client;
    try {
      final inserted = await client
          .from('expectation_messages')
          .insert({
            'company_id': _companyId,
            'expectation_id': widget.expectation.id,
            'sender_person_id': _myPersonId,
            'type': type,
            'message_text': text,
          })
          .select('id')
          .single();
      return inserted['id'] as String;
    } on PostgrestException catch (e) {
      final msg = e.message.toLowerCase();
      final typeColumnIssue = msg.contains('column') && msg.contains('type');
      if (!typeColumnIssue) rethrow;
      final inserted = await client
          .from('expectation_messages')
          .insert({
            'company_id': _companyId,
            'expectation_id': widget.expectation.id,
            'sender_person_id': _myPersonId,
            'message_text': text,
          })
          .select('id')
          .single();
      return inserted['id'] as String;
    }
  }

  Future<void> _touchChatActivity() async {
    final client = Supabase.instance.client;
    final nowIso = DateTime.now().toUtc().toIso8601String();
    final currentUserId = client.auth.currentUser?.id;
    final isWriter = currentUserId != null &&
        widget.expectation.writerUserId != null &&
        currentUserId == widget.expectation.writerUserId;
    await client
        .from('expectations')
        .update({
          if (isWriter) 'last_chatted_sender_at': nowIso,
          if (!isWriter) 'last_chatted_receiver_at': nowIso,
        })
        .eq('id', widget.expectation.id);
  }

  String? _buildCriticalChangeLogText() {
    final changes = <String>[];
    if (_status != _savedStatus) {
      changes.add('status to ${_statusMeta(_status).$1}');
    }
    if (_health != _savedHealth) {
      changes.add('health to ${_healthMeta(_health).$1}');
    }
    if (_deadlineAt != _savedDeadlineAt ||
        _deadlineLabel.trim() != _savedDeadlineLabel) {
      final deadlineText = _deadlineAt == null
          ? (_deadlineLabel.trim().isEmpty ? 'no deadline' : _deadlineLabel.trim())
          : _dateOnlyLabel(_deadlineAt!);
      changes.add('deadline to $deadlineText');
    }
    if (changes.isEmpty) return null;
    return 'Update: ${changes.join(', ')}.';
  }

  String _dateOnlyLabel(DateTime dt) {
    final local = dt.toLocal();
    return '${local.year}-${local.month.toString().padLeft(2, '0')}-${local.day.toString().padLeft(2, '0')}';
  }

  String _initialSenderLabel() {
    final writer = widget.expectation.writerUserId?.trim();
    if (writer == null || writer.isEmpty) return 'Unknown sender';
    return writer;
  }

  Future<void> _loadSenderLabel() async {
    final writer = widget.expectation.writerUserId?.trim();
    if (writer == null || writer.isEmpty) return;
    try {
      final rows = await Supabase.instance.client
          .from('people')
          .select('display_name,handle')
          .eq('auth_user_id', writer)
          .limit(1);
      if (!mounted || (rows as List).isEmpty) return;
      final row = rows.first as Map;
      final display = ((row['display_name'] as String?) ?? '').trim();
      final handle = ((row['handle'] as String?) ?? '').trim();
      final label = display.isNotEmpty
          ? display
          : (handle.isNotEmpty ? '@$handle' : 'Unknown sender');
      setState(() => _senderLabel = label);
    } catch (_) {
      // Keep fallback sender label.
    }
  }

  Future<void> _editProgress() async {
    if (!widget.canEdit) return;
    final start = (_progress ?? 0).clamp(0, 100);
    var working = start.toDouble();
    final picked = await showDialog<int>(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: const Text('Progress'),
          content: StatefulBuilder(
            builder: (context, setLocalState) {
              return Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('${working.round()}%'),
                  const SizedBox(height: 8),
                  Slider(
                    value: working,
                    min: 0,
                    max: 100,
                    divisions: 20,
                    label: '${working.round()}%',
                    onChanged: (v) => setLocalState(() => working = v),
                  ),
                ],
              );
            },
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(context).pop(working.round()),
              child: const Text('Set'),
            ),
          ],
        );
      },
    );
    if (picked == null) return;
    setState(() => _progress = picked.clamp(0, 100));
  }

  Future<void> _pickDeadline() async {
    final initial = _deadlineAt ?? DateTime.now().add(const Duration(days: 7));
    final picked = await showDatePicker(
      context: context,
      initialDate: initial,
      firstDate: DateTime(2020),
      lastDate: DateTime(2100),
    );
    if (picked == null) return;
    setState(() {
      _deadlineAt = DateTime(picked.year, picked.month, picked.day).toUtc();
      _deadlineLabel =
          '${picked.year}-${picked.month.toString().padLeft(2, '0')}-${picked.day.toString().padLeft(2, '0')}';
    });
  }

  Future<void> _archiveColleagueTalkingPoint() async {
    if (_saving || !widget.canEdit) return;
    setState(() => _status = ExpectationStatus.finished);
    await _save();
  }

  Future<void> _save({bool publish = false}) async {
    if (_saving) return;
    setState(() => _saving = true);
    final client = Supabase.instance.client;
    await _ensureActorContext();
    final isReceiverActor = _myPersonId != null && _myPersonId == widget.expectation.personId;
    // If receiver saves while still pending, auto-promote to accepted.
    if (isReceiverActor && _status == ExpectationStatus.pending) {
      _status = ExpectationStatus.accepted;
    }
    final summary = _descriptionController.text.trim();
    final nextVisibility = publish ? ExpectationVisibility.echo : _visibility;
    final nextFinishedAt = _status == ExpectationStatus.finished
        ? (widget.expectation.finishedAt ?? DateTime.now().toUtc())
        : null;
    final responsibleFieldsChanged = _status != _savedStatus ||
        _health != _savedHealth ||
        _deadlineAt != _savedDeadlineAt ||
        _deadlineLabel.trim() != _savedDeadlineLabel ||
        _progress != _savedProgress;
    final updates = <String, dynamic>{
      'summary': summary,
      'title': summary.length > 80 ? '${summary.substring(0, 80)}...' : summary,
      'expectation_status': _statusToDb(_status),
      'expectation_health': _healthToDb(_health),
      'deadline_label': _deadlineLabel.trim().isEmpty ? 'TBD' : _deadlineLabel.trim(),
      'deadline_at': _deadlineAt?.toIso8601String(),
      'finished_at': nextFinishedAt?.toIso8601String(),
      if (responsibleFieldsChanged)
        'responsible_updated_at': DateTime.now().toUtc().toIso8601String(),
      'progress': _progress,
      'expectation_visibility': nextVisibility.index,
    };
    if (publish && widget.expectation.publishedAt == null) {
      updates['published_at'] = DateTime.now().toUtc().toIso8601String();
    }
    final changeLogText = _buildCriticalChangeLogText();
    try {
      await client.from('expectations').update(updates).eq('id', widget.expectation.id);
      if (changeLogText != null) {
        var actorReady = await _ensureActorContext();
        if (!actorReady) {
          // Fallback path: conversation load also initializes actor context.
          await _loadConversation();
          actorReady = _myPersonId != null && _companyId != null;
        }
        if (actorReady) {
          await _insertExpectationMessage(
            text: changeLogText,
            type: _messageTypeChangeLog,
          );
          await _touchChatActivity();
        }
      }
      if (!mounted) return;
      setState(() {
        _saving = false;
        _hasSavedChanges = true;
        _editingDescription = false;
        _visibility = nextVisibility;
        _savedSummary = summary;
        _savedStatus = _status;
        _savedHealth = _health;
        _savedDeadlineAt = _deadlineAt;
        _savedDeadlineLabel =
            _deadlineLabel.trim().isEmpty ? 'TBD' : _deadlineLabel.trim();
        _savedVisibility = _visibility;
        _savedProgress = _progress;
      });
      await _loadConversation();
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Expectation saved.')),
      );
    } catch (_) {
      if (!mounted) return;
      setState(() => _saving = false);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Failed to save expectation changes.')),
      );
    }
  }

  Future<void> _deleteExpectation() async {
    if (_saving || _deleting) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: const Text('Delete expectation?'),
          content: const Text(
            'This will permanently remove the expectation and its conversation.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(context).pop(true),
              style: FilledButton.styleFrom(
                backgroundColor: Theme.of(context).colorScheme.error,
                foregroundColor: Theme.of(context).colorScheme.onError,
              ),
              child: const Text('Delete'),
            ),
          ],
        );
      },
    );
    if (confirmed != true) return;
    setState(() => _deleting = true);
    try {
      await Supabase.instance.client
          .from('expectations')
          .delete()
          .eq('id', widget.expectation.id);
      if (!mounted) return;
      Navigator.of(context).pop(true);
    } catch (_) {
      if (!mounted) return;
      setState(() => _deleting = false);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Failed to delete expectation.')),
      );
    }
  }

  Future<void> _inviteReceiver() async {
    final receiver = widget.person;
    if (receiver == null || _inviting) return;
    if (widget.onInvitePerson == null) return;
    setState(() => _inviting = true);
    try {
      await widget.onInvitePerson!(receiver.id);
      if (!mounted) return;
      setState(() => _inviting = false);
    } catch (_) {
      if (!mounted) return;
      setState(() => _inviting = false);
    }
  }

  Future<void> _loadConversation() async {
    final client = Supabase.instance.client;
    final user = client.auth.currentUser;
    if (user == null) {
      if (!mounted) return;
      setState(() {
        _messagesLoading = false;
        _messagesError = 'No authenticated user.';
      });
      return;
    }
    try {
      final meRows = await client
          .from('people')
          .select('id,company_id,display_name,handle')
          .eq('auth_user_id', user.id)
          .limit(1);
      if ((meRows as List).isEmpty) {
        if (!mounted) return;
        setState(() {
          _messagesLoading = false;
          _messagesError = 'No linked person/company found for this user.';
        });
        return;
      }
      _myPersonId = meRows.first['id'] as String;
      _companyId = meRows.first['company_id'] as String;
      final meDisplay = ((meRows.first['display_name'] as String?) ?? '').trim();
      final meHandle = ((meRows.first['handle'] as String?) ?? '').trim();
      _myActorLabel = meDisplay.isNotEmpty
          ? meDisplay
          : (meHandle.isNotEmpty ? '@$meHandle' : null);

      final rows = await client
          .from('expectation_messages')
          .select(
            'id,sender_person_id,message_text,created_at,'
            'people!inner(display_name,handle),'
            'expectation_message_attachments(file_name,file_url)',
          )
          .eq('expectation_id', widget.expectation.id)
          .order('created_at', ascending: true);

      final mapped = (rows as List).map((r) {
        final personObj = r['people'];
        final senderLabel = personObj is Map
            ? ((personObj['display_name'] as String?)?.trim().isNotEmpty == true
                ? (personObj['display_name'] as String).trim()
                : '@${(personObj['handle'] as String?) ?? 'unknown'}')
            : (r['sender_person_id'] as String);
        final attachmentRows = (r['expectation_message_attachments'] as List?) ?? const [];
        final attachments = attachmentRows
            .map(
              (a) => _PendingAttachment(
                fileName: ((a as Map)['file_name'] as String?)?.trim().isNotEmpty == true
                    ? (a['file_name'] as String).trim()
                    : 'Attachment',
                fileUrl: ((a['file_url'] as String?) ?? '').trim(),
              ),
            )
            .where((a) => a.fileUrl.isNotEmpty)
            .toList();
        return _ExpectationMessageVm(
          id: r['id'] as String,
          senderPersonId: r['sender_person_id'] as String,
          senderLabel: senderLabel,
          messageText: ((r['message_text'] as String?) ?? '').trim(),
          createdAt: DateTime.tryParse((r['created_at'] as String?) ?? '') ??
              DateTime.now().toUtc(),
          attachments: attachments,
        );
      }).toList();

      if (!mounted) return;
      setState(() {
        _messages
          ..clear()
          ..addAll(mapped);
        _messagesLoading = false;
        _messagesError = null;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _messagesLoading = false;
        _messagesError = 'Failed to load conversation: $e';
      });
    }
  }

  Future<void> _pickAndUploadAttachment() async {
    if (_uploadingAttachment || _sendingMessage) return;
    final result = await FilePicker.platform.pickFiles(allowMultiple: false);
    if (result == null || result.files.isEmpty) return;
    final picked = result.files.first;
    final path = picked.path;
    if (path == null || path.isEmpty) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Could not access selected file path.')),
      );
      return;
    }
    if (_companyId == null) {
      await _loadConversation();
      if (_companyId == null) return;
    }
    setState(() => _uploadingAttachment = true);
    final client = Supabase.instance.client;
    final file = File(path);
    final fileName = picked.name.trim().isEmpty ? 'attachment' : picked.name.trim();
    final safeName = fileName.replaceAll(RegExp(r'[^a-zA-Z0-9._-]'), '_');
    final objectPath =
        '${_companyId!}/expectations/${widget.expectation.id}/${DateTime.now().millisecondsSinceEpoch}_$safeName';
    try {
      await client.storage.from('storage').upload(
            objectPath,
            file,
            fileOptions: const FileOptions(upsert: false),
          );
      final publicUrl = client.storage.from('storage').getPublicUrl(objectPath);
      if (!mounted) return;
      setState(() {
        _uploadingAttachment = false;
        _pendingAttachments.add(
          _PendingAttachment(fileName: fileName, fileUrl: publicUrl),
        );
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _uploadingAttachment = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Failed to upload attachment: $e')),
      );
    }
  }

  Future<void> _sendMessage() async {
    if (_sendingMessage) return;
    final text = _messageController.text.trim();
    if (text.isEmpty && _pendingAttachments.isEmpty) return;
    if (_myPersonId == null || _companyId == null) {
      final ready = await _ensureActorContext();
      if (!ready) return;
    }
    setState(() => _sendingMessage = true);
    final client = Supabase.instance.client;
    try {
      final messageId = await _insertExpectationMessage(
        text: text.isEmpty ? '[Attachment]' : text,
        type: _messageTypeChat,
      );
      for (final a in _pendingAttachments) {
        await client.from('expectation_message_attachments').insert({
          'company_id': _companyId,
          'expectation_message_id': messageId,
          'file_name': a.fileName,
          'file_url': a.fileUrl,
        });
      }
      await _touchChatActivity();
      if (!mounted) return;
      setState(() {
        _sendingMessage = false;
        _messageController.clear();
        _pendingAttachments.clear();
      });
      await _loadConversation();
    } on PostgrestException catch (e) {
      if (!mounted) return;
      setState(() => _sendingMessage = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Failed to send message: ${e.message}')),
      );
    } catch (e) {
      if (!mounted) return;
      setState(() => _sendingMessage = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Failed to send message: $e')),
      );
    }
  }

  Future<void> _openAttachmentUrl(String rawUrl) async {
    final client = Supabase.instance.client;
    Uri? uri = Uri.tryParse(rawUrl);
    // If we stored/received a public storage URL, prefer a signed URL at click time
    // to avoid bucket visibility mismatches.
    if (uri != null) {
      final marker = '/storage/v1/object/public/storage/';
      final absolute = uri.toString();
      final idx = absolute.indexOf(marker);
      if (idx >= 0) {
        final objectPath = absolute.substring(idx + marker.length);
        if (objectPath.isNotEmpty) {
          try {
            final signed = await client.storage
                .from('storage')
                .createSignedUrl(objectPath, 60 * 30);
            final signedUri = Uri.tryParse(signed);
            if (signedUri != null) {
              uri = signedUri;
            }
          } catch (_) {
            // Fall back to raw URL open below.
          }
        }
      }
    }
    if (uri == null) return;
    final ok = await launchUrl(uri, mode: LaunchMode.externalApplication);
    if (!ok && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Could not open attachment link.')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final handle = widget.person?.handle;
    final (statusLabel, statusColor) = _statusMeta(_status);
    final (healthLabel, healthColor) = _healthMeta(_health);
    final canEdit = widget.canEdit;
    final currentUserId = Supabase.instance.client.auth.currentUser?.id;
    final canSendMessage =
        !_sendingMessage && _messageController.text.trim().isNotEmpty;
    final canDelete = canEdit &&
        widget.expectation.writerUserId != null &&
        widget.expectation.writerUserId == currentUserId;
    final isDiscussionPoint = _isDiscussionPoint(widget.expectation);
    final hasReceiver = handle != null &&
        handle.trim().isNotEmpty &&
        widget.expectation.personId.trim().isNotEmpty;
    final showInviteForReceiver = canEdit &&
        widget.person != null &&
        (widget.person!.authUserId ?? '').trim().isEmpty;
    final working = Expectation(
      id: widget.expectation.id,
      createdAt: widget.expectation.createdAt,
      writerUserId: widget.expectation.writerUserId,
      personId: widget.expectation.personId,
      summary: _descriptionController.text,
      deadlineLabel: _deadlineLabel,
      deadlineAt: _deadlineAt,
      finishedAt: widget.expectation.finishedAt,
      responsibleUpdatedAt: widget.expectation.responsibleUpdatedAt,
      publishedAt: widget.expectation.publishedAt,
      seenAt: widget.expectation.seenAt,
      lastChattedSenderAt: widget.expectation.lastChattedSenderAt,
      lastChattedReceiverAt: widget.expectation.lastChattedReceiverAt,
      progress: _progress,
      health: _health,
      type: widget.expectation.type,
      status: _status,
      visibility: _visibility,
    );
    final tags = _tagsRegex
        .allMatches(_descriptionController.text)
        .map((m) => (m.group(1) ?? '').trim())
        .where((x) => x.isNotEmpty)
        .toSet()
        .toList();

    return Container(
      decoration: BoxDecoration(
        color: scheme.surfaceContainerLow.withValues(alpha: 0.92),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: scheme.outlineVariant.withValues(alpha: 0.35)),
      ),
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 14, 10, 8),
            child: Row(
              children: [
                Expanded(
                  child: Row(
                    children: [
                      Flexible(
                        child: Text(
                          isDiscussionPoint
                              ? (_visibility == ExpectationVisibility.shadow
                                    ? 'Talking point - PERSONAL'
                                    : 'Talking point')
                              : (_visibility == ExpectationVisibility.shadow
                                    ? 'Expectation Details - PERSONAL'
                                    : 'Expectation Details'),
                          style: theme.textTheme.titleLarge?.copyWith(
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                      if (_visibility == ExpectationVisibility.shadow) ...[
                        const SizedBox(width: 8),
                        Icon(
                          Icons.visibility_off_outlined,
                          size: 18,
                          color: scheme.onSurfaceVariant,
                        ),
                      ],
                    ],
                  ),
                ),
                IconButton(
                  tooltip: 'Close',
                  onPressed: () => Navigator.of(context).pop(_hasSavedChanges),
                  icon: const Icon(Icons.close),
                ),
              ],
            ),
          ),
          const Divider(height: 1),
          Expanded(
            child: ListView(
              padding: const EdgeInsets.fromLTRB(16, 14, 16, 0),
              children: [
                LayoutBuilder(
                  builder: (context, constraints) {
                    final left = <Widget>[
                      _DetailRow(
                        label: 'From',
                        value: _senderLabel.startsWith('@')
                            ? _senderLabel
                            : '@$_senderLabel',
                      ),
                      if (hasReceiver)
                        _DetailRow(
                          label: 'To',
                          valueWidget: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Text(
                                handle.startsWith('@') ? handle : '@$handle',
                                style: theme.textTheme.bodyMedium?.copyWith(
                                  color: scheme.onSurface,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                              if (showInviteForReceiver) ...[
                                const SizedBox(width: 8),
                                TextButton(
                                  onPressed: _inviting ? null : _inviteReceiver,
                                  style: TextButton.styleFrom(
                                    visualDensity: VisualDensity.compact,
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 8,
                                      vertical: 4,
                                    ),
                                    minimumSize: const Size(0, 0),
                                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                                  ),
                                  child: _inviting
                                      ? const SizedBox(
                                          width: 12,
                                          height: 12,
                                          child: CircularProgressIndicator(strokeWidth: 2),
                                        )
                                      : const Text('Invite'),
                                ),
                              ],
                            ],
                          ),
                        ),
                      if (widget.expectation.seenAt != null)
                        _DetailRow(
                          label: 'Seen',
                          valueWidget: Text(
                            _createdRelativeLabel(widget.expectation.seenAt!),
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: scheme.onSurface,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          hint: _exactDateTimeLabel(widget.expectation.seenAt!),
                        )
                      else if (widget.expectation.publishedAt != null)
                        _DetailRow(
                          label: 'Published',
                          valueWidget: Text(
                            _createdRelativeLabel(widget.expectation.publishedAt!),
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: scheme.onSurface,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          hint: _exactDateTimeLabel(widget.expectation.publishedAt!),
                        )
                      else if (working.responsibleUpdatedAt != null)
                        _DetailRow(
                          label: 'Updated',
                          valueWidget: Text(
                            _createdRelativeLabel(working.responsibleUpdatedAt!),
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: scheme.onSurface,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          hint: _exactDateTimeLabel(working.responsibleUpdatedAt!),
                        )
                      else
                        _DetailRow(
                          label: 'Created',
                          valueWidget: Text(
                            _createdRelativeLabel(widget.expectation.createdAt),
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: scheme.onSurface,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          hint: _exactDateTimeLabel(widget.expectation.createdAt),
                        ),
                      if (tags.isNotEmpty)
                        _DetailRow(
                          label: 'Tags',
                          alignTop: true,
                          valueWidget: Wrap(
                            spacing: 6,
                            runSpacing: 6,
                            children: [
                              for (final t in tags) LedgerTagChip(tag: t),
                            ],
                          ),
                        ),
                    ];
                    final right = <Widget>[
                      if (!isDiscussionPoint) ...[
                        _DetailRow(
                          label: 'Health',
                          valueWidget: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Flexible(
                                child: canEdit
                                    ? DropdownButtonHideUnderline(
                                        child: DropdownButton<ExpectationHealth>(
                                          value: _health,
                                          isDense: true,
                                          style: theme.textTheme.bodySmall?.copyWith(
                                            color: scheme.onSurface,
                                            fontWeight: FontWeight.w600,
                                          ),
                                          iconSize: 18,
                                          items: const [
                                            DropdownMenuItem(
                                              value: ExpectationHealth.unknown,
                                              child: Text('Unknown'),
                                            ),
                                            DropdownMenuItem(
                                              value: ExpectationHealth.onTrack,
                                              child: Text('On track'),
                                            ),
                                            DropdownMenuItem(
                                              value: ExpectationHealth.atRisk,
                                              child: Text('At risk'),
                                            ),
                                            DropdownMenuItem(
                                              value: ExpectationHealth.offTrack,
                                              child: Text('Off track'),
                                            ),
                                          ],
                                          onChanged: (v) => setState(() => _health = v ?? _health),
                                        ),
                                      )
                                    : Text(healthLabel),
                              ),
                              if (_health == ExpectationHealth.unknown) ...[
                                const SizedBox(width: 6),
                                Tooltip(
                                  message: 'Set health state',
                                  child: Icon(
                                    Icons.warning_amber_rounded,
                                    size: 16,
                                    color: Colors.amberAccent.shade200,
                                  ),
                                ),
                              ],
                            ],
                          ),
                          dotColor: healthColor,
                        ),
                        _DetailRow(
                          label: 'Status',
                          valueWidget: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Flexible(
                                child: canEdit
                                    ? DropdownButtonHideUnderline(
                                        child: DropdownButton<ExpectationStatus>(
                                          value: _status,
                                          isDense: true,
                                          style: theme.textTheme.bodySmall?.copyWith(
                                            color: scheme.onSurface,
                                            fontWeight: FontWeight.w600,
                                          ),
                                          iconSize: 18,
                                          items: const [
                                            DropdownMenuItem(
                                              value: ExpectationStatus.pending,
                                              child: Text('Pending'),
                                            ),
                                            DropdownMenuItem(
                                              value: ExpectationStatus.accepted,
                                              child: Text('Accepted'),
                                            ),
                                            DropdownMenuItem(
                                              value: ExpectationStatus.finished,
                                              child: Text('Finished'),
                                            ),
                                            DropdownMenuItem(
                                              value: ExpectationStatus.abandoned,
                                              child: Text('Abandoned'),
                                            ),
                                          ],
                                          onChanged: (v) => setState(() => _status = v ?? _status),
                                        ),
                                      )
                                    : Text(statusLabel),
                              ),
                              if (_status == ExpectationStatus.pending) ...[
                                const SizedBox(width: 6),
                                Tooltip(
                                  message: 'Status still pending',
                                  child: Icon(
                                    Icons.warning_amber_rounded,
                                    size: 16,
                                    color: Colors.amberAccent.shade200,
                                  ),
                                ),
                              ],
                            ],
                          ),
                          dotColor: statusColor,
                        ),
                      ],
                      _DetailRow(
                        label: 'Deadline',
                        valueWidget: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(
                              _deadlineDistanceLabel(working),
                              style: theme.textTheme.bodyMedium?.copyWith(
                                color: scheme.onSurface,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                            if (canEdit) ...[
                              const SizedBox(width: 8),
                              InkResponse(
                                onTap: _pickDeadline,
                                radius: 14,
                                child: Icon(
                                  Icons.edit_outlined,
                                  size: 16,
                                  color: scheme.onSurfaceVariant,
                                ),
                              ),
                            ],
                          ],
                        ),
                        hint: _deadlineTooltip(working),
                        alignTop: true,
                      ),
                      if (_visibility == ExpectationVisibility.echo)
                        _DetailRow(
                          label: 'Progress',
                          valueWidget: Row(
                            children: [
                              Flexible(
                                child: FractionallySizedBox(
                                  widthFactor: 0.8,
                                  alignment: Alignment.centerLeft,
                                  child: ClipRRect(
                                    borderRadius: BorderRadius.circular(999),
                                    child: LinearProgressIndicator(
                                      value: ((working.progress ?? 0).clamp(0, 100)) / 100.0,
                                      minHeight: 8,
                                      backgroundColor: scheme.surfaceContainerHighest,
                                    ),
                                  ),
                                ),
                              ),
                              const SizedBox(width: 8),
                              Text(
                                '${(working.progress ?? 0).clamp(0, 100)}%',
                                style: theme.textTheme.bodySmall?.copyWith(
                                  color: scheme.onSurface,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ],
                          ),
                          trailing: canEdit
                              ? InkResponse(
                                  onTap: _editProgress,
                                  radius: 14,
                                  child: Icon(
                                    Icons.edit_outlined,
                                    size: 16,
                                    color: scheme.onSurfaceVariant,
                                  ),
                                )
                              : null,
                        ),
                    ];
                    if (constraints.maxWidth < 620) {
                      return Column(children: [...left, ...right]);
                    }
                    final rowCount = left.length > right.length
                        ? left.length
                        : right.length;
                    return Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Expanded(
                          child: Column(
                            children: [
                              for (var i = 0; i < rowCount; i++)
                                Row(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Expanded(
                                      child: i < left.length
                                          ? left[i]
                                          : const SizedBox.shrink(),
                                    ),
                                    const SizedBox(width: 16),
                                    Expanded(
                                      child: i < right.length
                                          ? right[i]
                                          : const SizedBox.shrink(),
                                    ),
                                  ],
                                ),
                            ],
                          ),
                        ),
                      ],
                    );
                  },
                ),
                const SizedBox(height: 12),
                Text(
                  'Description',
                  style: theme.textTheme.labelLarge?.copyWith(
                    fontWeight: FontWeight.w700,
                    color: scheme.onSurface,
                  ),
                ),
                const SizedBox(height: 16),
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(10),
                    color: scheme.surfaceContainerHighest.withValues(alpha: 0.35),
                    border: Border.all(color: scheme.outline.withValues(alpha: 0.28)),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Expanded(
                            child: _editingDescription && canEdit
                                ? Focus(
                                    onKeyEvent: (node, event) {
                                      if (event is KeyDownEvent &&
                                          event.logicalKey == LogicalKeyboardKey.escape) {
                                        setState(() {
                                          _descriptionController.text = _savedSummary;
                                          _descriptionController.selection =
                                              TextSelection.collapsed(
                                                offset: _descriptionController.text.length,
                                              );
                                          _editingDescription = false;
                                        });
                                        return KeyEventResult.handled;
                                      }
                                      return KeyEventResult.ignored;
                                    },
                                    child: TextField(
                                      controller: _descriptionController,
                                      minLines: 4,
                                      maxLines: 10,
                                      decoration: const InputDecoration(
                                        border: OutlineInputBorder(),
                                      ),
                                    ),
                                  )
                                : canEdit
                                    ? InkWell(
                                        borderRadius: BorderRadius.circular(6),
                                        onTap: () => setState(() {
                                          _editingDescription = true;
                                        }),
                                        child: Padding(
                                          padding: const EdgeInsets.symmetric(
                                            vertical: 2,
                                          ),
                                          child: Text(
                                            _descriptionController.text,
                                            style: theme.textTheme.bodyMedium
                                                ?.copyWith(height: 1.45),
                                          ),
                                        ),
                                      )
                                    : Text(
                                        _descriptionController.text,
                                        style: theme.textTheme.bodyMedium
                                            ?.copyWith(height: 1.45),
                                      ),
                          ),
                          if (canEdit) ...[
                            const SizedBox(width: 8),
                            SizedBox(
                              width: 32,
                              child: IconButton(
                                tooltip: 'Edit description',
                                visualDensity: VisualDensity.compact,
                                onPressed: () => setState(() {
                                  _editingDescription = !_editingDescription;
                                }),
                                icon: Icon(
                                  _editingDescription
                                      ? Icons.edit_off_outlined
                                      : Icons.edit_outlined,
                                  size: 18,
                                ),
                              ),
                            ),
                          ],
                        ],
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 18),
                Row(
                  children: [
                    if (canDelete)
                      TextButton.icon(
                        onPressed: (_saving || _deleting) ? null : _deleteExpectation,
                        icon: _deleting
                            ? const SizedBox(
                                width: 14,
                                height: 14,
                                child: CircularProgressIndicator(strokeWidth: 2),
                              )
                            : const Icon(Icons.delete_outline),
                        label: const Text('Delete'),
                        style: TextButton.styleFrom(
                          foregroundColor: scheme.error,
                        ),
                      ),
                    const Spacer(),
                    FilledButton(
                      onPressed: (_saving || _deleting || !_dirty || !canEdit)
                          ? null
                          : _save,
                      child: const Text('Save'),
                    ),
                    const SizedBox(width: 8),
                    if (canEdit && !_editingDescription) ...[
                      if (_isColleagueTalkingPoint) ...[
                        if (_visibility == ExpectationVisibility.shadow &&
                            _status != ExpectationStatus.finished &&
                            _status != ExpectationStatus.abandoned)
                          FilledButton(
                            onPressed: (_saving || _deleting)
                                ? null
                                : _archiveColleagueTalkingPoint,
                            child: const Text('Archive'),
                          ),
                      ] else if (_visibility == ExpectationVisibility.shadow)
                        FilledButton(
                          onPressed: (_saving || _deleting)
                              ? null
                              : () => _save(publish: true),
                          child: const Text('Publish'),
                        ),
                    ],
                  ],
                ),
                const SizedBox(height: 15),
                const Divider(height: 1),
                const SizedBox(height: 15),
                ConstrainedBox(
                  constraints: BoxConstraints(
                    minHeight: _messagesLoading || _messagesError != null
                        ? 80
                        : (_messages.isNotEmpty ? 210 : 24),
                  ),
                  child: _messagesLoading
                      ? const Padding(
                          padding: EdgeInsets.symmetric(vertical: 8),
                          child: Text('Loading conversation...'),
                        )
                      : _messagesError != null
                      ? Padding(
                          padding: const EdgeInsets.symmetric(vertical: 8),
                          child: Text(
                            _messagesError!,
                            style: TextStyle(color: scheme.error),
                          ),
                        )
                      : _messages.isNotEmpty
                      ? Column(
                          children: [
                            for (var i = 0; i < _messages.length; i++) ...[
                              if (i > 0) const SizedBox(height: 14),
                              (() {
                                final m = _messages[i];
                                final mine = m.senderPersonId == _myPersonId;
                                return Align(
                                  alignment:
                                      mine ? Alignment.centerRight : Alignment.centerLeft,
                                  child: Padding(
                                    padding: const EdgeInsets.symmetric(horizontal: 10),
                                    child: Container(
                                      constraints: const BoxConstraints(maxWidth: 520),
                                      padding: const EdgeInsets.all(12),
                                      decoration: BoxDecoration(
                                        borderRadius: BorderRadius.circular(10),
                                        color: mine
                                            ? scheme.primaryContainer.withValues(alpha: 0.55)
                                            : scheme.surfaceContainerHigh.withValues(alpha: 0.45),
                                      ),
                                      child: Column(
                                        crossAxisAlignment: CrossAxisAlignment.start,
                                        children: [
                                          Text(
                                            '${m.senderLabel} · ${_chatRelativeLabel(m.createdAt)}',
                                            style: theme.textTheme.labelSmall?.copyWith(
                                              color: scheme.onSurfaceVariant,
                                            ),
                                          ),
                                          const SizedBox(height: 4),
                                          Text(
                                            m.messageText,
                                            style: theme.textTheme.bodyMedium,
                                          ),
                                          for (final a in m.attachments) ...[
                                            const SizedBox(height: 4),
                                            InkWell(
                                              onTap: () => _openAttachmentUrl(a.fileUrl),
                                              borderRadius: BorderRadius.circular(6),
                                              child: MouseRegion(
                                                cursor: SystemMouseCursors.click,
                                                child: Padding(
                                                  padding: const EdgeInsets.symmetric(
                                                    horizontal: 2,
                                                    vertical: 2,
                                                  ),
                                                  child: Text(
                                                    a.fileName,
                                                    style: theme.textTheme.bodySmall?.copyWith(
                                                      color: scheme.primary,
                                                      decoration: TextDecoration.underline,
                                                    ),
                                                  ),
                                                ),
                                              ),
                                            ),
                                          ],
                                        ],
                                      ),
                                    ),
                                  ),
                                );
                              })(),
                            ],
                          ],
                        )
                      : const SizedBox.shrink(),
                ),
                const SizedBox(height: 15),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Expanded(
                      child: TextField(
                        controller: _messageController,
                        onChanged: (_) => setState(() {}),
                        minLines: 2,
                        maxLines: 5,
                        style: theme.textTheme.bodySmall,
                        decoration: InputDecoration(
                          hintText: 'Write a message...',
                          hintStyle: theme.textTheme.bodySmall?.copyWith(
                            color: scheme.onSurfaceVariant.withValues(alpha: 0.78),
                          ),
                          isDense: true,
                          contentPadding: const EdgeInsets.symmetric(
                            horizontal: 10,
                            vertical: 10,
                          ),
                          border: const OutlineInputBorder(),
                        ),
                      ),
                    ),
                    const SizedBox(width: 6),
                    IconButton(
                      tooltip: 'Attach file',
                      onPressed: _uploadingAttachment ? null : _pickAndUploadAttachment,
                      icon: _uploadingAttachment
                          ? const SizedBox(
                              width: 16,
                              height: 16,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.attach_file),
                    ),
                  ],
                ),
                if (_pendingAttachments.isNotEmpty) ...[
                  const SizedBox(height: 6),
                  Wrap(
                    spacing: 6,
                    runSpacing: 6,
                    children: [
                      for (var i = 0; i < _pendingAttachments.length; i++)
                        InputChip(
                          label: Text(_pendingAttachments[i].fileName),
                          onDeleted: () {
                            setState(() {
                              _pendingAttachments.removeAt(i);
                            });
                          },
                        ),
                    ],
                  ),
                ],
                const SizedBox(height: 12),
                Align(
                  alignment: Alignment.centerRight,
                  child: FilledButton.icon(
                    onPressed: canSendMessage ? _sendMessage : null,
                    icon: const Icon(Icons.send_outlined),
                    label: const Text('Send'),
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

class _DetailRow extends StatelessWidget {
  const _DetailRow({
    required this.label,
    this.value,
    this.valueWidget,
    this.hint,
    this.dotColor,
    this.trailing,
    this.alignTop = false,
  });

  final String label;
  final String? value;
  final Widget? valueWidget;
  final String? hint;
  final Color? dotColor;
  final Widget? trailing;
  final bool alignTop;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final valueNode = Row(
      mainAxisSize: MainAxisSize.max,
      crossAxisAlignment: alignTop ? CrossAxisAlignment.start : CrossAxisAlignment.center,
      children: [
        if (dotColor != null) ...[
          Container(
            width: 9,
            height: 9,
            decoration: BoxDecoration(color: dotColor, shape: BoxShape.circle),
          ),
          const SizedBox(width: 6),
        ],
        Expanded(
          child: Align(
            alignment: Alignment.centerLeft,
            child: valueWidget ??
                Text(
                  value ?? '',
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: scheme.onSurface,
                    fontWeight: FontWeight.w600,
                  ),
                ),
          ),
        ),
        if (trailing != null) ...[
          const SizedBox(width: 4),
          Align(
            alignment: alignTop ? Alignment.topCenter : Alignment.center,
            child: trailing!,
          ),
        ],
      ],
    );
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 7),
      child: Row(
        crossAxisAlignment: alignTop ? CrossAxisAlignment.start : CrossAxisAlignment.center,
        children: [
          SizedBox(
            width: 98,
            child: Text(
              label,
              style: theme.textTheme.bodySmall?.copyWith(
                color: scheme.onSurfaceVariant,
              ),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: hint == null ? valueNode : Tooltip(message: hint!, child: valueNode),
          ),
        ],
      ),
    );
  }
}
