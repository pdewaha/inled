import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' show min;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:exled/models/expectation.dart';
import 'package:exled/models/expectation_changelog_payload.dart';
import 'package:exled/models/expectation_health.dart';
import 'package:exled/models/expectation_type.dart';
import 'package:exled/models/feed_entry.dart';
import 'package:exled/models/ledger_pillar.dart';
import 'package:exled/models/person.dart';
import 'package:exled/models/expectation_status.dart';
import 'package:exled/models/expectation_visibility.dart';
import 'package:exled/services/expectation_activity_feed.dart';
import 'package:exled/services/expectation_chat_changelog.dart';
import 'package:exled/services/expectation_mentions.dart';
import 'package:exled/services/send_invite_email.dart';
import 'package:exled/supabase_config.dart';
import 'package:exled/theme.dart';
import 'package:exled/utils/capture_parser.dart';
import 'package:exled/utils/display_date_format.dart';
import 'package:exled/utils/hashtag_normalize.dart';
import 'package:exled/utils/person_display.dart';
import 'package:exled/widgets/command_capture_bar.dart';
import 'package:exled/widgets/expectation_changelog_message_body.dart';
import 'package:exled/widgets/ledger_tag_chip.dart';
import 'package:exled/widgets/debug_menu_button.dart';
import 'package:exled/widgets/responsive_centered_body.dart';
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
  /// Save-action row (Home kind row / Add topic / Add expectation): Tab order field ? A ? B.
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
  /// Cached company id for the signed-in person (feed + read watermarks).
  String? _ledgerCompanyId;
  int _activityUnreadCount = 0;
  /// Expectations with at least one changelog row unread for the current reader (listing bell).
  final Set<String> _expectationIdsWithChangelogUnread = {};
  /// Changelog marked seen in UI (details open / Mark read); hides listing bell while the
  /// server snapshot still reports unread rows for that expectation (watermark can lag).
  final Set<String> _changelogBellClearedIds = {};
  final GlobalKey _activityBellAnchorKey = GlobalKey(debugLabel: 'activityBell');
  final GlobalKey<_ExpectationDetailsPanelState> _expectationDetailsPanelKey =
      GlobalKey(debugLabel: 'expectationDetailsPanel');
  OverlayEntry? _activityFeedOverlayEntry;

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
  /// Public talking-points list: filter by @handle in summary (not [Expectation.personId]).
  String? _publicMentionFilterHandle;
  _TalkingPointsSubView _talkingPointsSubView = _TalkingPointsSubView.meetingsOrTags;
  /// Private view: filter talking points that @mention this handle (author-only).
  String? _colleagueMentionFilterHandle;
  ExpectationStatus? _othersStatusFilter;
  String? _othersTagFilter;
  String? _othersPersonFilter;
  ExpectationStatus? _inboxStatusFilter;
  String? _inboxTagFilter;
  /// @handles from [expectation_mentions] (includes leading @ stripped from summary).
  Map<String, List<String>> _mentionHandlesByExpectationId = {};
  Map<String, Set<String>> _mentionPersonIdsByExpectationId = {};

  /// [ExpectationMentionsIndex] uses `const {}` when empty — always clone before storing in state.
  void _replaceMentionIndexesFrom(ExpectationMentionsIndex index) {
    _mentionHandlesByExpectationId = {
      for (final e in index.handlesByExpectationId.entries)
        e.key: List<String>.from(e.value),
    };
    _mentionPersonIdsByExpectationId = {
      for (final e in index.personIdsByExpectationId.entries)
        e.key: Set<String>.from(e.value),
    };
  }

  void _setMentionHandlesForExpectation(String expectationId, List<String> handles) {
    final next = <String, List<String>>{};
    for (final e in _mentionHandlesByExpectationId.entries) {
      next[e.key] = List<String>.from(e.value);
    }
    next[expectationId] = List<String>.from(handles);
    _mentionHandlesByExpectationId = next;
  }
  /// Set from `?expectation=` in the page URL (notification email deep link).
  String? _emailDeepLinkExpectationId;

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

  /// Listing bell: unread chat for this user, or unread expectation changelog/activity.
  bool _hasUnreadListingIndicator(Expectation e) {
    if (_hasUnreadChat(e)) return true;
    if (_changelogBellClearedIds.contains(e.id)) return false;
    return _expectationIdsWithChangelogUnread.contains(e.id);
  }

  /// Updates in-memory timestamps so the listing bell drops before the next fetch.
  void _optimisticallyMarkExpectationChatCaughtUp(
    String expectationId,
    String authUserId,
  ) {
    final idx = _expectations.indexWhere((x) => x.id == expectationId);
    if (idx == -1) return;
    final old = _expectations[idx];
    final now = DateTime.now().toUtc();
    final isWriter =
        old.writerUserId != null && old.writerUserId == authUserId;
    _expectations[idx] = Expectation(
      id: old.id,
      createdAt: old.createdAt,
      writerUserId: old.writerUserId,
      personId: old.personId,
      summary: old.summary,
      deadlineLabel: old.deadlineLabel,
      deadlineAt: old.deadlineAt,
      finishedAt: old.finishedAt,
      responsibleUpdatedAt: old.responsibleUpdatedAt,
      publishedAt: old.publishedAt,
      seenAt: old.seenAt,
      lastChattedSenderAt: isWriter ? now : old.lastChattedSenderAt,
      lastChattedReceiverAt: isWriter ? old.lastChattedReceiverAt : now,
      updateRequestedAt: old.updateRequestedAt,
      progress: old.progress,
      health: old.health,
      type: old.type,
      status: old.status,
      visibility: old.visibility,
    );
  }

  void _openTagPillar(String tag) {
    setState(() {
      _homePendingEntry = null;
      _pillar = LedgerPillar.tags;
      _talkingPointsSubView = _TalkingPointsSubView.meetingsOrTags;
      _tagsSelectedTag = tag.trim().toLowerCase();
      _publicMentionFilterHandle = null;
      _colleagueMentionFilterHandle = null;
    });
    _captureFocus.unfocus();
  }

  void _openPublicMentionPillar(String handle) {
    setState(() {
      _homePendingEntry = null;
      _pillar = LedgerPillar.tags;
      _talkingPointsSubView = _TalkingPointsSubView.meetingsOrTags;
      _publicMentionFilterHandle = handle.trim().toLowerCase();
      _tagsSelectedTag = null;
      _colleagueMentionFilterHandle = null;
    });
    _captureFocus.unfocus();
  }

  /// Rail @ chip: open Private filtered to talking points that mention this handle.
  void _openPrivateMentionColleagues(String handle) {
    final needle = handle.trim().toLowerCase();
    if (needle.isEmpty) return;
    setState(() {
      _homePendingEntry = null;
      _pillar = LedgerPillar.tags;
      _talkingPointsSubView = _TalkingPointsSubView.colleagues;
      _colleagueMentionFilterHandle = needle;
      _tagsSelectedTag = null;
      _publicMentionFilterHandle = null;
    });
    _captureFocus.unfocus();
  }

  /// Published (echo) talking points.
  Iterable<Expectation> _publicEchoTalkingPoints() {
    return _expectations.where(
      (x) =>
          x.type == ExpectationType.topic &&
          x.visibility == ExpectationVisibility.echo,
    );
  }

  bool _summaryMentionsHandle(String summary, String handleLower) {
    if (handleLower.isEmpty) return false;
    return extractMentionHandlesFromText(summary)
        .map((h) => h.toLowerCase())
        .contains(handleLower);
  }

  List<String> _persistedMentionHandles(Expectation e) {
    return _mentionHandlesByExpectationId[e.id] ?? const [];
  }

  /// Primary receiver first, then other @mentioned people (expectations + talking points).
  List<Person> _receiverPeopleForExpectation(Expectation e) {
    final out = <Person>[];
    final seen = <String>{};
    void addPerson(Person p) {
      if (seen.add(p.id)) out.add(p);
    }

    void addId(String id) {
      final pid = id.trim();
      if (pid.isEmpty) return;
      for (final p in _people) {
        if (p.id == pid) {
          addPerson(p);
          return;
        }
      }
    }

    void addHandle(String rawHandle) {
      final h = rawHandle.trim().toLowerCase();
      if (h.isEmpty) return;
      for (final p in _people) {
        if (p.handle.trim().toLowerCase() == h) {
          addPerson(p);
          return;
        }
      }
    }

    addId(e.personId);
    for (final id in _mentionPersonIdsByExpectationId[e.id] ?? const {}) {
      addId(id);
    }
    if (e.type == ExpectationType.topic) {
      for (final handle in talkingPointMentionHandleList(
        summary: e.summary,
        persistedMentionHandles: _persistedMentionHandles(e),
      )) {
        addHandle(handle);
      }
    } else {
      Person? primary;
      final pid = e.personId.trim();
      if (pid.isNotEmpty) {
        for (final p in _people) {
          if (p.id == pid) {
            primary = p;
            break;
          }
        }
      }
      for (final handle in expectationReceiverHandleList(
        summary: e.summary,
        primaryPersonHandle: primary?.handle,
        persistedMentionHandles: _persistedMentionHandles(e),
      )) {
        addHandle(handle);
      }
    }
    return out;
  }

  bool _isExpectationReceiver(Expectation e, String myPersonId) {
    return expectationAppliesToPerson(
      e: e,
      myPersonId: myPersonId,
      mentionsIndex: ExpectationMentionsIndex(
        handlesByExpectationId: _mentionHandlesByExpectationId,
        personIdsByExpectationId: _mentionPersonIdsByExpectationId,
      ),
    );
  }

  bool _canEditExpectationForUser(
    Expectation e,
    String? authUserId,
    String? myPersonId,
  ) {
    if (authUserId != null && e.writerUserId == authUserId) return true;
    if (myPersonId != null && _isExpectationReceiver(e, myPersonId)) {
      return true;
    }
    return false;
  }

  bool _talkingPointMentionsHandle(Expectation e, String handleLower) {
    if (handleLower.isEmpty) return false;
    if (_summaryMentionsHandle(e.summary, handleLower)) return true;
    return _persistedMentionHandles(e)
        .any((h) => h.toLowerCase() == handleLower);
  }

  /// Outbox only: filter the current list by #tag without leaving the pillar.
  void _applyOutboxTagFilter(String tag) {
    setState(() {
      _othersTagFilter = tag.trim().toLowerCase();
    });
  }

  /// @handles on your shadow talking points (Private), from summary text (all mentions).
  List<String> _privateRailMentionHandlesFromExpectations({int max = 20}) {
    final uid = Supabase.instance.client.auth.currentUser?.id;
    if (uid == null) return [];
    final seen = <String>{};
    final out = <String>[];
    final pool = _expectations
        .where(
          (x) =>
              x.type == ExpectationType.topic &&
              x.writerUserId == uid &&
              x.visibility == ExpectationVisibility.shadow,
        )
        .toList()
      ..sort((a, b) => b.createdAt.compareTo(a.createdAt));
    for (final e in pool) {
      for (final handle in talkingPointMentionHandleList(
        summary: e.summary,
        persistedMentionHandles: _persistedMentionHandles(e),
      )) {
        final k = handle.toLowerCase();
        if (seen.add(k)) out.add(handle);
        if (out.length >= max) return out;
      }
    }
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
        if (seen.add(tag)) out.add(tag);
        if (out.length >= max) return out;
      }
    }
    return out;
  }

  /// @handles cited on public talking points (not [target_person_id]).
  List<String> _publicRailMentionHandlesFromExpectations({int max = 20}) {
    final seen = <String>{};
    final out = <String>[];
    final pool = _publicEchoTalkingPoints().toList()
      ..sort((a, b) => b.createdAt.compareTo(a.createdAt));
    for (final e in pool) {
      for (final handle in talkingPointMentionHandleList(
        summary: e.summary,
        persistedMentionHandles: _persistedMentionHandles(e),
      )) {
        final k = handle.toLowerCase();
        if (seen.add(k)) out.add(handle);
        if (out.length >= max) return out;
      }
    }
    return out;
  }

  /// #tags on echo talking points (Public), merged with [\_recentTags].
  /// [_loadRecentTagsFromSupabase]) loads echo rows without a receiver for #tags only.
  List<String> _mergedPublicRailTags({int max = 20}) {
    final seen = <String>{};
    final out = <String>[];
    void addDisplay(String tag) {
      final k = normalizeHashtagToken(tag);
      if (k.isEmpty) return;
      if (seen.add(k)) out.add(k);
    }
    final pool = _publicEchoTalkingPoints().toList()
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
      final k = normalizeHashtagToken(t);
      if (k.isEmpty) return;
      if (seen.add(k)) out.add(k);
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
      _publicMentionFilterHandle = null;
      _colleagueMentionFilterHandle = null;
    });
  }

  void _openTalkingPointsSubView(_TalkingPointsSubView view) {
    setState(() {
      _homePendingEntry = null;
      _pillar = LedgerPillar.tags;
      _talkingPointsSubView = view;
      if (view == _TalkingPointsSubView.colleagues) {
        _tagsSelectedTag = null;
        _publicMentionFilterHandle = null;
      } else {
        _colleagueMentionFilterHandle = null;
        _publicMentionFilterHandle = null;
      }
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

  /// Outbox draft ? published (visible to receiver): echo visibility + published_at.
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
            updateRequestedAt: e.updateRequestedAt,
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
      await appendExpectationChangelogForSignedInUser(
        client: Supabase.instance.client,
        expectationId: expectation.id,
        expectationWriterUserId: expectation.writerUserId,
        messageBuilder: (_) {
          final noun =
              expectation.type == ExpectationType.topic ? 'talking point' : 'expectation';
          return 'Published this $noun.';
        },
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
    final isReceiver = _isExpectationReceiver(expectation, meId);
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

  /// Private talking-point row: shadow → echo; @mentions sync to [expectation_mentions].
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
    if (expectation.type != ExpectationType.topic) return;
    final now = DateTime.now().toUtc();
    try {
      await Supabase.instance.client.from('expectations').update({
        'expectation_visibility': ExpectationVisibility.echo.index,
        'target_person_id': null,
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
            personId: '',
            summary: e.summary,
            deadlineLabel: e.deadlineLabel,
            deadlineAt: e.deadlineAt,
            finishedAt: e.finishedAt,
            responsibleUpdatedAt: now,
            publishedAt: now,
            seenAt: e.seenAt,
            lastChattedSenderAt: e.lastChattedSenderAt,
            lastChattedReceiverAt: e.lastChattedReceiverAt,
            updateRequestedAt: e.updateRequestedAt,
            progress: e.progress,
            health: e.health,
            type: e.type,
            status: e.status,
            visibility: ExpectationVisibility.echo,
          );
        }
      });
      final client = Supabase.instance.client;
      final user = client.auth.currentUser;
      if (user != null) {
        final meRows = await client
            .from('people')
            .select('id,company_id,display_name,handle')
            .eq('auth_user_id', user.id)
            .limit(1);
        if ((meRows as List).isNotEmpty) {
          final meRow = meRows.first as Map<String, dynamic>;
          final cachedHandles =
              _mentionHandlesByExpectationId[expectation.id] ?? const [];
          final mentionLine = [
            ...cachedHandles.map((h) => '@$h'),
            ...extractMentionHandlesFromText(expectation.summary)
                .where((h) => !cachedHandles
                    .any((c) => c.toLowerCase() == h.toLowerCase()))
                .map((h) => '@$h'),
            expectation.summary,
          ].join(' ');
          await syncTalkingPointMentions(
            client: client,
            companyId: meRow['company_id'] as String,
            expectationId: expectation.id,
            summary: mentionLine,
            authorPersonId: meRow['id'] as String,
            people: _people,
            resolveMe: (_) async {
              return Person(
                id: meRow['id'] as String,
                createdAt: DateTime.now().toUtc(),
                displayName: (meRow['display_name'] as String?) ?? '',
                handle: (meRow['handle'] as String?) ?? 'me',
                authUserId: user.id,
              );
            },
            createPlaceholder: (handle) =>
                _createPersonFromHandleInSupabase(handle),
            replaceExisting: true,
          );
        }
      }
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Published.')),
      );
      await appendExpectationChangelogForSignedInUser(
        client: Supabase.instance.client,
        expectationId: expectation.id,
        expectationWriterUserId: expectation.writerUserId,
        messageBuilder: (_) {
          final noun =
              expectation.type == ExpectationType.topic ? 'talking point' : 'expectation';
          return 'Published this $noun.';
        },
      );
      await _loadExpectationsFromSupabase();
      if (mounted) {
        await _refreshActivityUnreadCount();
      }
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
      await appendExpectationChangelogForSignedInUser(
        client: Supabase.instance.client,
        expectationId: expectation.id,
        expectationWriterUserId: expectation.writerUserId,
        messageBuilder: (_) {
          final noun =
              expectation.type == ExpectationType.topic ? 'talking point' : 'expectation';
          return 'Archived this $noun.';
        },
      );
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
            updateRequestedAt: e.updateRequestedAt,
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
    final linkExpId = Uri.base.queryParameters['expectation']?.trim();
    if (linkExpId != null && linkExpId.isNotEmpty) {
      _emailDeepLinkExpectationId = linkExpId;
    }
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
        _ledgerCompanyId = null;
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
          _ledgerCompanyId = null;
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
        _ledgerCompanyId = companyId;
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
      await _refreshActivityUnreadCount();
    } on PostgrestException catch (e) {
      if (!mounted) return;
      setState(() {
        _peopleLoading = false;
        _peopleLoadError = 'Failed to load people: ${e.message}';
        _myPersonId = null;
        _ledgerCompanyId = null;
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
        _ledgerCompanyId = null;
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
      // Public rail only: published talking points (echo + topic), not shadow/private rows.
      final rows = await client
          .from('expectations')
          .select('summary,created_at')
          .eq('company_id', companyId)
          .eq('expectation_type', ExpectationType.topic.index)
          .eq('expectation_visibility', ExpectationVisibility.echo.index)
          .order('created_at', ascending: false)
          .limit(200);

      final seen = <String>{};
      final tags = <String>[];
      for (final row in (rows as List)) {
        final summary = ((row['summary'] as String?) ?? '').trim();
        if (summary.isEmpty) continue;
        for (final tag in _extractInlineTags(summary)) {
          if (seen.add(tag)) {
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
          .select('id,company_id')
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
            'id,created_at,writer_user_id,target_person_id,summary,deadline_label,deadline_at,finished_at,responsible_updated_at,published_at,seen_at,last_chatted_sender_at,last_chatted_receiver_at,update_requested_at,progress,expectation_status,expectation_health,expectation_visibility,expectation_type',
          )
          .eq('company_id', companyId)
          .order('created_at', ascending: false);

      final mapped = <Expectation>[];
      for (final raw in rows as List) {
        if (raw is! Map<String, dynamic>) continue;
        final id = _dbString(raw['id']);
        if (id.isEmpty || !isPersistedExpectationId(id)) continue;
        mapped.add(_mapSupabaseExpectationRow(raw));
      }
      final mePersonId = _dbString(meRows.first['id']);
      List<Expectation> mentioned = const [];
      if (mePersonId.isNotEmpty) {
        try {
          mentioned = await fetchExpectationsMentioningPerson(
            client: client,
            companyId: companyId,
            myPersonId: mePersonId,
            mapRow: _mapSupabaseExpectationRow,
          );
        } catch (_) {
          mentioned = const [];
        }
      }
      final combined = mergePartyExpectationsWithMentions(
        party: mapped,
        mentioned: mentioned,
      );

      final peopleById = {for (final p in _people) p.id: p};
      ExpectationMentionsIndex mentionsIndex = ExpectationMentionsIndex.empty();
      try {
        mentionsIndex = await loadMentionHandlesByExpectationId(
          client: client,
          companyId: companyId,
          expectationIds: combined.map((e) => e.id),
          peopleById: peopleById,
        );
      } catch (_) {
        mentionsIndex = ExpectationMentionsIndex.empty();
      }

      if (!mounted) return;
      setState(() {
        _expectations
          ..clear()
          ..addAll(combined);
        _replaceMentionIndexesFrom(mentionsIndex);
        _expectationsLoading = false;
        _expectationsLoadError = null;
        _ledgerCompanyId ??= companyId;
      });
      await _refreshActivityUnreadCount();
      _tryOpenEmailDeepLinkExpectation();
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

  /// Opens `?expectation=<id>` from notification email links (web).
  void _tryOpenEmailDeepLinkExpectation() {
    final id = _emailDeepLinkExpectationId?.trim();
    if (id == null || id.isEmpty || !mounted || _expectationsLoading) return;
    for (final e in _expectations) {
      if (e.id != id) continue;
      _emailDeepLinkExpectationId = null;
      Person? person;
      if (e.personId.isNotEmpty) {
        for (final p in _people) {
          if (p.id == e.personId) {
            person = p;
            break;
          }
        }
      }
      unawaited(_openExpectationDetails(e: e, person: person));
      return;
    }
  }

  @override
  void dispose() {
    _dismissActivityFeedOverlay();
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
          final e = _expectationCaptureTextIsSubmittable(t) && !busy;
          return (e, e);
        }
        return (
          _talkingPointPrivateSubmittable(t) && !busy,
          _expectationCaptureTextIsSubmittable(t) && !busy,
        );
      case LedgerPillar.addTopic:
        return (
          _talkingPointPrivateSubmittable(t) && !busy,
          _talkingPointPublicSubmittable(t) && !busy,
        );
      case LedgerPillar.addExpectation:
        final e = _expectationCaptureTextIsSubmittable(t) && !busy;
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
      final detailsState = _expectationDetailsPanelKey.currentState;
      if (detailsState != null) {
        unawaited(_openQuickCaptureClosingDetailsIfNeeded(detailsState));
        return true;
      }
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
        if (!_expectationCaptureTextIsSubmittable(text) || _submitInFlight) {
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
    final canonical = normalizeHashtagToken(tag);
    if (canonical.isEmpty) return;
    final prefix = value.text.substring(0, start);
    final suffix = value.text.substring(end);
    final replacement = '#$canonical';
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
    final label = ledgerAtMentionLine(
      p.displayName.trim().isNotEmpty ? p.displayName : p.handle,
    );
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
        child: Text(
          label,
          style: chipStyle?.copyWith(
            color: sel ? scheme.onPrimaryContainer : scheme.onSurface,
          ),
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
                  _expectationCaptureTextIsSubmittable(value.text);
              final canSaveTalkingPoint =
                  _talkingPointPrivateSubmittable(value.text);
              final busy = _submitInFlight;
              final tpEnabled = canSaveTalkingPoint && !busy;
              final expEnabled = canSaveExpectation && !busy;
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

  /// Close the expectation/talking-point details dialog (with unsaved prompt if needed), then Quick Capture.
  Future<void> _openQuickCaptureClosingDetailsIfNeeded(
    _ExpectationDetailsPanelState detailsState,
  ) async {
    final closed = await detailsState.tryCloseForQuickCapture();
    if (!mounted || !closed) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (_homeQuickCaptureSheetOpen) return;
      _openHomeQuickCaptureModal();
    });
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
                    dialogTheme.brightness == Brightness.light
                        ? dialogTheme.colorScheme.surface
                        : dialogTheme.colorScheme.surfaceContainerHigh,
                insetPadding:
                    const EdgeInsets.symmetric(horizontal: 28, vertical: 36),
                clipBehavior: Clip.antiAlias,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(20),
                  side: dialogTheme.brightness == Brightness.light
                      ? BorderSide(
                          color: dialogTheme.colorScheme.outlineVariant,
                        )
                      : BorderSide.none,
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
      return 'Example: @Alex please review the budget #finance — add +7d at the end for a due date.';
    }
    if (_pillar == LedgerPillar.addTopic) {
      return 'Example: #weeklymeeting notes @Sam @Alex — or @Sam only for a private note.';
    }
    if (_pillar == LedgerPillar.home) {
      if (_homePendingEntry == _ComposerEntryMode.topic) {
        return 'Choose Save privately or Save publicly (back arrow to re-pick type).';
      }
      if (_homePendingEntry == _ComposerEntryMode.expectation) {
        return 'Choose Save as Draft or Send immediately (back arrow to re-pick type).';
      }
      return 'Type your line. @ and # as needed; expectations need @someone. '
          'Optional deadline: +7d, +1w, or +14 days at the end (stripped when saved). '
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
                  'Use Tab to choose, Enter to insert, or click a match',
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
    final expOk = _expectationCaptureTextIsSubmittable(text);
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

  /// Expectations must @mention a receiver; #tags alone are not enough.
  bool _expectationCaptureTextIsSubmittable(String text) {
    final t = text.trim();
    if (t.isEmpty) return false;
    if (!_talkingPointLineHasPersonMention(t)) return false;
    return _hasContentWord(t);
  }

  /// Talking points / ambiguous capture: need @ or # and real content.
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

  /// Talking point can be saved **publicly**: needs at least one # ( @mentions stay in the text only).
  bool _talkingPointPublicSubmittable(String text) {
    final t = text.trim();
    if (t.isEmpty) return false;
    if (!_hashTagRegex.hasMatch(t)) return false;
    return _hasContentWord(t);
  }

  /// True when the line has an @mention.
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
    if (isExpectationSubmitContext &&
        !_talkingPointLineHasPersonMention(text)) {
      _showComposerToast(
        'Expectations must @mention at least one receiver (e.g. @alice or @alice @bob …).',
      );
      return;
    }
    if (isTalkingPointSubmit && !_hashTagRegex.hasMatch(text)) {
      final colleagueShadowOk =
          forcedTalkingPointVisibility == ExpectationVisibility.shadow &&
              _talkingPointLineHasPersonMention(text) &&
              _hasContentWord(text);
      if (!colleagueShadowOk) {
        _showComposerToast(
          'Talking points need at least one #hashtag to publish publicly, or @person for a private colleague note.',
        );
        return;
      }
    }
    if (!isExpectationSubmitContext && !isTalkingPointSubmit) {
      final hasTag = _atTagRegex.hasMatch(text) || _hashTagRegex.hasMatch(text);
      if (!hasTag) {
        _showComposerToast(
          'Please add @name for someone, or #tag to classify a talking point.',
        );
        return;
      }
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
    final openDetailsAfterCapture = _homeQuickCaptureSheetOpen ||
        _pillar == LedgerPillar.addExpectation ||
        _pillar == LedgerPillar.addTopic;
    _submitInFlight = true;
    _homeComposerUiRevision.value++;
    setState(() {});
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
    final trimmedLine = text.trim();
    final deadlineCmd = _stripCaptureDeadlineSuffix(trimmedLine);
    final captureBody = deadlineCmd.text;
    late final ExpectationVisibility visibilityForResolve;
    if (forcedTalkingPointVisibility != null &&
        entryType == ExpectationType.topic) {
      visibilityForResolve = forcedTalkingPointVisibility;
    } else if (forcedExpectationVisibility != null &&
        entryType == ExpectationType.expectation) {
      visibilityForResolve = forcedExpectationVisibility;
    } else {
      visibilityForResolve = ExpectationVisibility.echo;
    }
    Person? person;
    var shouldAskSubmitMode = true;
    if (entryType == ExpectationType.expectation) {
      shouldAskSubmitMode = false;
      person = await _resolveExpectationReceiversFromCaptureLine(
        captureBody,
        visibility: visibilityForResolve,
      );
      if (person == null) {
        _releaseSubmitInFlight();
        return;
      }
    } else {
      final handle = _extractMentionHandle(text);
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
          final tagOnlyPrivateTalkingPointDraft =
              forcedTalkingPointVisibility ==
                      ExpectationVisibility.shadow &&
                  !_talkingPointLineHasPersonMention(text);
          if (tagOnlyPrivateTalkingPointDraft) {
            shouldAskSubmitMode = false;
          } else {
            shouldAskSubmitMode = false;
            final skipEmailInvite = _talkingPointLineHasPersonMention(text);
            final String? email;
            if (skipEmailInvite) {
              email = null;
            } else {
              email = await _askOptionalEmailForHandle(handle);
              if (email == _cancelToken) {
                _releaseSubmitInFlight();
                return;
              }
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
    }
    final storedText = entryType == ExpectationType.topic
        ? _normalizeTalkingPointTextForStorage(captureBody)
        : _normalizeExpectationTextForStorage(captureBody);
    final parse = parseCaptureLine(captureBody);
    late final ExpectationVisibility visibility;
    if (forcedTalkingPointVisibility != null &&
        entryType == ExpectationType.topic) {
      // Talking points: @mentions live in summary (+ expectation_mentions when echo).
      visibility = forcedTalkingPointVisibility;
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
      final wantsEcho = mode == _ExpectationSubmitMode.inform;
      if (entryType == ExpectationType.topic &&
          wantsEcho &&
          !_hashTagRegex.hasMatch(captureBody)) {
        visibility = ExpectationVisibility.shadow;
      } else {
        visibility = wantsEcho
            ? ExpectationVisibility.echo
            : ExpectationVisibility.shadow;
      }
    }

    final persistTarget = entryType == ExpectationType.topic ? null : person;
    final tempExpectationId = 'exp_${DateTime.now().millisecondsSinceEpoch}';

    setState(() {
      _homeRecent.insert(0, FeedEntry(
        id: 'cap_${DateTime.now().millisecondsSinceEpoch}',
        createdAt: DateTime.now().toUtc(),
        body: captureBody,
        parse: parse,
        linkedExpectationId: persistTarget != null ? tempExpectationId : null,
        isUserCapture: true,
      ));
      _expectations.insert(
        0,
        Expectation(
          id: tempExpectationId,
          createdAt: DateTime.now().toUtc(),
          writerUserId: Supabase.instance.client.auth.currentUser?.id,
          personId: persistTarget?.id ?? '',
          summary: storedText,
          deadlineLabel:
              deadlineCmd.deadlineAt != null ? deadlineCmd.deadlineLabel : 'TBD',
          deadlineAt: deadlineCmd.deadlineAt,
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
        mentionSourceText: captureBody,
        visibility: visibility,
        type: entryType,
        target: persistTarget,
        deadlineAt: deadlineCmd.deadlineAt,
        deadlineLabel: deadlineCmd.deadlineLabel,
      );
      _cacheMentionHandlesAfterPersist(
        expectationId: persistedExpectationId,
        mentionLine: captureBody,
        storedText: storedText,
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
          final i = _expectations.indexWhere((e) => e.id == tempExpectationId);
          if (i >= 0) {
            final old = _expectations[i];
            _expectations[i] = Expectation(
              id: persistedExpectationId,
              createdAt: old.createdAt,
              writerUserId: old.writerUserId,
              personId: old.personId,
              summary: old.summary,
              deadlineLabel: old.deadlineLabel,
              deadlineAt: old.deadlineAt,
              finishedAt: old.finishedAt,
              responsibleUpdatedAt: old.responsibleUpdatedAt,
              publishedAt: old.publishedAt,
              seenAt: old.seenAt,
              lastChattedSenderAt: old.lastChattedSenderAt,
              lastChattedReceiverAt: old.lastChattedReceiverAt,
              updateRequestedAt: old.updateRequestedAt,
              progress: old.progress,
              health: old.health,
              type: old.type,
              status: old.status,
              visibility: old.visibility,
            );
          }
        });
      }
      await _loadExpectationsFromSupabase();
      if (mounted && entryType == ExpectationType.topic) {
        await _loadRecentTagsFromSupabase();
      }
      if (mounted && openDetailsAfterCapture) {
        if (_pillar == LedgerPillar.addExpectation ||
            _pillar == LedgerPillar.addTopic) {
          setState(() {
            _pillar = LedgerPillar.home;
            _homePendingEntry = null;
            _composerMode = _composerDefaultMode;
          });
        }
        _presentNewCaptureDetailsAfterQuickCapture(
          expectationId: persistedExpectationId,
          fallbackPerson: persistTarget,
        );
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _expectations.removeWhere((e) => e.id == tempExpectationId);
          _homeRecent.removeWhere((e) => e.linkedExpectationId == tempExpectationId);
        });
        final msg = e is PostgrestException
            ? 'Could not save to the database: ${e.message}'
            : 'Save failed in the app (not the database): $e';
        _showComposerToast(msg);
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
  static final RegExp _atTagRegex = RegExp(r'@([a-zA-Z0-9._-]+)');
  static final RegExp _hashTagRegex = RegExp(r'#([a-zA-Z0-9._-]+)');
  static final RegExp _allHashTagsRegex = RegExp(r'#([a-zA-Z0-9._-]+)');
  static final RegExp _wordCharRegex = RegExp(r'[a-zA-Z0-9]');
  static final RegExp _uuidRegex = RegExp(
    r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[1-5][0-9a-fA-F]{3}-[89abAB][0-9a-fA-F]{3}-[0-9a-fA-F]{12}$',
  );

  /// True when [id] is a Postgres uuid (not a client-only `exp_<ms>` optimistic id).
  static bool isPersistedExpectationId(String id) =>
      _uuidRegex.hasMatch(id.trim());
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
                      labelText: person != null
                          ? _inviteEmailFieldLabel(person)
                          : 'E-mail',
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

  String _inviteEmailFieldLabel(Person person) {
    final handle = person.handle.trim();
    if (handle.isEmpty) return 'E-mail';
    return 'E-mail of @$handle';
  }

  /// Email for each person (by id) when several receivers still need an address.
  Future<Map<String, String>?> _askInviteEmailsForPeopleDialog(
    List<Person> people,
  ) async {
    if (people.isEmpty) return {};
    final controllers = <String, TextEditingController>{
      for (final p in people)
        p.id: TextEditingController(text: (p.email ?? '').trim()),
    };
    final errors = <String, String?>{for (final p in people) p.id: null};
    String? formError;

    bool validateAndCollect(Map<String, String> out) {
      var hasInvalidNonEmpty = false;
      for (final p in people) {
        final value = controllers[p.id]!.text.trim();
        if (value.isEmpty) {
          errors[p.id] = null;
          continue;
        }
        if (_emailRegex.hasMatch(value)) {
          errors[p.id] = null;
          out[p.id] = value;
        } else {
          hasInvalidNonEmpty = true;
          errors[p.id] = 'Please enter a valid email address.';
        }
      }
      if (out.isEmpty) {
        formError = people.length == 1
            ? 'Enter a valid email to send this invite.'
            : 'Enter at least one valid email. Leave others blank to skip.';
        return false;
      }
      if (hasInvalidNonEmpty) {
        formError = null;
        return false;
      }
      formError = null;
      return true;
    }

    final result = await showDialog<Map<String, String>>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) {
        return StatefulBuilder(
          builder: (context, setLocalState) {
            return AlertDialog(
              title: Text(
                people.length == 1
                    ? 'Invite @${people.first.handle}'
                    : 'Invite ${people.length} people',
              ),
              content: SizedBox(
                width: 420,
                child: SingleChildScrollView(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Text(
                        people.length == 1
                            ? 'Send a personalized invite email for @${people.first.handle}.'
                            : 'Add emails for the receivers you want to invite now. '
                                'Fields are optional except you need at least one valid address.',
                      ),
                      if (formError != null) ...[
                        const SizedBox(height: 10),
                        Text(
                          formError!,
                          style: Theme.of(context).textTheme.bodySmall?.copyWith(
                                color: Theme.of(context).colorScheme.error,
                              ),
                        ),
                      ],
                      const SizedBox(height: 12),
                      for (final p in people) ...[
                        TextField(
                          controller: controllers[p.id],
                          decoration: InputDecoration(
                            labelText: _inviteEmailFieldLabel(p),
                            hintText: 'name@company.com (optional)',
                            errorText: errors[p.id],
                          ),
                          textInputAction: people.last.id == p.id
                              ? TextInputAction.done
                              : TextInputAction.next,
                          onSubmitted: (_) {
                            final out = <String, String>{};
                            if (validateAndCollect(out)) {
                              Navigator.of(dialogContext).pop(out);
                            } else {
                              setLocalState(() {});
                            }
                          },
                        ),
                        if (p != people.last) const SizedBox(height: 10),
                      ],
                    ],
                  ),
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(dialogContext).pop(),
                  child: const Text('Cancel'),
                ),
                FilledButton(
                  onPressed: () {
                    final out = <String, String>{};
                    if (validateAndCollect(out)) {
                      Navigator.of(dialogContext).pop(out);
                    } else {
                      setLocalState(() {});
                    }
                  },
                  child: Text(
                    people.length == 1 ? 'Send invite' : 'Send invites',
                  ),
                ),
              ],
            );
          },
        );
      },
    );

    for (final c in controllers.values) {
      c.dispose();
    }
    return result;
  }

  Future<String> _inviteCompanyIdForCurrentUser() async {
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
    return meRows.first['company_id'] as String;
  }

  Future<String> _createInviteForPerson({
    required String companyId,
    required Person? person,
    required String email,
  }) async {
    final client = Supabase.instance.client;
    final user = client.auth.currentUser;
    if (user == null) {
      throw Exception('No authenticated user.');
    }
    if (person != null) {
      await client.from('people').update({'email': email}).eq('id', person.id);
    }
    final expiresAt =
        DateTime.now().toUtc().add(const Duration(days: 14)).toIso8601String();
    final inviteKind = person == null ? 'generic' : 'personalized:${person.id}';
    final tokenHash =
        '$inviteKind:${DateTime.now().microsecondsSinceEpoch}-${user.id}-${email.toLowerCase()}';
    final row = await client.from('invites').insert({
      'company_id': companyId,
      'email': email,
      'role': 0,
      'status': 0,
      'token_hash': tokenHash,
      'invited_by_user_id': user.id,
      'expires_at': expiresAt,
    }).select('id').single();
    return row['id'] as String;
  }

  Future<bool> _dispatchInviteEmail(String inviteId) async {
    return sendInviteEmailForInviteId(
      client: Supabase.instance.client,
      inviteId: inviteId,
    );
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
      final companyId = await _inviteCompanyIdForCurrentUser();
      final inviteId = await _createInviteForPerson(
        companyId: companyId,
        person: person,
        email: email,
      );
      final emailed = await _dispatchInviteEmail(inviteId);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            emailed
                ? (person == null
                    ? 'Invite email sent to $email.'
                    : 'Invite email sent to @${
                        person.handle
                      } ($email).')
                : (person == null
                    ? 'Invite saved for $email, but the email could not be sent.'
                    : 'Invite saved for @${
                        person.handle
                      }, but the email could not be sent.'),
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

  /// Invite every receiver without an account; prompt for emails only when missing.
  Future<void> _openInviteFlowForReceivers(List<Person> receivers) async {
    final pending = receivers
        .where((p) => (p.authUserId ?? '').trim().isEmpty)
        .toList();
    if (pending.isEmpty) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('All receivers already have accounts.')),
      );
      return;
    }

    final emailsByPersonId = <String, String>{};
    final needsEmailPrompt = <Person>[];
    for (final p in pending) {
      final existing = (p.email ?? '').trim();
      if (existing.isNotEmpty && _emailRegex.hasMatch(existing)) {
        emailsByPersonId[p.id] = existing;
      } else {
        needsEmailPrompt.add(p);
      }
    }

    if (needsEmailPrompt.isNotEmpty) {
      final collected = await _askInviteEmailsForPeopleDialog(needsEmailPrompt);
      if (collected == null) return;
      emailsByPersonId.addAll(collected);
    }

    try {
      final companyId = await _inviteCompanyIdForCurrentUser();
      final sent = <String>[];
      var emailFailures = 0;
      for (final p in pending) {
        final email = emailsByPersonId[p.id]?.trim() ?? '';
        if (!_emailRegex.hasMatch(email)) continue;
        final inviteId = await _createInviteForPerson(
          companyId: companyId,
          person: p,
          email: email,
        );
        final emailed = await _dispatchInviteEmail(inviteId);
        if (!emailed) emailFailures++;
        sent.add('@${p.handle}');
      }
      if (!mounted) return;
      if (sent.isEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('No invites were sent.')),
        );
        return;
      }
      final base = sent.length == 1
          ? 'Invite email sent to ${sent.first}.'
          : 'Invite emails sent to ${sent.join(', ')}.';
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            emailFailures == 0
                ? base
                : '$base ${emailFailures} email(s) could not be delivered.',
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
      if (_captureDeadlineTokenLooksLikeContent(t)) continue;
      if (_wordCharRegex.hasMatch(t)) return true;
    }
    return false;
  }

  /// Trailing ` +7d`, ` +1w`, ` +14 days` (case-insensitive) sets a relative deadline
  /// from **today (UTC calendar)**; stripped from stored summary.
  ({String text, DateTime? deadlineAt, String deadlineLabel})
      _stripCaptureDeadlineSuffix(String trimmedInput) {
    var s = trimmedInput.trim();
    final re = RegExp(
      r'\s+\+(\d+)\s*(w|weeks?|d|days?)\s*$',
      caseSensitive: false,
    );
    final m = re.firstMatch(s);
    if (m == null) {
      return (text: s, deadlineAt: null, deadlineLabel: 'TBD');
    }
    final n = int.tryParse(m.group(1) ?? '') ?? 0;
    if (n < 1 || n > 730) {
      return (text: s, deadlineAt: null, deadlineLabel: 'TBD');
    }
    final unit = (m.group(2) ?? 'd').toLowerCase();
    final calendarDays = unit.startsWith('w') ? n * 7 : n;
    final now = DateTime.now().toUtc();
    final base = DateTime.utc(now.year, now.month, now.day);
    final at = base.add(Duration(days: calendarDays));
    final label = formatDisplayDateOnly(
      DateTime(at.year, at.month, at.day),
      Localizations.localeOf(context),
    );
    final cleaned = s.substring(0, m.start).trimRight();
    return (text: cleaned, deadlineAt: at, deadlineLabel: label);
  }

  /// True if [token] is only a deadline shorthand like `+3d` (not yet stripped).
  bool _captureDeadlineTokenLooksLikeContent(String token) {
    return RegExp(r'^\+\d+(w|weeks?|d|days?)$', caseSensitive: false)
        .hasMatch(token);
  }

  /// Expectations: drop leading @receiver burst (stored on target + mentions); capitalize body.
  String _normalizeExpectationTextForStorage(String input) {
    final trimmed = input.trim();
    if (trimmed.isEmpty) return trimmed;
    var normalized = stripLeadingMentionBurst(trimmed);
    if (normalized.isEmpty) {
      return trimmed;
    }
    final first = normalized[0];
    final upperFirst = first.toUpperCase();
    if (first != upperFirst) {
      normalized = '$upperFirst${normalized.substring(1)}';
    }
    return normalizeHashtagsInText(normalized);
  }

  /// Talking points: strip leading @mention burst (stored in [expectation_mentions]); keep other @/# in body.
  String _normalizeTalkingPointTextForStorage(String input) {
    final trimmed = input.trim();
    if (trimmed.isEmpty) return trimmed;
    var normalized = stripLeadingMentionBurst(trimmed);
    if (normalized.isEmpty) {
      return trimmed;
    }
    final first = normalized[0];
    final upperFirst = first.toUpperCase();
    if (first != upperFirst) {
      normalized = '$upperFirst${normalized.substring(1)}';
    }
    return normalizeHashtagsInText(normalized);
  }

  Future<String> _persistExpectationToSupabase({
    required String text,
    String? mentionSourceText,
    required ExpectationVisibility visibility,
    required ExpectationType type,
    required Person? target,
    DateTime? deadlineAt,
    String deadlineLabel = 'TBD',
  }) async {
    final client = Supabase.instance.client;
    final user = client.auth.currentUser;
    if (user == null) {
      throw Exception('No authenticated user.');
    }

    final meRows = await client
        .from('people')
        .select('id,company_id,display_name,handle')
        .eq('auth_user_id', user.id)
        .limit(1);
    if ((meRows as List).isEmpty) {
      throw Exception('No linked person/company for this user.');
    }
    final meRow = meRows.first as Map<String, dynamic>;
    final companyId = meRow['company_id'] as String;
    final mePersonId = meRow['id'] as String;

    final targetPersonId = (target != null && _uuidRegex.hasMatch(target.id))
        ? target.id
        : null;
    final isPublicTalkingPoint = type == ExpectationType.topic &&
        visibility == ExpectationVisibility.echo;
    final title = text.length > 80 ? '${text.substring(0, 80)}...' : text;

    final labelTrimmed = deadlineLabel.trim();
    final effectiveLabel =
        labelTrimmed.isEmpty || labelTrimmed.toUpperCase() == 'TBD'
            ? 'TBD'
            : labelTrimmed;

    final inserted = await client.from('expectations').insert({
      'company_id': companyId,
      'writer_user_id': user.id,
      'target_person_id': targetPersonId,
      'title': title,
      'summary': text,
      'deadline_label': effectiveLabel,
      'deadline_at': deadlineAt?.toIso8601String(),
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
        .map((m) => normalizeHashtagToken(m.group(1) ?? ''))
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
            .eq('name', tag)
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
    final mentionLine = (mentionSourceText ?? text).trim();
    // Sync @mentions before changelog so activity-email triggers see recipients.
    // Talking points never set target_person_id; recipients come from expectation_mentions only.
    // Shadow + echo: summary strips leading @, so rows must be persisted for every save.
    if (type == ExpectationType.topic) {
      await syncTalkingPointMentions(
        client: client,
        companyId: companyId,
        expectationId: expectationId,
        summary: mentionLine,
        authorPersonId: mePersonId,
        people: _people,
        resolveMe: (_) async {
          return Person(
            id: mePersonId,
            createdAt: DateTime.now().toUtc(),
            displayName: (meRow['display_name'] as String?) ?? '',
            handle: (meRow['handle'] as String?) ?? 'me',
            authUserId: user.id,
          );
        },
        createPlaceholder: (handle) => _createPersonFromHandleInSupabase(handle),
        replaceExisting: true,
      );
    } else {
      await syncExpectationCoReceiverMentions(
        client: client,
        companyId: companyId,
        expectationId: expectationId,
        mentionSourceText: mentionLine.isNotEmpty ? mentionLine : text,
        authorPersonId: mePersonId,
        people: _people,
        resolveMe: (_) async {
          return Person(
            id: mePersonId,
            createdAt: DateTime.now().toUtc(),
            displayName: (meRow['display_name'] as String?) ?? '',
            handle: (meRow['handle'] as String?) ?? 'me',
            authUserId: user.id,
          );
        },
        createPlaceholder: (handle) => _createPersonFromHandleInSupabase(handle),
      );
    }
    final kindWord = type == ExpectationType.topic ? 'talking point' : 'expectation';
    final oneLine = text.trim().replaceAll(RegExp(r'\s+'), ' ');
    final clipped =
        oneLine.length > 160 ? '${oneLine.substring(0, 160)}…' : oneLine;
    try {
      await insertExpectationAppMessage(
        client: client,
        companyId: companyId,
        expectationId: expectationId,
        senderPersonId: mePersonId,
        messageText: 'Created a new $kindWord: $clipped',
        type: kExpectationMessageTypeChangelog,
      );
      await touchExpectationChatActivityForAuthUser(
        client: client,
        expectationId: expectationId,
        expectationWriterUserId: user.id,
      );
    } catch (_) {}
    if (mounted) {
      await _loadRecentTagsFromSupabase();
    }
    return expectationId;
  }

  void _cacheMentionHandlesAfterPersist({
    required String expectationId,
    required String mentionLine,
    required String storedText,
  }) {
    if (!mounted) return;
    try {
      setState(() {
        _setMentionHandlesForExpectation(
          expectationId,
          extractMentionHandlesFromText(
            mentionLine.isNotEmpty ? mentionLine : storedText,
          ),
        );
      });
    } catch (_) {
      // UI cache only — never fail a successful DB save.
    }
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

  static String _dbString(dynamic value, {String fallback = ''}) {
    if (value == null) return fallback;
    if (value is String) return value;
    return value.toString();
  }

  static String? _dbStringOrNull(dynamic value) {
    if (value == null) return null;
    if (value is String) return value;
    return value.toString();
  }

  static int _dbInt(dynamic value, {int fallback = 0}) {
    if (value == null) return fallback;
    if (value is int) return value;
    if (value is num) return value.toInt();
    return int.tryParse('$value') ?? fallback;
  }

  static DateTime? _dbDateTime(dynamic value) {
    final raw = _dbStringOrNull(value);
    if (raw == null || raw.isEmpty) return null;
    return DateTime.tryParse(raw)?.toUtc();
  }

  Expectation _mapSupabaseExpectationRow(Map<String, dynamic> r) {
    final statusIdx = _dbInt(r['expectation_status']);
    final healthIdx = _dbInt(r['expectation_health']);
    final visIdx = _dbInt(r['expectation_visibility']);
    final typeIdx = _dbInt(r['expectation_type']);
    final status = _statusFromDb(statusIdx);
    final health = _healthFromDb(healthIdx);
    final type = _typeFromDb(typeIdx);
    final visibility = (visIdx >= 0 && visIdx < ExpectationVisibility.values.length)
        ? ExpectationVisibility.values[visIdx]
        : ExpectationVisibility.shadow;
    final createdAt = _dbDateTime(r['created_at']) ?? DateTime.now().toUtc();
    final publishedAt = _dbDateTime(r['published_at']) ??
        (visIdx == ExpectationVisibility.echo.index ? createdAt : null);
    return Expectation(
      id: _dbString(r['id']),
      createdAt: createdAt,
      writerUserId: _dbStringOrNull(r['writer_user_id']),
      personId: _dbString(r['target_person_id']),
      summary: _dbString(r['summary']).trim(),
      deadlineLabel: _dbString(r['deadline_label'], fallback: 'TBD').trim(),
      deadlineAt: _dbDateTime(r['deadline_at']),
      finishedAt: _dbDateTime(r['finished_at']),
      responsibleUpdatedAt: _dbDateTime(r['responsible_updated_at']),
      publishedAt: publishedAt,
      seenAt: _dbDateTime(r['seen_at']),
      lastChattedSenderAt: _dbDateTime(r['last_chatted_sender_at']),
      lastChattedReceiverAt: _dbDateTime(r['last_chatted_receiver_at']),
      updateRequestedAt: _dbDateTime(r['update_requested_at']),
      progress: r['progress'] == null ? null : _dbInt(r['progress']),
      health: health,
      type: type,
      status: status,
      visibility: visibility,
    );
  }

  String _authorLabelForExpectation(Expectation e) {
    final uid = e.writerUserId;
    if (uid == null) return 'Someone';
    for (final p in _people) {
      if (p.authUserId == uid) {
        final dn = p.displayName.trim();
        if (dn.isNotEmpty) return dn;
        return '@${p.handle}';
      }
    }
    return 'Someone';
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

  /// First @ on the line is the primary receiver; later @handles become co-receivers on save.
  Future<Person?> _resolveExpectationReceiversFromCaptureLine(
    String captureBody, {
    required ExpectationVisibility visibility,
  }) async {
    final handles = extractMentionHandlesFromText(captureBody);
    if (handles.isEmpty) return null;

    Person? primary;
    for (var i = 0; i < handles.length; i++) {
      final handle = handles[i];
      Person? person;
      if (handle.toLowerCase() == 'me') {
        person = await _resolveCurrentPerson();
        if (person == null && i == 0) {
          _showComposerToast('Could not resolve @me for the current user.');
          return null;
        }
      } else {
        person = _findPersonByHandle(handle);
      }
      if (person == null) {
        final skipEmailInvite = visibility == ExpectationVisibility.shadow;
        String? email;
        if (!skipEmailInvite && i == 0) {
          email = await _askOptionalEmailForHandle(handle);
          if (email == _cancelToken) return null;
        }
        try {
          person = await _createPersonFromHandleInSupabase(
            handle,
            email: i == 0 ? email : null,
          );
        } catch (e) {
          _showComposerToast('Could not create @$handle yet: $e');
          return null;
        }
      }
      if (i == 0) primary = person;
    }
    return primary;
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
      final personId = personRow['id'] as String;
      final expiresAt = DateTime.now()
          .toUtc()
          .add(const Duration(days: 14))
          .toIso8601String();
      final tokenHash =
          'personalized:$personId:${DateTime.now().microsecondsSinceEpoch}-${user.id}-${normalized.toLowerCase()}';
      final inviteRow = await client.from('invites').insert({
        'company_id': companyId,
        'email': normalizedEmail,
        'role': 0,
        'status': 0,
        'token_hash': tokenHash,
        'invited_by_user_id': user.id,
        'expires_at': expiresAt,
      }).select('id').single();
      unawaited(
        _dispatchInviteEmail(inviteRow['id'] as String),
      );
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

  Future<void> _refreshActivityUnreadCount() async {
    final client = Supabase.instance.client;
    final uid = client.auth.currentUser?.id;
    final companyId = _ledgerCompanyId;
    final me = _myPersonId;
    if (uid == null || companyId == null || me == null) {
      if (!mounted) return;
      setState(() {
        _activityUnreadCount = 0;
        _expectationIdsWithChangelogUnread.clear();
        _changelogBellClearedIds.clear();
      });
      return;
    }
    final mentioned = await fetchExpectationsMentioningPerson(
      client: client,
      companyId: companyId,
      myPersonId: me,
      mapRow: _mapSupabaseExpectationRow,
    );
    final mergedExpectations = mergePartyExpectationsWithMentions(
      party: _expectations,
      mentioned: mentioned,
    );
    var party = expectationsPartyForPerson(
      expectations: mergedExpectations,
      authUserId: uid,
      myPersonId: me,
      coReceiverPersonIdsByExpectationId: _mentionPersonIdsByExpectationId,
    );
    try {
      final snap = await computeChangelogUnreadPartySnapshot(
        client: client,
        companyId: companyId,
        authUserId: uid,
        readerPersonId: me,
        partyExpectations: party,
      );
      if (!mounted) return;
      setState(() {
        _activityUnreadCount = snap.unreadMessageCount;
        _expectationIdsWithChangelogUnread
          ..clear()
          ..addAll(snap.expectationIdsWithAnyUnread);
        // Do not wipe optimistic clears: the snapshot can still list this
        // expectation until the read watermark upsert is visible to RLS.
        // Drop a cleared id only once the server agrees it has no unread rows.
        _changelogBellClearedIds.removeWhere(
          (id) => !snap.expectationIdsWithAnyUnread.contains(id),
        );
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _activityUnreadCount = 0;
        _expectationIdsWithChangelogUnread.clear();
        _changelogBellClearedIds.clear();
      });
    }
  }

  Future<void> _handleActivityFeedRowTap(ExpectationActivityFeedItem item) async {
    _dismissActivityFeedOverlay();
    Expectation? match;
    for (final x in _expectations) {
      if (x.id == item.expectationId) {
        match = x;
        break;
      }
    }
    if (match == null) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'That item is not loaded — pull Refresh or reopen the list.',
          ),
        ),
      );
      return;
    }
    Person? p;
    final pid = match.personId.trim();
    if (pid.isNotEmpty) {
      for (final person in _people) {
        if (person.id == pid) {
          p = person;
          break;
        }
      }
    }
    await _openExpectationDetails(e: match, person: p);
  }

  Future<bool> _markActivityExpectationChangelogRead(String expectationId) async {
    final client = Supabase.instance.client;
    final companyId = _ledgerCompanyId;
    final me = _myPersonId;
    if (companyId == null || me == null) return false;
    final synced = await syncExpectationChangelogReadWatermark(
      client: client,
      companyId: companyId,
      expectationId: expectationId,
      readerPersonId: me,
    );
    if (!mounted) return false;
    if (synced) {
      setState(() {
        _changelogBellClearedIds.add(expectationId);
        _expectationIdsWithChangelogUnread.remove(expectationId);
      });
    }
    _activityFeedOverlayEntry?.markNeedsBuild();
    if (mounted) {
      _scheduleChangelogUnreadSnapshotRefresh();
    }
    return synced;
  }

  void _dismissActivityFeedOverlay() {
    if (_activityFeedOverlayEntry == null) return;
    _activityFeedOverlayEntry!.remove();
    _activityFeedOverlayEntry = null;
    if (mounted) {
      unawaited(_refreshActivityUnreadCount());
    }
  }

  Future<void> _toggleActivityFeedPanel() async {
    if (_activityFeedOverlayEntry != null) {
      _dismissActivityFeedOverlay();
      return;
    }
    final client = Supabase.instance.client;
    final uid = client.auth.currentUser?.id;
    final companyId = _ledgerCompanyId;
    final me = _myPersonId;
    if (uid == null || companyId == null || me == null) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Sign in and link a profile to see activity.')),
      );
      return;
    }
    final mentioned = await fetchExpectationsMentioningPerson(
      client: client,
      companyId: companyId,
      myPersonId: me,
      mapRow: _mapSupabaseExpectationRow,
    );
    final mergedExpectations = mergePartyExpectationsWithMentions(
      party: _expectations,
      mentioned: mentioned,
    );
    final party = expectationsPartyForPerson(
      expectations: mergedExpectations,
      authUserId: uid,
      myPersonId: me,
      coReceiverPersonIdsByExpectationId: _mentionPersonIdsByExpectationId,
    );
    if (!mounted) return;
    final anchorContext = _activityBellAnchorKey.currentContext;
    final renderObject = anchorContext?.findRenderObject();
    if (renderObject is! RenderBox || !renderObject.hasSize) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Could not position activity panel.')),
      );
      return;
    }
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final box = renderObject;
    final origin = box.localToGlobal(Offset.zero);
    final bellSize = box.size;
    final media = MediaQuery.of(context);
    final screenW = media.size.width;
    final screenH = media.size.height;
    const margin = 8.0;
    const gapBelowBell = 6.0;
    final panelWidth = min(440.0, screenW - margin * 2);
    final bellRight = origin.dx + bellSize.width;
    var left = bellRight - panelWidth;
    if (left < margin) left = margin;
    if (left + panelWidth > screenW - margin) {
      left = screenW - margin - panelWidth;
    }
    final top = origin.dy + bellSize.height + gapBelowBell;
    final bottomSafe = media.padding.bottom + margin;
    final maxPanelHeight = min(420.0, screenH - top - bottomSafe).clamp(160.0, 520.0);

    _activityFeedOverlayEntry = OverlayEntry(
      builder: (overlayContext) {
        return Stack(
          children: [
            Positioned.fill(
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: _dismissActivityFeedOverlay,
                child: const ColoredBox(color: Color(0x33000000)),
              ),
            ),
            Positioned(
              left: left,
              top: top,
              width: panelWidth,
              child: Material(
                elevation: 12,
                shadowColor: Colors.black45,
                color: scheme.surfaceContainerHigh,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                  side: BorderSide(color: scheme.outlineVariant.withValues(alpha: 0.5)),
                ),
                clipBehavior: Clip.antiAlias,
                child: SizedBox(
                  height: maxPanelHeight,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Padding(
                        padding: const EdgeInsets.fromLTRB(16, 12, 8, 4),
                        child: Row(
                          children: [
                            Expanded(
                              child: Text(
                                'Activity',
                                style: theme.textTheme.titleMedium?.copyWith(
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                            ),
                            IconButton(
                              tooltip: 'Close',
                              visualDensity: VisualDensity.compact,
                              onPressed: _dismissActivityFeedOverlay,
                              icon: const Icon(Icons.close, size: 20),
                            ),
                          ],
                        ),
                      ),
                      Padding(
                        padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                        child: Text(
                          'Changelog and @mentions on public talking points. '
                          'Tap a row to open; use the check to mark changelog as read.',
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: scheme.onSurfaceVariant,
                          ),
                        ),
                      ),
                      const Divider(height: 1),
                      Expanded(
                        child: _ChangelogActivityFeedList(
                          theme: theme,
                          scheme: scheme,
                          client: client,
                          companyId: companyId,
                          authUserId: uid,
                          readerPersonId: me,
                          myPersonId: me,
                          partyExpectations: party,
                          authorLabelForExpectation: _authorLabelForExpectation,
                          onRowTap: _handleActivityFeedRowTap,
                          onMarkExpectationRead: _markActivityExpectationChangelogRead,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ],
        );
      },
    );
    if (!mounted) return;
    Overlay.of(context).insert(_activityFeedOverlayEntry!);
  }

  /// Re-fetch changelog unread snapshot (debounced slightly so DB read follows upsert).
  void _scheduleChangelogUnreadSnapshotRefresh() {
    Future<void>.delayed(const Duration(milliseconds: 500), () {
      if (mounted) unawaited(_refreshActivityUnreadCount());
    });
  }

  Expectation? _expectationById(String id) {
    for (final e in _expectations) {
      if (e.id == id) return e;
    }
    return null;
  }

  Person? _personForExpectation(Expectation e, {Person? fallback}) {
    final pid = e.personId.trim();
    if (pid.isNotEmpty) {
      for (final p in _people) {
        if (p.id == pid) return p;
      }
    }
    return fallback;
  }

  /// After capture saves (Quick Capture modal or Add expectation/talking point), close
  /// any sheet and open the new item's detail dialog.
  void _presentNewCaptureDetailsAfterQuickCapture({
    required String expectationId,
    Person? fallbackPerson,
  }) {
    if (_homeQuickCaptureSheetOpen) {
      Navigator.of(context).maybePop();
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      unawaited(
        _openCapturedExpectationDetails(
          expectationId: expectationId,
          fallbackPerson: fallbackPerson,
        ),
      );
    });
  }

  Future<void> _openCapturedExpectationDetails({
    required String expectationId,
    Person? fallbackPerson,
  }) async {
    if (!isPersistedExpectationId(expectationId)) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'Still saving this item — try again in a moment from the list.',
          ),
        ),
      );
      return;
    }
    Expectation? e = _expectationById(expectationId);
    if (e == null) {
      await _loadExpectationsFromSupabase();
      if (!mounted) return;
      e = _expectationById(expectationId);
    }
    if (e == null || !isPersistedExpectationId(e.id)) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Could not open details — refresh the list and try again.'),
        ),
      );
      return;
    }
    await _openExpectationDetails(
      e: e,
      person: _personForExpectation(e, fallback: fallbackPerson),
    );
  }

  Future<void> _openExpectationDetails({
    required Expectation e,
    required Person? person,
  }) async {
    if (!isPersistedExpectationId(e.id)) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'This item is not saved yet — wait for sync or pull to refresh.',
          ),
        ),
      );
      return;
    }
    final client = Supabase.instance.client;
    final uid = client.auth.currentUser?.id;
    if (mounted) {
      setState(() {
        _changelogBellClearedIds.add(e.id);
        _expectationIdsWithChangelogUnread.remove(e.id);
        if (uid != null) {
          _optimisticallyMarkExpectationChatCaughtUp(e.id, uid);
        }
      });
    }
    if (uid != null) {
      try {
        await touchExpectationChatActivityForAuthUser(
          client: client,
          expectationId: e.id,
          expectationWriterUserId: e.writerUserId,
        );
      } catch (_) {}
    }
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
              key: _expectationDetailsPanelKey,
              expectation: e,
              person: person,
              talkingPointPersistedMentions: _persistedMentionHandles(e),
              coReceiverPersonIds:
                  _mentionPersonIdsByExpectationId[e.id] ?? const {},
              receiverPeople: _receiverPeopleForExpectation(e),
              canEdit: _canEditExpectationForUser(
                e,
                uid,
                _myPersonId,
              ),
              onInviteReceivers: _openInviteFlowForReceivers,
              onChangelogReadSynced: _scheduleChangelogUnreadSnapshotRefresh,
              onExpectationDataMutated: () {
                unawaited(_loadExpectationsFromSupabase());
                _scheduleChangelogUnreadSnapshotRefresh();
              },
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
        title: Text(
          supabaseIsLeamDevHost ? 'exled · dev' : 'exled',
          overflow: TextOverflow.ellipsis,
        ),
        actions: [
          DebugMenuButton(
            activityUnreadCount: _activityUnreadCount,
            onReloadExpectations: () async {
              await _loadExpectationsFromSupabase();
              await _refreshActivityUnreadCount();
            },
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 8),
            child: FilledButton.tonalIcon(
              onPressed: _openHomeQuickCaptureModal,
              icon: const Icon(Icons.post_add_outlined, size: 20),
              label: const Text('Quick Capture'),
              style: FilledButton.styleFrom(
                visualDensity: VisualDensity.compact,
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.only(right: 2),
            key: _activityBellAnchorKey,
            child: Stack(
              clipBehavior: Clip.none,
              children: [
                IconButton(
                  tooltip: 'Activity feed',
                  onPressed: _toggleActivityFeedPanel,
                  icon: const Icon(Icons.notifications_outlined),
                ),
                if (_activityUnreadCount > 0)
                  Positioned(
                    right: 4,
                    top: 4,
                    child: IgnorePointer(
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
                        decoration: BoxDecoration(
                          color: scheme.error,
                          borderRadius: BorderRadius.circular(10),
                        ),
                        constraints: const BoxConstraints(minWidth: 16, minHeight: 16),
                        child: Text(
                          _activityUnreadCount > 99 ? '99+' : '$_activityUnreadCount',
                          style: theme.textTheme.labelSmall?.copyWith(
                            color: scheme.onError,
                            fontWeight: FontWeight.w600,
                            fontSize: 10,
                          ),
                          textAlign: TextAlign.center,
                        ),
                      ),
                    ),
                  ),
              ],
            ),
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
                publicRailMentions: _publicRailMentionHandlesFromExpectations(),
                onPublicRailMention: _openPublicMentionPillar,
                privateRailTags: _privateRailTagsFromExpectations(),
                onPrivateRailTag: _onPrivateRailTagSelect,
                privateRailMentions: _privateRailMentionHandlesFromExpectations(),
                onPrivateRailMention: _openPrivateMentionColleagues,
                selectedPrivateMentionHandle: _colleagueMentionFilterHandle,
                tagsLoading: _tagsLoading,
                tagsLoadError: _tagsLoadError,
                onRetryTags: () {
                  _loadRecentTagsFromSupabase();
                },
                talkingPointsSubView: _talkingPointsSubView,
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
                      _colleagueMentionFilterHandle = null;
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
                      if (_pillar != LedgerPillar.home) ...[
                        Padding(
                          padding: EdgeInsets.symmetric(
                            horizontal:
                                (_pillar == LedgerPillar.expectationsMe ||
                                        _pillar ==
                                            LedgerPillar.expectationsOthers)
                                    ? 24
                                    : 0,
                          ),
                          child: _PillarHeader(pillar: _pillar, theme: theme),
                        ),
                        const SizedBox(height: _kPillarHeaderTrailingGap),
                      ],
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
                                  _expectationCaptureTextIsSubmittable(
                                value.text,
                              );
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
                                ? const EdgeInsets.fromLTRB(28, 24, 28, 52)
                                : (_pillar == LedgerPillar.expectationsMe ||
                                        _pillar ==
                                            LedgerPillar.expectationsOthers)
                                    ? const EdgeInsets.fromLTRB(24, 8, 24, 32)
                                    : const EdgeInsets.fromLTRB(0, 4, 12, 16),
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
        out.add(
          _HomeDashboardPanel(
            theme: theme,
            scheme: scheme,
            displayName: _profileName,
            companyName: _companyName,
            expectations: expectations,
            people: people,
            mePerson: mePerson,
            currentUserId: Supabase.instance.client.auth.currentUser?.id,
            peopleById: peopleById,
            mentionHandlesByExpectationId: _mentionHandlesByExpectationId,
            mentionPersonIdsByExpectationId: _mentionPersonIdsByExpectationId,
            hasUnreadChat: _hasUnreadListingIndicator,
            activityUnreadCount: _activityUnreadCount,
            onOpenActivityFeed: _toggleActivityFeedPanel,
            onOpenItem: onOpenExpectationDetails,
            onOpenColleaguesPage: () {
              setState(() => _pillar = LedgerPillar.people);
            },
          ),
        );
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
              hasUnreadChat: _hasUnreadListingIndicator(x),
              onTagPressed: _openTagPillar,
              onDelete: () => _deleteExpectationFromList(x),
              onOpenDetails: () => onOpenExpectationDetails(x, peopleById[x.personId]),
              composerRecentListing: true,
              talkingPointPersistedMentions: _persistedMentionHandles(x),
              peopleById: peopleById,
              coReceiverPersonIds:
                  _mentionPersonIdsByExpectationId[x.id] ?? const {},
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
        // All of your private talking points (shadow topics). The @ rail cloud
        // surfaces people cited in the summary; the listing includes #tag-only lines too.
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
        final publicTagged = expectations.where((x) {
          if (x.visibility != ExpectationVisibility.echo) return false;
          if (x.type != ExpectationType.topic) return false;
          return _extractInlineTags(x.summary).isNotEmpty ||
              extractMentionHandlesFromText(x.summary).isNotEmpty;
        }).toList();
        final availableTags = publicTagged
            .expand((e) => _extractInlineTags(e.summary))
            .map((t) => t.toLowerCase())
            .toSet()
            .toList()
          ..sort();
        final publicTagNeedle = _tagFilterNeedle(_tagsSelectedTag);
        final publicTagDropdownValue =
            _tagFilterDropdownValue(_tagsSelectedTag, availableTags);
        final publicTagDropdownItems =
            _tagFilterDropdownItems(availableTags, _tagsSelectedTag);
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
        final privateTagNeedle = _tagFilterNeedle(_tagsSelectedTag);
        final privateTagDropdownValue =
            _tagFilterDropdownValue(_tagsSelectedTag, availablePrivateTags);
        final privateTagDropdownItems =
            _tagFilterDropdownItems(availablePrivateTags, _tagsSelectedTag);

        if (_talkingPointsSubView == _TalkingPointsSubView.meetingsOrTags) {
          out.add(
            Padding(
              padding: _listingToolbarPadding,
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  const Spacer(),
                  _ExpectationsOthersFiltersBar(
                    showStatus: false,
                    showTag: true,
                    showPerson: false,
                    selectedStatus: null,
                    selectedTag: publicTagDropdownValue,
                    selectedPersonId: null,
                    tags: publicTagDropdownItems,
                    people: const [],
                    tagFieldWidth: 240,
                    onStatusChanged: (_) {},
                    onTagChanged: (v) {
                      setState(() {
                        _tagsSelectedTag = v;
                        _publicMentionFilterHandle = null;
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
                padding: _listingToolbarPadding,
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    const Spacer(),
                    _ExpectationsOthersFiltersBar(
                      showStatus: false,
                      showTag: true,
                      showPerson: false,
                      selectedStatus: null,
                      selectedTag: privateTagDropdownValue,
                      selectedPersonId: null,
                      tags: privateTagDropdownItems,
                      people: const [],
                      tagFieldWidth: 240,
                      onStatusChanged: (_) {},
                      onTagChanged: (v) {
                        setState(() {
                          _tagsSelectedTag = v;
                          _colleagueMentionFilterHandle = null;
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
            final mentionFilter = _colleagueMentionFilterHandle?.trim().toLowerCase();
            var filtered = mentionFilter != null && mentionFilter.isNotEmpty
                ? colleagueTopics
                    .where((x) => _talkingPointMentionsHandle(x, mentionFilter))
                    .toList()
                : colleagueTopics;
            if (privateTagNeedle != null) {
              filtered = filtered
                  .where(
                    (x) => _extractInlineTags(x.summary)
                        .map((t) => t.toLowerCase())
                        .contains(privateTagNeedle),
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
                emptyText: mentionFilter == null
                    ? 'No active private talking points yet.'
                    : 'No active private talking points mentioning @$mentionFilter.',
                items: activeColleague,
                peopleById: peopleById,
                theme: theme,
                scheme: scheme,
                collapsed: false,
                hasUnreadChat: _hasUnreadListingIndicator,
                onTagPressed: _openTagPillar,
                onOpenDetails: (e, p) => onOpenExpectationDetails(e, p),
                onDeleteExpectation: _deleteExpectationFromList,
                onToggleCollapsed: () {},
                personForItem: (_) => null,
                talkingPointsBrowseListing: true,
                talkingPointMentionHandlesById:
                    _mentionHandlesByExpectationId,
                onArchiveTalkingPoint: _archiveTalkingPointBrowse,
                onPublishTalkingPoint: _publishTalkingPointBrowse,
              ),
            );
            out.add(const SizedBox(height: 12));
            out.add(
              _ExpectationsOthersSection(
                title: 'Archive',
                emptyText: mentionFilter == null
                    ? 'No archived private talking points yet.'
                    : 'No archived private talking points mentioning @$mentionFilter.',
                items: archiveColleague,
                peopleById: peopleById,
                theme: theme,
                scheme: scheme,
                collapsed: _colleagueArchiveCollapsed,
                hasUnreadChat: _hasUnreadListingIndicator,
                onTagPressed: _openTagPillar,
                onOpenDetails: (e, p) => onOpenExpectationDetails(e, p),
                onDeleteExpectation: _deleteExpectationFromList,
                onToggleCollapsed: () {
                  setState(() {
                    _colleagueArchiveCollapsed = !_colleagueArchiveCollapsed;
                  });
                },
                personForItem: (_) => null,
                talkingPointsBrowseListing: true,
                talkingPointMentionHandlesById:
                    _mentionHandlesByExpectationId,
                onArchiveTalkingPoint: _archiveTalkingPointBrowse,
                onPublishTalkingPoint: _publishTalkingPointBrowse,
              ),
            );
          break;
        }
        // Public (#tags, echo)
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
          final publicTagDisplay =
              publicTagDropdownValue ?? publicTagNeedle;
          final mentionFilter = _publicMentionFilterHandle;
          final filtered = publicTagged.where((x) {
            if (publicTagNeedle != null) {
              return _extractInlineTags(x.summary)
                  .map((t) => t.toLowerCase())
                  .contains(publicTagNeedle);
            }
            if (mentionFilter != null && mentionFilter.isNotEmpty) {
              return _talkingPointMentionsHandle(x, mentionFilter);
            }
            return true;
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
              emptyText: publicTagNeedle == null && mentionFilter == null
                  ? 'No published talking points yet.'
                  : mentionFilter != null
                      ? 'No active talking points mentioning @$mentionFilter.'
                      : 'No active talking points for #$publicTagDisplay.',
              items: inflow,
              peopleById: peopleById,
              theme: theme,
              scheme: scheme,
              collapsed: false,
              hasUnreadChat: _hasUnreadListingIndicator,
              onTagPressed: _openTagPillar,
              onOpenDetails: (e, p) => _openExpectationDetails(e: e, person: p),
              onDeleteExpectation: _deleteExpectationFromList,
              onToggleCollapsed: () {},
              personForItem: (_) => null,
              talkingPointsBrowseListing: true,
              talkingPointMentionHandlesById:
                  _mentionHandlesByExpectationId,
              onArchiveTalkingPoint: _archiveTalkingPointBrowse,
              onPublishTalkingPoint: _publishTalkingPointBrowse,
            ),
          );
          out.add(const SizedBox(height: 12));
          out.add(
            _ExpectationsOthersSection(
              title: 'Archive',
              emptyText: publicTagNeedle == null && mentionFilter == null
                  ? 'No archived published talking points.'
                  : mentionFilter != null
                      ? 'No archive for @$mentionFilter.'
                      : 'No archive for #$publicTagDisplay.',
              items: archive,
              peopleById: peopleById,
              theme: theme,
              scheme: scheme,
              collapsed: _tagsArchiveCollapsed,
              hasUnreadChat: _hasUnreadListingIndicator,
              onTagPressed: _openTagPillar,
              onOpenDetails: (e, p) => _openExpectationDetails(e: e, person: p),
              onDeleteExpectation: _deleteExpectationFromList,
              onToggleCollapsed: () {
                setState(() => _tagsArchiveCollapsed = !_tagsArchiveCollapsed);
              },
              personForItem: (_) => null,
              talkingPointsBrowseListing: true,
              talkingPointMentionHandlesById:
                  _mentionHandlesByExpectationId,
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
                    x.type == ExpectationType.expectation &&
                    _isExpectationReceiver(x, mePerson.id),
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
          final inboxTagNeedle = _tagFilterNeedle(_inboxTagFilter);
          final inboxTagDropdownValue =
              _tagFilterDropdownValue(_inboxTagFilter, availableTags);
          final inboxTagDropdownItems =
              _tagFilterDropdownItems(availableTags, _inboxTagFilter);
          final filteredTowardsMe = towardsMeForTab.where((x) {
            final statusMatch =
                _inboxStatusFilter == null || x.status == _inboxStatusFilter;
            final tagMatch = inboxTagNeedle == null
                ? true
                : _extractInlineTags(x.summary)
                      .map((t) => t.toLowerCase())
                      .contains(inboxTagNeedle);
            return statusMatch && tagMatch;
          }).toList();
          out.add(
            Padding(
              padding: _listingToolbarPadding,
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  SegmentedButton<_InboxListingTab>(
                    style: SegmentedButton.styleFrom(
                      visualDensity: VisualDensity.compact,
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 12),
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
                  Expanded(
                    child: Align(
                      alignment: Alignment.centerRight,
                      child: SingleChildScrollView(
                        scrollDirection: Axis.horizontal,
                        reverse: true,
                        padding: const EdgeInsets.only(left: 8),
                        child: _ExpectationsOthersFiltersBar(
                          showPerson: false,
                          selectedStatus: _inboxStatusFilter,
                          selectedTag: inboxTagDropdownValue,
                          selectedPersonId: null,
                          tags: inboxTagDropdownItems,
                          people: const [],
                          onStatusChanged: (v) {
                            setState(() => _inboxStatusFilter = v);
                          },
                          onTagChanged: (v) {
                            setState(() => _inboxTagFilter = v);
                          },
                          onPersonChanged: (_) {},
                        ),
                      ),
                    ),
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
              hasUnreadChat: _hasUnreadListingIndicator,
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
              mentionPersonIdsByExpectationId: _mentionPersonIdsByExpectationId,
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
                hasUnreadChat: _hasUnreadListingIndicator,
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
                mentionPersonIdsByExpectationId: _mentionPersonIdsByExpectationId,
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
              hasUnreadChat: _hasUnreadListingIndicator,
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
        final othersTagNeedle = _tagFilterNeedle(_othersTagFilter);
        final othersTagDropdownValue =
            _tagFilterDropdownValue(_othersTagFilter, availableTags);
        final othersTagDropdownItems =
            _tagFilterDropdownItems(availableTags, _othersTagFilter);
        final effectivePersonFilter = personOptions.any((p) => p.id == _othersPersonFilter)
            ? _othersPersonFilter
            : null;
        final filteredTowardsOthers = towardsOthers.where((x) {
          final statusMatch =
              _othersStatusFilter == null || x.status == _othersStatusFilter;
          final tagMatch = othersTagNeedle == null
              ? true
              : _extractInlineTags(x.summary)
                    .map((t) => t.toLowerCase())
                    .contains(othersTagNeedle);
          final personMatch =
              effectivePersonFilter == null || x.personId == effectivePersonFilter;
          return statusMatch && tagMatch && personMatch;
        }).toList();
        out.add(
          Padding(
            padding: _listingToolbarPadding,
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                SegmentedButton<_OutboxListingTab>(
                  style: SegmentedButton.styleFrom(
                    visualDensity: VisualDensity.compact,
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 12),
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
                Expanded(
                  child: Align(
                    alignment: Alignment.centerRight,
                    child: SingleChildScrollView(
                      scrollDirection: Axis.horizontal,
                      reverse: true,
                      padding: const EdgeInsets.only(left: 8),
                      child: _ExpectationsOthersFiltersBar(
                        selectedStatus: _othersStatusFilter,
                        selectedTag: othersTagDropdownValue,
                        selectedPersonId: effectivePersonFilter,
                        tags: othersTagDropdownItems,
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
                    ),
                  ),
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
              hasUnreadChat: _hasUnreadListingIndicator,
              onTagPressed: _applyOutboxTagFilter,
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
              hasUnreadChat: _hasUnreadListingIndicator,
              onTagPressed: _applyOutboxTagFilter,
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
              hasUnreadChat: _hasUnreadListingIndicator,
              onTagPressed: _applyOutboxTagFilter,
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
                hasUnreadChat: _hasUnreadListingIndicator,
                onTagPressed: _applyOutboxTagFilter,
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
              hasUnreadChat: _hasUnreadListingIndicator,
              onTagPressed: _applyOutboxTagFilter,
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

class _PillarRail extends StatelessWidget {
  const _PillarRail({
    required this.expanded,
    required this.selected,
    required this.recentTags,
    required this.recentTagsHasMore,
    required this.publicRailMentions,
    required this.onPublicRailMention,
    required this.privateRailTags,
    required this.onPrivateRailTag,
    required this.privateRailMentions,
    required this.onPrivateRailMention,
    required this.selectedPrivateMentionHandle,
    required this.tagsLoading,
    required this.tagsLoadError,
    required this.onRetryTags,
    required this.talkingPointsSubView,
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
  /// Aligns heading —+— with [ListTile] trailing (see Talking points tile [contentPadding]).
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
  final List<String> publicRailMentions;
  final ValueChanged<String> onPublicRailMention;
  final List<String> privateRailTags;
  final ValueChanged<String> onPrivateRailTag;
  final List<String> privateRailMentions;
  final ValueChanged<String> onPrivateRailMention;
  final String? selectedPrivateMentionHandle;
  final bool tagsLoading;
  final String? tagsLoadError;
  final VoidCallback onRetryTags;
  final _TalkingPointsSubView talkingPointsSubView;
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
    final privateMentionRailChild = privateRailMentions.isEmpty
        ? const SizedBox.shrink()
        : Wrap(
            alignment: WrapAlignment.start,
            spacing: 6,
            runSpacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              for (final handle in privateRailMentions)
                LedgerTagChip(
                  tag: handle,
                  tokenPrefix: '@',
                  unselectedLabelColor: LedgerListingAccents.topic,
                  selected: selectedPrivateMentionHandle ==
                      handle.toLowerCase(),
                  selectionAccent: LedgerListingAccents.topic,
                  onPressed: () => onPrivateRailMention(handle),
                ),
            ],
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
                      title: const Text('Welcome'),
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
                    const SizedBox(height: 4),
                    ListTile(
                      dense: true,
                      contentPadding: const EdgeInsets.fromLTRB(20, 10, 12, 6),
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
                    if (privateRailMentions.isNotEmpty ||
                        privateRailTags.isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.fromLTRB(12, 4, 12, 18),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            if (privateRailMentions.isNotEmpty)
                              privateMentionRailChild,
                            if (privateRailMentions.isNotEmpty &&
                                privateRailTags.isNotEmpty)
                              const SizedBox(height: 10),
                            if (privateRailTags.isNotEmpty)
                              Wrap(
                                spacing: 6,
                                runSpacing: 8,
                                crossAxisAlignment: WrapCrossAlignment.center,
                                children: [
                                  for (final tag in privateRailTags)
                                    LedgerTagChip(
                                      tag: tag,
                                      onPressed: () => onPrivateRailTag(tag),
                                    ),
                                ],
                              ),
                          ],
                        ),
                      ),
                    ListTile(
                      dense: true,
                      contentPadding: const EdgeInsets.fromLTRB(20, 8, 12, 6),
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
                      padding: const EdgeInsets.fromLTRB(12, 6, 12, 14),
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
                          : (recentTags.isNotEmpty ||
                              publicRailMentions.isNotEmpty ||
                              recentTagsHasMore)
                          ? Wrap(
                              spacing: 6,
                              runSpacing: 8,
                              crossAxisAlignment: WrapCrossAlignment.center,
                              children: [
                                for (final handle in publicRailMentions)
                                  LedgerTagChip(
                                    tag: handle,
                                    tokenPrefix: '@',
                                    unselectedLabelColor:
                                        LedgerListingAccents.topic,
                                    onPressed: () => onPublicRailMention(handle),
                                  ),
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

  /// Filled circle with —+—; used for Expectations and Talking points headings.
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
    final desc = p.description.trim();
    return Tooltip(
      message: desc.isEmpty ? tipTitle : '$tipTitle\n$desc',
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
                  ledgerPersonInitialLetter(
                    ledgerAtMentionLine(
                      person.displayName.trim().isNotEmpty
                          ? person.displayName
                          : person.handle,
                    ),
                  ),
                  style: TextStyle(color: scheme.onSurface),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      ledgerAtMentionLine(
                        person.displayName.trim().isNotEmpty
                            ? person.displayName
                            : person.handle,
                      ),
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

/// Bell overlay: loads changelog rows once, then **removes every row for an expectation** after a
/// successful mark-read for that expectation (matches the per-expectation read watermark).
class _ChangelogActivityFeedList extends StatefulWidget {
  const _ChangelogActivityFeedList({
    super.key,
    required this.theme,
    required this.scheme,
    required this.client,
    required this.companyId,
    required this.authUserId,
    required this.readerPersonId,
    required this.myPersonId,
    required this.partyExpectations,
    required this.authorLabelForExpectation,
    required this.onRowTap,
    required this.onMarkExpectationRead,
  });

  final ThemeData theme;
  final ColorScheme scheme;
  final SupabaseClient client;
  final String companyId;
  final String authUserId;
  final String readerPersonId;
  final String myPersonId;
  final List<Expectation> partyExpectations;
  final String Function(Expectation expectation) authorLabelForExpectation;
  final Future<void> Function(ExpectationActivityFeedItem item) onRowTap;
  final Future<bool> Function(String expectationId) onMarkExpectationRead;

  @override
  State<_ChangelogActivityFeedList> createState() => _ChangelogActivityFeedListState();
}

class _ChangelogActivityFeedListState extends State<_ChangelogActivityFeedList> {
  List<ExpectationActivityFeedItem>? _items;
  bool _loading = true;
  Object? _error;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    try {
      final changelog = await loadChangelogActivityFeed(
        client: widget.client,
        companyId: widget.companyId,
        authUserId: widget.authUserId,
        readerPersonId: widget.readerPersonId,
        partyExpectations: widget.partyExpectations,
        limit: 80,
      );
      final mentions = await loadTalkingPointMentionActivityFeed(
        client: widget.client,
        companyId: widget.companyId,
        readerPersonId: widget.readerPersonId,
        partyExpectations: widget.partyExpectations,
        authorLabel: widget.authorLabelForExpectation,
        limit: 40,
      );
      final merged = [...changelog, ...mentions]
        ..sort((a, b) => b.createdAt.compareTo(a.createdAt));
      if (!mounted) return;
      setState(() {
        _items = merged.take(80).toList();
        _loading = false;
        _error = null;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e;
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(24),
          child: CircularProgressIndicator(),
        ),
      );
    }
    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Text(
            'Could not load activity.',
            style: widget.theme.textTheme.bodyMedium?.copyWith(
              color: widget.scheme.error,
            ),
          ),
        ),
      );
    }
    final items = _items ?? const <ExpectationActivityFeedItem>[];
    if (items.isEmpty) {
      return Center(
        child: Text(
          'No activity yet.',
          style: widget.theme.textTheme.bodyMedium?.copyWith(
            color: widget.scheme.onSurfaceVariant,
          ),
        ),
      );
    }
    return ListView.builder(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 10),
      itemCount: items.length,
      itemBuilder: (context, i) {
        final item = items[i];
        final mine = item.senderPersonId == widget.myPersonId;
        final atSender = _expectationBubbleAtSenderLabel(item.senderLabel);
        final labelLine =
            'Activity · $atSender · ${_chatRelativeLabel(item.createdAt)}';
        return Padding(
          padding: EdgeInsets.only(
            bottom: i < items.length - 1 ? 10 : 0,
          ),
          child: _ActivityFeedBubbleTile(
            theme: widget.theme,
            scheme: widget.scheme,
            item: item,
            mine: mine,
            labelLine: labelLine,
            onRowTap: () => widget.onRowTap(item),
            onMarkRead: () async {
              final ok = await widget.onMarkExpectationRead(item.expectationId);
              if (ok && mounted) {
                setState(() {
                  _items!.removeWhere((e) => e.expectationId == item.expectationId);
                });
              }
              return ok;
            },
          ),
        );
      },
    );
  }
}

/// Activity feed row: tap the bubble to open the item; tap the **check** control to mark that
/// expectation's changelog read. Hover shows a local **Mark as read** label (not [Tooltip], so it
/// stays aligned inside the bell overlay).
class _ActivityFeedBubbleTile extends StatefulWidget {
  const _ActivityFeedBubbleTile({
    super.key,
    required this.theme,
    required this.scheme,
    required this.item,
    required this.mine,
    required this.labelLine,
    required this.onRowTap,
    required this.onMarkRead,
  });

  final ThemeData theme;
  final ColorScheme scheme;
  final ExpectationActivityFeedItem item;
  final bool mine;
  final String labelLine;
  final VoidCallback onRowTap;
  final Future<bool> Function() onMarkRead;

  @override
  State<_ActivityFeedBubbleTile> createState() => _ActivityFeedBubbleTileState();
}

class _ActivityFeedBubbleTileState extends State<_ActivityFeedBubbleTile> {
  bool _markBusy = false;
  bool _markReadHover = false;

  Future<void> _onMarkReadTap() async {
    if (_markBusy) return;
    setState(() => _markBusy = true);
    try {
      await widget.onMarkRead();
    } finally {
      if (mounted) setState(() => _markBusy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = widget.theme;
    final scheme = widget.scheme;
    final item = widget.item;
    final mine = widget.mine;
    final labelStyle = theme.textTheme.labelSmall?.copyWith(
      color: scheme.onSurfaceVariant,
      fontWeight: FontWeight.w600,
    );
    final bodyStyle = theme.textTheme.bodySmall?.copyWith(
      color: scheme.onSurface,
      height: 1.35,
    );
    final contextBaseStyle = theme.textTheme.bodySmall?.copyWith(
          color: scheme.onSurfaceVariant,
          height: 1.25,
          fontSize: (theme.textTheme.bodySmall?.fontSize ?? 12) - 0.5,
        ) ??
        TextStyle(
          color: scheme.onSurfaceVariant,
          height: 1.25,
          fontSize: (theme.textTheme.bodySmall?.fontSize ?? 12) - 0.5,
        );
    final displayBody = item.messageText.trim();
    final contextPrefix = '${item.kindLabel} · ';
    const maxContextChars = 90;
    final snippetBudget =
        (maxContextChars - contextPrefix.length - 2).clamp(16, 120);
    final quotedSnippet =
        '"${activityFeedEllipsis(item.expectationSummarySnippet, snippetBudget)}"';
    final bubbleMeFill = scheme.primary.withValues(alpha: 0.14);
    final bubbleOtherFill = scheme.surfaceContainerHighest.withValues(alpha: 0.72);
    final bubbleMeBorder = scheme.primary.withValues(alpha: 0.38);
    final bubbleOtherBorder = scheme.outline.withValues(alpha: 0.45);

    final bubble = Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(10),
        color: mine ? bubbleMeFill : bubbleOtherFill,
        border: Border.all(
          color: mine ? bubbleMeBorder : bubbleOtherBorder,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            widget.labelLine,
            textAlign: mine ? TextAlign.left : TextAlign.right,
            style: labelStyle,
            softWrap: true,
            maxLines: 3,
            overflow: TextOverflow.ellipsis,
          ),
          const SizedBox(height: 4),
          Text(
            displayBody,
            textAlign: mine ? TextAlign.left : TextAlign.right,
            style: bodyStyle,
            softWrap: true,
            maxLines: 12,
            overflow: TextOverflow.ellipsis,
          ),
          const SizedBox(height: 4),
          Text.rich(
            TextSpan(
              children: [
                TextSpan(
                  text: contextPrefix,
                  style: contextBaseStyle,
                ),
                TextSpan(
                  text: quotedSnippet,
                  style: contextBaseStyle.copyWith(
                    fontStyle: FontStyle.italic,
                  ),
                ),
              ],
            ),
            textAlign: mine ? TextAlign.left : TextAlign.right,
            softWrap: true,
            maxLines: 4,
            overflow: TextOverflow.ellipsis,
          ),
          if (item.hashtags.isNotEmpty) ...[
            const SizedBox(height: 6),
            Theme(
              data: theme.copyWith(
                textTheme: theme.textTheme.copyWith(
                  labelSmall: theme.textTheme.labelSmall?.copyWith(
                    fontSize: 10,
                    height: 1.15,
                  ),
                ),
              ),
              child: Wrap(
                alignment:
                    mine ? WrapAlignment.start : WrapAlignment.end,
                spacing: 4,
                runSpacing: 3,
                children: [
                  for (final tag in item.hashtags)
                    LedgerTagChip(
                      tag: tag,
                      unselectedLabelColor:
                          scheme.onSurfaceVariant.withValues(alpha: 0.88),
                    ),
                ],
              ),
            ),
          ],
        ],
      ),
    );

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2, horizontal: 4),
      child: Material(
        color: Colors.transparent,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 2, horizontal: 4),
          child: Row(
            mainAxisAlignment:
                mine ? MainAxisAlignment.start : MainAxisAlignment.end,
            children: [
              Expanded(
                child: Align(
                  alignment:
                      mine ? Alignment.centerLeft : Alignment.centerRight,
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 520),
                    child: Stack(
                      clipBehavior: Clip.none,
                      children: [
                        InkWell(
                          onTap: widget.onRowTap,
                          borderRadius: BorderRadius.circular(12),
                          child: bubble,
                        ),
                        Positioned(
                          top: 4,
                          right: mine ? 6 : null,
                          left: mine ? null : 6,
                          child: MouseRegion(
                            onEnter: (_) =>
                                setState(() => _markReadHover = true),
                            onExit: (_) =>
                                setState(() => _markReadHover = false),
                            child: Stack(
                              clipBehavior: Clip.none,
                              alignment: mine
                                  ? Alignment.topRight
                                  : Alignment.topLeft,
                              children: [
                                if (_markReadHover)
                                  Positioned(
                                    right: mine ? 0 : null,
                                    left: mine ? null : 0,
                                    bottom: 42,
                                    child: Material(
                                      elevation: 4,
                                      borderRadius: BorderRadius.circular(8),
                                      color: scheme.inverseSurface
                                          .withValues(alpha: 0.92),
                                      child: Padding(
                                        padding: const EdgeInsets.symmetric(
                                          horizontal: 10,
                                          vertical: 5,
                                        ),
                                        child: Text(
                                          'Mark as read',
                                          style: theme.textTheme.labelSmall
                                              ?.copyWith(
                                            color: scheme.onInverseSurface,
                                            fontWeight: FontWeight.w600,
                                          ),
                                        ),
                                      ),
                                    ),
                                  ),
                                Material(
                                  color: scheme.surface
                                      .withValues(alpha: 0.94),
                                  elevation: 2,
                                  shadowColor: Colors.black38,
                                  borderRadius: BorderRadius.circular(8),
                                  clipBehavior: Clip.antiAlias,
                                  child: InkWell(
                                    onTap: _markBusy ? null : _onMarkReadTap,
                                    borderRadius: BorderRadius.circular(8),
                                    child: Semantics(
                                      button: true,
                                      label: 'Mark as read for this expectation',
                                      child: SizedBox(
                                        width: 36,
                                        height: 36,
                                        child: Center(
                                          child: _markBusy
                                              ? SizedBox(
                                                  width: 18,
                                                  height: 18,
                                                  child: CircularProgressIndicator(
                                                    strokeWidth: 2,
                                                    color: scheme.primary,
                                                  ),
                                                )
                                              : Icon(
                                                  Icons.mark_chat_read_outlined,
                                                  size: 22,
                                                  color: scheme.primary,
                                                ),
                                        ),
                                      ),
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
            ],
          ),
        ),
      ),
    );
  }
}

/// Same paint as the main title —|— bar — keep tab highlights visually identical.
Color _pillarAccentBarColor(LedgerPillar pillar, ThemeData theme) {
  var base = pillar.captureAccent;
  if (pillar == LedgerPillar.home && theme.brightness == Brightness.light) {
    base = Color.lerp(base, theme.colorScheme.onSurface, 0.28)!;
  }
  return base.withValues(alpha: 0.94);
}

/// Vertical gap between [_PillarHeader] and composer / list toolbars.
const double _kPillarHeaderTrailingGap = 20;

/// Inset around filter rows and segmented controls below the pillar header.
const EdgeInsets _listingToolbarPadding = EdgeInsets.only(top: 8, bottom: 20);

class _PillarHeader extends StatelessWidget {
  const _PillarHeader({required this.pillar, required this.theme});

  final LedgerPillar pillar;
  final ThemeData theme;

  @override
  Widget build(BuildContext context) {
    final scheme = theme.colorScheme;
    final barColor = _pillarAccentBarColor(pillar, theme);
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
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
            const SizedBox(height: 12),
            Text(
              pillar.description,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: scheme.onSurfaceVariant,
                height: 1.45,
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
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final isLight = theme.brightness == Brightness.light;
    return FilledButton(
      focusNode: focusNode,
      autofocus: autofocus,
      onPressed: enabled ? onPressed : null,
      style: ButtonStyle(
        visualDensity: VisualDensity.compact,
        backgroundColor: WidgetStateProperty.resolveWith((states) {
          // 1) Disabled — visible but clearly inactive
          if (!enabled) {
            return isLight
                ? scheme.surfaceContainer
                : scheme.surfaceContainerHighest.withValues(alpha: 0.72);
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
              isLight ? 0.42 : 0.36,
            )!;
          }
          // 2) Secondary enabled idle (e.g. Save publicly)
          return isLight
              ? Color.lerp(
                  scheme.primaryContainer,
                  scheme.primary,
                  0.32,
                )!
              : Color.lerp(
                  scheme.primaryContainer,
                  scheme.primary,
                  0.24,
                )!;
        }),
        foregroundColor: WidgetStateProperty.resolveWith((states) {
          if (!enabled) {
            return scheme.onSurface.withValues(alpha: isLight ? 0.52 : 0.42);
          }
          if (states.contains(WidgetState.focused) ||
              states.contains(WidgetState.hovered)) {
            return scheme.onPrimary;
          }
          if (emphasizeAsKeyboardDefault) {
            return Color.lerp(
              scheme.onPrimaryContainer,
              scheme.onPrimary,
              isLight ? 0.45 : 0.42,
            )!;
          }
          return isLight
              ? scheme.onPrimaryContainer
              : scheme.onPrimaryContainer.withValues(alpha: 0.92);
        }),
      ),
      child: Text(label),
    );
  }
}

/// Home pillar: welcome, activity entry point, and a short recents list.
class _HomeDashboardPanel extends StatelessWidget {
  const _HomeDashboardPanel({
    required this.theme,
    required this.scheme,
    required this.displayName,
    this.companyName,
    required this.expectations,
    required this.people,
    required this.mePerson,
    required this.currentUserId,
    required this.peopleById,
    required this.mentionHandlesByExpectationId,
    required this.mentionPersonIdsByExpectationId,
    required this.hasUnreadChat,
    required this.activityUnreadCount,
    required this.onOpenActivityFeed,
    required this.onOpenItem,
    required this.onOpenColleaguesPage,
  });

  final ThemeData theme;
  final ColorScheme scheme;
  final String displayName;
  final String? companyName;
  final List<Expectation> expectations;
  final List<Person> people;
  final Person? mePerson;
  final String? currentUserId;
  final Map<String, Person> peopleById;
  final Map<String, List<String>> mentionHandlesByExpectationId;
  final Map<String, Set<String>> mentionPersonIdsByExpectationId;
  final bool Function(Expectation e) hasUnreadChat;
  final int activityUnreadCount;
  final VoidCallback onOpenActivityFeed;
  final void Function(Expectation e, Person? person) onOpenItem;
  /// Same destination as the sidebar People entry ("Your colleagues").
  final VoidCallback onOpenColleaguesPage;

  @override
  Widget build(BuildContext context) {
    final muted = scheme.onSurfaceVariant;
    final company = companyName?.trim();
    final involved = expectations
        .where(
          (e) =>
              e.status != ExpectationStatus.abandoned &&
              _ledgerUserInvolvedInExpectation(
                e,
                currentUserId,
                mePerson,
                mentionPersonIdsByExpectationId:
                    mentionPersonIdsByExpectationId,
              ),
        )
        .toList()
      ..sort(
        (a, b) => _expectationActivityAt(b).compareTo(_expectationActivityAt(a)),
      );
    final recent = involved.take(5).toList();
    final urgentPool = involved
        .where(
          (e) =>
              _expectationQualifiesForHomeUrgent(e) &&
              _homeUrgentUserIsWriterOrReceiver(
                e,
                currentUserId,
                mePerson,
                mentionPersonIdsByExpectationId:
                    mentionPersonIdsByExpectationId,
              ),
        )
        .toList();
    _sortHomeUrgentExpectations(urgentPool);
    final urgent = urgentPool.take(5).toList();
    final welcomeBase = theme.textTheme.headlineSmall?.copyWith(
      fontWeight: FontWeight.w700,
      color: scheme.onSurface,
      height: 1.25,
    );

    final welcomeBarColor = _pillarAccentBarColor(LedgerPillar.home, theme);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            Container(
              width: 4,
              height: 22,
              decoration: BoxDecoration(
                color: welcomeBarColor,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Text.rich(
                TextSpan(
                  children: [
                    TextSpan(text: 'Welcome, ', style: welcomeBase),
                    TextSpan(
                      text: displayName,
                      style: welcomeBase?.copyWith(fontWeight: FontWeight.w800),
                    ),
                    if (company != null && company.isNotEmpty)
                      WidgetSpan(
                        alignment: PlaceholderAlignment.middle,
                        child: Tooltip(
                          message: 'Open People — your colleagues',
                          child: MouseRegion(
                            cursor: SystemMouseCursors.click,
                            child: InkWell(
                              onTap: onOpenColleaguesPage,
                              borderRadius: BorderRadius.circular(4),
                              child: Padding(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 2,
                                  vertical: 1,
                                ),
                                child: Text(
                                  ' · $company',
                                  style: theme.textTheme.bodyMedium?.copyWith(
                                    color: scheme.primary,
                                    fontWeight: FontWeight.w600,
                                    height: 1.35,
                                    decoration: TextDecoration.underline,
                                    decorationColor:
                                        scheme.primary.withValues(alpha: 0.75),
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),
        Text(
          'Exled is a collaborative execution ledger designed to keep teams perfectly aligned'
          'Use it to log shared expectations, track personal commitments, and capture talking points for upcoming rituals.'
          'Use Quick Capture above to log an entry, clear up ambiguity, and keep work moving forward reliably.',
          style: theme.textTheme.bodyMedium?.copyWith(
            color: muted,
            height: 1.35,
          ),
        ),
        const SizedBox(height: 28),
        Material(
          color: scheme.surfaceContainerHigh.withValues(alpha: 0.42),
          borderRadius: BorderRadius.circular(12),
          child: InkWell(
            borderRadius: BorderRadius.circular(12),
            onTap: onOpenActivityFeed,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 20),
              child: Row(
                children: [
                  Badge(
                    isLabelVisible: activityUnreadCount > 0,
                    backgroundColor: scheme.error,
                    label: Text(
                      activityUnreadCount > 99 ? '99+' : '$activityUnreadCount',
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: scheme.onError,
                        fontWeight: FontWeight.w700,
                        fontSize: 10,
                      ),
                    ),
                    child: Icon(
                      Icons.notifications_outlined,
                      color: scheme.primary,
                      size: 22,
                    ),
                  ),
                  const SizedBox(width: 16),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Activity',
                          style: theme.textTheme.titleSmall?.copyWith(
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        const SizedBox(height: 6),
                        Text(
                          'Changelog across items you send or receive',
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: muted,
                            height: 1.2,
                          ),
                        ),
                      ],
                    ),
                  ),
                  Icon(Icons.chevron_right, color: muted, size: 22),
                ],
              ),
            ),
          ),
        ),
        const SizedBox(height: 32),
        LayoutBuilder(
          builder: (context, c) {
            final narrow = c.maxWidth < 520;
            final sectionTitleStyle = theme.textTheme.labelLarge?.copyWith(
              fontWeight: FontWeight.w700,
              color: scheme.onSurface,
              letterSpacing: 0.15,
            );
            final sectionHintStyle = theme.textTheme.bodySmall?.copyWith(
              color: muted,
              height: 1.35,
            );

            Widget recentsColumn() {
              return Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.center,
                    children: [
                      Icon(
                        Icons.hourglass_top_outlined,
                        size: 20,
                        color: scheme.primary,
                      ),
                      const SizedBox(width: 8),
                      Text('Recents', style: sectionTitleStyle),
                    ],
                  ),
                  const SizedBox(height: 6),
                  Text(
                    'Items related to you, ordered by newest updates.',
                    style: sectionHintStyle,
                  ),
                  const SizedBox(height: 18),
                  if (recent.isEmpty)
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.fromLTRB(18, 20, 18, 20),
                      decoration: BoxDecoration(
                        color: scheme.surfaceContainerHigh.withValues(alpha: 0.45),
                        borderRadius: BorderRadius.circular(14),
                        border: Border.all(
                          color: scheme.outlineVariant.withValues(alpha: 0.45),
                        ),
                      ),
                      child: Text(
                        'Nothing here yet — capture from the bar, or open Inbox / Outbox.',
                        style: theme.textTheme.bodyMedium?.copyWith(
                          color: muted,
                          height: 1.4,
                        ),
                      ),
                    )
                  else
                    Column(
                      children: [
                        for (final e in recent)
                          _HomeActivityRow(
                            expectation: e,
                            theme: theme,
                            scheme: scheme,
                            subline: _homeActivitySubline(
                              e,
                              currentUserId,
                              mePerson,
                              peopleById,
                              people,
                              mentionHandlesByExpectationId:
                                  mentionHandlesByExpectationId,
                              mentionPersonIdsByExpectationId:
                                  mentionPersonIdsByExpectationId,
                            ),
                            trailingLabel: _activityRecencyShortLabel(
                              _expectationActivityAt(e),
                            ),
                            trailingColor: null,
                            unread: hasUnreadChat(e),
                            onTap: () => onOpenItem(e, peopleById[e.personId]),
                          ),
                      ],
                    ),
                ],
              );
            }

            Widget urgentColumn() {
              return Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.center,
                    children: [
                      Icon(
                        Icons.warning_amber_rounded,
                        size: 20,
                        color: scheme.error,
                      ),
                      const SizedBox(width: 8),
                      Text('Attention needed', style: sectionTitleStyle),
                    ],
                  ),
                  const SizedBox(height: 6),
                  Text(
                    'Relevant, due to attention markers',                    
                    style: sectionHintStyle,
                  ),
                  const SizedBox(height: 18),
                  if (urgent.isEmpty)
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.fromLTRB(18, 20, 18, 20),
                      decoration: BoxDecoration(
                        color: scheme.surfaceContainerHigh.withValues(alpha: 0.45),
                        borderRadius: BorderRadius.circular(14),
                        border: Border.all(
                          color: scheme.outlineVariant.withValues(alpha: 0.45),
                        ),
                      ),
                      child: Text(
                        'Nothing urgent right now.',
                        style: theme.textTheme.bodyMedium?.copyWith(
                          color: muted,
                          height: 1.4,
                        ),
                      ),
                    )
                  else
                    Column(
                      children: [
                        for (final e in urgent)
                          _HomeActivityRow(
                            expectation: e,
                            theme: theme,
                            scheme: scheme,
                            subline: _homeActivitySubline(
                              e,
                              currentUserId,
                              mePerson,
                              peopleById,
                              people,
                              mentionHandlesByExpectationId:
                                  mentionHandlesByExpectationId,
                              mentionPersonIdsByExpectationId:
                                  mentionPersonIdsByExpectationId,
                            ),
                            trailingLabel: _homeUrgentTrailingLabel(e, scheme),
                            trailingColor: _homeUrgentTrailingColor(e, scheme),
                            urgencyRoleIcon: _homeUrgentRoleIcon(
                              e,
                              currentUserId,
                              mePerson,
                              mentionPersonIdsByExpectationId:
                                  mentionPersonIdsByExpectationId,
                            ),
                            urgencyRoleTooltip: _homeUrgentRoleTooltip(
                              e,
                              currentUserId,
                              mePerson,
                              mentionPersonIdsByExpectationId:
                                  mentionPersonIdsByExpectationId,
                            ),
                            urgencyRoleIconColor: _homeUrgentRoleIconColor(
                              e,
                              currentUserId,
                              mePerson,
                              mentionPersonIdsByExpectationId:
                                  mentionPersonIdsByExpectationId,
                            ),
                            unread: hasUnreadChat(e),
                            onTap: () => onOpenItem(e, peopleById[e.personId]),
                          ),
                      ],
                    ),
                ],
              );
            }

            if (narrow) {
              return Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  recentsColumn(),
                  const SizedBox(height: 36),
                  urgentColumn(),
                ],
              );
            }
            return Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(child: recentsColumn()),
                const SizedBox(width: 32),
                Expanded(child: urgentColumn()),
              ],
            );
          },
        ),
      ],
    );
  }
}

class _HomeActivityRow extends StatelessWidget {
  const _HomeActivityRow({
    required this.expectation,
    required this.theme,
    required this.scheme,
    required this.subline,
    required this.trailingLabel,
    this.trailingColor,
    this.urgencyRoleIcon,
    this.urgencyRoleTooltip,
    this.urgencyRoleIconColor,
    required this.unread,
    required this.onTap,
  });

  final Expectation expectation;
  final ThemeData theme;
  final ColorScheme scheme;
  final String? subline;
  final String trailingLabel;
  final Color? trailingColor;
  /// When set (home Urgent column), same glyphs as Inbox / Outbox rail: whose move it is.
  final IconData? urgencyRoleIcon;
  final String? urgencyRoleTooltip;
  final Color? urgencyRoleIconColor;
  final bool unread;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final sublineText = subline;
    final isTopic = expectation.type == ExpectationType.topic;
    final accent = isTopic
        ? LedgerListingAccents.topic
        : LedgerListingAccents.expectation;
    final icon = isTopic ? Icons.forum_outlined : Icons.flag_outlined;
    final readStripeAlpha = theme.brightness == Brightness.dark ? 0.30 : 0.48;
    final stripeColor =
        unread ? accent : accent.withValues(alpha: readStripeAlpha);
    final stripeWidth = unread ? 5.0 : 3.0;
    Widget row = Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Material(
        color: scheme.surfaceContainerHigh.withValues(alpha: 0.48),
        borderRadius: BorderRadius.circular(12),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: onTap,
          child: DecoratedBox(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(12),
              border: Border(
                left: BorderSide(width: stripeWidth, color: stripeColor),
              ),
            ),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
              child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(icon, size: 20, color: accent),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        expectation.summary,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodyMedium?.copyWith(
                          color: scheme.onSurface,
                          height: 1.35,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                      if (sublineText != null) ...[
                        const SizedBox(height: 4),
                        Text(
                          sublineText,
                          style: theme.textTheme.labelSmall?.copyWith(
                            color: scheme.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Text(
                      trailingLabel,
                      textAlign: TextAlign.end,
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: trailingColor ?? scheme.onSurfaceVariant,
                        fontWeight: trailingColor != null
                            ? FontWeight.w600
                            : FontWeight.normal,
                        fontFeatures: const [FontFeature.tabularFigures()],
                      ),
                    ),
                    if (urgencyRoleIcon != null) ...[
                      const SizedBox(height: 6),
                      Tooltip(
                        message: urgencyRoleTooltip ?? '',
                        child: Icon(
                          urgencyRoleIcon,
                          size: 20,
                          color:
                              urgencyRoleIconColor ?? scheme.onSurfaceVariant,
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
      ),
    );
    if (unread) {
      row = Tooltip(
        message: 'Unread chat or activity',
        child: row,
      );
    }
    return row;
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
    final isLight = theme.brightness == Brightness.light;
    final baseStyle = theme.textTheme.bodyMedium!.copyWith(
      color: isLight
          ? theme.colorScheme.onSurface.withValues(alpha: 0.82)
          : scheme.onSurfaceVariant,
      height: 1.5,
    );
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(16, 18, 16, 18),
      decoration: BoxDecoration(
        color: isLight
            ? scheme.primaryContainer.withValues(alpha: 0.72)
            : scheme.surfaceContainerHigh.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: isLight
              ? scheme.primary.withValues(alpha: 0.38)
              : accent.withValues(alpha: 0.28),
          width: isLight ? 1.25 : 1,
        ),
      ),
      child: Text.rich(
        TextSpan(
          style: baseStyle,
          children: [
            const TextSpan(
              text: 'Pick Talking point or Expectation below, type one line, then ',
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
    if (handle == null || handle.isEmpty) return kLedgerAllMentionLabel;
    for (final person in widget.people) {
      if (person.handle.toLowerCase() == handle.toLowerCase()) {
        return person.displayName.trim().isNotEmpty
            ? person.displayName
            : person.handle;
      }
    }
    return handle;
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
    final locale = Localizations.localeOf(context);
    final who = ledgerAtMentionLine(_targetLabel());
    final initials = ledgerPersonInitialLetter(who);
    final summaryStyle = widget.theme.textTheme.bodyMedium?.copyWith(
      color: widget.scheme.onSurfaceVariant,
      height: 1.35,
      fontFamily: 'monospace',
      fontSize: 14,
    );
    final parse = widget.entry.parse;
    final showPersonalIndicator =
        widget.linkedExpectation?.visibility == ExpectationVisibility.shadow;
    final rowSurface = _ledgerListingRowSurface(scheme: widget.scheme);
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
                      message: _timeLabel(widget.entry.createdAt, locale),
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
                          _timeLabel(widget.entry.createdAt, locale),
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

String _timeLabel(DateTime t, Locale locale) {
  return formatDisplayDateTime(t, locale);
}

/// Shown in listing deadline rails when [Expectation.deadlineAt] is unset (TBD).
const String kNoDeadlineListingSymbol = '\u221E'; // ∞ (not the digit 8)

String _deadlineDistanceLabel(Expectation e) {
  final due = e.deadlineAt;
  if (due == null) {
    final label = e.deadlineLabel.trim();
    if (label.isEmpty || label.toUpperCase() == 'TBD') {
      return kNoDeadlineListingSymbol;
    }
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

String _exactDateTimeLabel(DateTime dt, Locale locale) {
  return formatDisplayDateTime(dt, locale);
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

/// @-style label for chat / activity bubble headers (single leading @).
String _expectationBubbleAtSenderLabel(String raw) {
  final t = raw.trim();
  if (t.isEmpty) return '@unknown';
  return t.startsWith('@') ? t : '@$t';
}

/// Latest meaningful timestamp on an expectation (for dashboard ordering).
DateTime _expectationActivityAt(Expectation e) {
  var latest = e.createdAt.toUtc();
  void bump(DateTime? t) {
    if (t == null) return;
    final u = t.toUtc();
    if (u.isAfter(latest)) latest = u;
  }

  bump(e.responsibleUpdatedAt);
  bump(e.lastChattedSenderAt);
  bump(e.lastChattedReceiverAt);
  bump(e.publishedAt);
  bump(e.seenAt);
  bump(e.finishedAt);
  return latest;
}

bool _ledgerUserInvolvedInExpectation(
  Expectation e,
  String? currentUserId,
  Person? mePerson, {
  Map<String, Set<String>> mentionPersonIdsByExpectationId = const {},
}) {
  if (currentUserId != null && e.writerUserId == currentUserId) return true;
  if (mePerson != null &&
      expectationAppliesToPerson(
        e: e,
        myPersonId: mePerson.id,
        mentionsIndex: ExpectationMentionsIndex(
          personIdsByExpectationId: mentionPersonIdsByExpectationId,
        ),
      )) {
    return true;
  }
  return false;
}

Person? _ledgerWriterPerson(Expectation e, List<Person> people) {
  final w = e.writerUserId;
  if (w == null) return null;
  for (final p in people) {
    if (p.authUserId == w) return p;
  }
  return null;
}

/// One-line context for home activity rows (counterparty).
String? _homeActivitySubline(
  Expectation e,
  String? currentUserId,
  Person? mePerson,
  Map<String, Person> peopleById,
  List<Person> people, {
  Map<String, List<String>> mentionHandlesByExpectationId = const {},
  Map<String, Set<String>> mentionPersonIdsByExpectationId = const {},
}) {
  final uid = currentUserId;
  final isWriter = uid != null && e.writerUserId == uid;
  if (isWriter) {
    final receivers = expectationReceiverWhoLabel(
      summary: e.summary,
      personDisplayName: peopleById[e.personId]?.displayName,
      personHandle: peopleById[e.personId]?.handle,
      personId: e.personId,
      persistedMentionHandles:
          mentionHandlesByExpectationId[e.id] ?? const [],
    );
    if (receivers == kLedgerAllMentionLabel) return null;
    return 'With ${ledgerAtMentionLine(receivers)}';
  }
  if (mePerson != null &&
      expectationAppliesToPerson(
        e: e,
        myPersonId: mePerson.id,
        mentionsIndex: ExpectationMentionsIndex(
          personIdsByExpectationId: mentionPersonIdsByExpectationId,
        ),
      )) {
    final w = _ledgerWriterPerson(e, people);
    if (w == null) return 'From someone on the team';
    return 'From ${ledgerAtMentionLine(w.displayName.trim().isNotEmpty ? w.displayName : w.handle)}';
  }
  return null;
}

String _activityRecencyShortLabel(DateTime at) {
  final now = DateTime.now().toUtc();
  var d = now.difference(at.toUtc());
  if (d.isNegative) d = Duration.zero;
  if (d.inMinutes < 1) return 'now';
  if (d.inMinutes < 60) return '${d.inMinutes}m';
  if (d.inHours < 48) return '${d.inHours}h';
  if (d.inDays < 14) return '${d.inDays}d';
  final w = d.inDays ~/ 7;
  return '${w}w';
}

/// Calendar days from today (UTC) to [deadlineAt]'s date; negative = overdue.
int? _calendarDaysUntilDeadlineUtc(Expectation e) {
  final d = e.deadlineAt;
  if (d == null) return null;
  final now = DateTime.now().toUtc();
  final deadlineDay = DateTime.utc(d.year, d.month, d.day);
  final today = DateTime.utc(now.year, now.month, now.day);
  return deadlineDay.difference(today).inDays;
}

bool _deadlineApproachingOrPast(Expectation e) {
  final diff = _calendarDaysUntilDeadlineUtc(e);
  if (diff == null) return false;
  return diff <= 7;
}

bool _expectationHealthIsUnhealthy(Expectation e) {
  return e.health == ExpectationHealth.atRisk ||
      e.health == ExpectationHealth.offTrack;
}

/// Matches [_ExpectationOthersTile] `showWarningIndicator`: expectations with undefined health
/// or pending status surface as warnings in Inbox/Outbox but were omitted from Home Urgent.
bool _expectationHomeUrgentAttentionRisk(Expectation e) {
  if (e.type == ExpectationType.topic) {
    return _expectationHealthIsUnhealthy(e);
  }
  return _expectationHealthIsUnhealthy(e) ||
      e.health == ExpectationHealth.unknown ||
      e.status == ExpectationStatus.pending;
}

bool _expectationQualifiesForHomeUrgent(Expectation e) {
  if (e.status == ExpectationStatus.finished ||
      e.status == ExpectationStatus.abandoned) {
    return false;
  }
  return _expectationHomeUrgentAttentionRisk(e) || _deadlineApproachingOrPast(e);
}

/// Home Urgent: only items where you are the author or the named receiver (Inbox / Outbox).
bool _homeUrgentUserIsWriterOrReceiver(
  Expectation e,
  String? currentUserId,
  Person? mePerson, {
  Map<String, Set<String>> mentionPersonIdsByExpectationId = const {},
}) {
  final uid = currentUserId;
  if (uid != null && e.writerUserId == uid) return true;
  if (mePerson == null) return false;
  return expectationAppliesToPerson(
    e: e,
    myPersonId: mePerson.id,
    mentionsIndex: ExpectationMentionsIndex(
      personIdsByExpectationId: mentionPersonIdsByExpectationId,
    ),
  );
}

/// You are the addressee (including self-addressed); urgency is on your side — Inbox rail icon.
bool _homeUrgentNeedsMyAction(
  Expectation e,
  String? currentUserId,
  Person? mePerson, {
  Map<String, Set<String>> mentionPersonIdsByExpectationId = const {},
}) {
  if (mePerson == null) return false;
  return expectationAppliesToPerson(
    e: e,
    myPersonId: mePerson.id,
    mentionsIndex: ExpectationMentionsIndex(
      personIdsByExpectationId: mentionPersonIdsByExpectationId,
    ),
  );
}

/// You sent this to someone else (or no receiver yet); waiting on them / your dispatch — Outbox.
bool _homeUrgentWaitingOnCounterparty(
  Expectation e,
  String? currentUserId,
  Person? mePerson, {
  Map<String, Set<String>> mentionPersonIdsByExpectationId = const {},
}) {
  final uid = currentUserId;
  if (uid == null || e.writerUserId != uid) return false;
  return !_homeUrgentNeedsMyAction(
    e,
    currentUserId,
    mePerson,
    mentionPersonIdsByExpectationId: mentionPersonIdsByExpectationId,
  );
}

IconData _homeUrgentRoleIcon(
  Expectation e,
  String? currentUserId,
  Person? mePerson, {
  Map<String, Set<String>> mentionPersonIdsByExpectationId = const {},
}) {
  if (_homeUrgentNeedsMyAction(
    e,
    currentUserId,
    mePerson,
    mentionPersonIdsByExpectationId: mentionPersonIdsByExpectationId,
  )) {
    return Icons.south_west_outlined;
  }
  return Icons.north_east_outlined;
}

Color _homeUrgentRoleIconColor(
  Expectation e,
  String? currentUserId,
  Person? mePerson, {
  Map<String, Set<String>> mentionPersonIdsByExpectationId = const {},
}) {
  if (_homeUrgentNeedsMyAction(
    e,
    currentUserId,
    mePerson,
    mentionPersonIdsByExpectationId: mentionPersonIdsByExpectationId,
  )) {
    return LedgerPillar.expectationsMe.accent;
  }
  return LedgerPillar.expectationsOthers.accent;
}

String _homeUrgentRoleTooltip(
  Expectation e,
  String? currentUserId,
  Person? mePerson, {
  Map<String, Set<String>> mentionPersonIdsByExpectationId = const {},
}) {
  if (_homeUrgentNeedsMyAction(
    e,
    currentUserId,
    mePerson,
    mentionPersonIdsByExpectationId: mentionPersonIdsByExpectationId,
  )) {
    return 'On you (Inbox): you are the receiver — progress, reply, or resolve.';
  }
  if (_homeUrgentWaitingOnCounterparty(
    e,
    currentUserId,
    mePerson,
    mentionPersonIdsByExpectationId: mentionPersonIdsByExpectationId,
  )) {
    return 'Waiting on them (Outbox): you are the sender — follow up with the other party.';
  }
  return 'Urgent item';
}

String _homeUrgentTrailingLabel(Expectation e, ColorScheme scheme) {
  final parts = <String>[];
  final diff = _calendarDaysUntilDeadlineUtc(e);
  if (diff != null && diff <= 7) {
    if (diff < 0) {
      parts.add('Overdue ${-diff}d');
    } else if (diff == 0) {
      parts.add('Due today');
    } else if (diff == 1) {
      parts.add('Due tomorrow');
    } else {
      parts.add('Due in ${diff}d');
    }
  }
  if (_expectationHealthIsUnhealthy(e)) {
    parts.add(_healthMeta(e.health, scheme).$1);
  } else if (e.type == ExpectationType.expectation) {
    if (e.status == ExpectationStatus.pending) {
      parts.add(_statusMeta(e.status, scheme).$1);
    } else if (e.health == ExpectationHealth.unknown) {
      parts.add(_healthMeta(e.health, scheme).$1);
    }
  }
  return parts.join(' · ');
}

void _sortHomeUrgentExpectations(List<Expectation> list) {
  /// Lower = more urgent (aligned with [_expectationHomeUrgentAttentionRisk]).
  int attentionRank(Expectation e) {
    if (e.type == ExpectationType.topic) {
      return switch (e.health) {
        ExpectationHealth.offTrack => 0,
        ExpectationHealth.atRisk => 1,
        _ => 4,
      };
    }
    if (e.health == ExpectationHealth.offTrack) return 0;
    if (e.health == ExpectationHealth.atRisk) return 1;
    if (e.status == ExpectationStatus.pending) return 2;
    if (e.health == ExpectationHealth.unknown) return 3;
    return 4;
  }

  list.sort((a, b) {
    final da = _calendarDaysUntilDeadlineUtc(a);
    final db = _calendarDaysUntilDeadlineUtc(b);
    if (da != null && db != null && da != db) {
      return da.compareTo(db);
    }
    if (da != null && db == null) return -1;
    if (da == null && db != null) return 1;
    final ha = attentionRank(a);
    final hb = attentionRank(b);
    if (ha != hb) return ha.compareTo(hb);
    return _expectationActivityAt(b).compareTo(_expectationActivityAt(a));
  });
}

Color _homeUrgentTrailingColor(Expectation e, ColorScheme scheme) {
  final diff = _calendarDaysUntilDeadlineUtc(e);
  if (diff != null && diff < 0) return scheme.error;
  if (_expectationHomeUrgentAttentionRisk(e)) return scheme.error;
  if (diff != null && diff <= 7) return scheme.tertiary;
  return scheme.tertiary;
}

String _deadlineTooltip(Expectation e, Locale locale) {
  if (e.deadlineAt != null) {
    return 'Due: ${_exactDateTimeLabel(e.deadlineAt!, locale)}';
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

(String, Color) _healthMeta(ExpectationHealth health, ColorScheme scheme) {
  return switch (health) {
    ExpectationHealth.onTrack => ('On track', scheme.primary),
    ExpectationHealth.atRisk => ('At risk', scheme.error),
    ExpectationHealth.offTrack => ('Off track', scheme.secondary),
    ExpectationHealth.unknown => ('Undefined', scheme.outline),
  };
}

(String, Color) _statusMeta(ExpectationStatus status, ColorScheme scheme) {
  return switch (status) {
    ExpectationStatus.pending => ('Pending', scheme.outline),
    ExpectationStatus.accepted => ('Accepted', scheme.primary),
    ExpectationStatus.finished => ('Finished', scheme.outline),
    ExpectationStatus.abandoned => ('Abandoned', scheme.error),
  };
}

IconData _seenIcon(Expectation e) {
  if (e.seenAt != null) return Icons.visibility_outlined;
  return Icons.visibility_off_outlined;
}

String _seenTooltip(Expectation e, Locale locale) {
  if (e.seenAt != null) {
    return 'Seen: ${_exactDateTimeLabel(e.seenAt!, locale)}';
  }
  if (e.publishedAt != null) {
    return 'Published: ${_exactDateTimeLabel(e.publishedAt!, locale)}';
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
  final seen = <String>{};
  final out = <String>[];
  for (final m in _inlineTagRegex.allMatches(input)) {
    final k = normalizeHashtagToken(m.group(1) ?? '');
    if (k.isNotEmpty && seen.add(k)) out.add(k);
  }
  return out;
}

/// Lowercase needle for matching summary #tags (null = no filter).
String? _tagFilterNeedle(String? stored) {
  if (stored == null) return null;
  final t = stored.trim();
  if (t.isEmpty) return null;
  return t.toLowerCase();
}

/// Value for tag dropdown: casing from [available] when matched, else trimmed [stored] (orphan).
String? _tagFilterDropdownValue(String? stored, List<String> available) {
  final needle = _tagFilterNeedle(stored);
  if (needle == null) return null;
  for (final x in available) {
    if (x.toLowerCase() == needle) return x;
  }
  return stored!.trim();
}

List<String> _tagFilterDropdownItems(List<String> available, String? stored) {
  final merged = <String>{...available};
  final v = _tagFilterDropdownValue(stored, available);
  if (v != null) merged.add(v);
  final list = merged.toList();
  list.sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
  return list;
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
    this.mentionPersonIdsByExpectationId = const {},
    this.onArchiveInbox,
    this.talkingPointsBrowseListing = false,
    this.talkingPointMentionHandlesById,
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
  final Map<String, Set<String>> mentionPersonIdsByExpectationId;
  final Future<void> Function(Expectation expectation)? onArchiveInbox;
  /// Tags pillar (Private / Public lists): hover Archive + owner Delete.
  final bool talkingPointsBrowseListing;
  final Map<String, List<String>>? talkingPointMentionHandlesById;
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
                  coReceiverPersonIds:
                      mentionPersonIdsByExpectationId[e.id] ?? const {},
                  onArchiveInbox: onArchiveInbox,
                  talkingPointsBrowseListing: talkingPointsBrowseListing,
                  talkingPointPersistedMentions:
                      talkingPointMentionHandlesById?[e.id] ?? const [],
                  peopleById: peopleById,
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
          color: scheme.primary.withValues(alpha: 0.9),
          width: 2,
        ),
      );
      return InputDecoration(
        labelText: label,
        isDense: true,
        contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        filled: true,
        fillColor: active
            ? scheme.primaryContainer.withValues(alpha: 0.45)
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
        labelStyle: theme.textTheme.labelMedium?.copyWith(
          fontWeight: active ? FontWeight.w600 : FontWeight.w400,
          color: active ? scheme.primary : scheme.onSurfaceVariant,
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
                    child: Text(_statusMeta(s, scheme).$1),
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
                      ledgerAtMentionLine(
                        p.displayName.trim().isNotEmpty
                            ? p.displayName
                            : p.handle,
                      ),
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
    this.coReceiverPersonIds = const {},
    this.onArchiveInbox,
    this.composerRecentListing = false,
    this.talkingPointsBrowseListing = false,
    this.talkingPointPersistedMentions = const [],
    this.peopleById = const {},
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
  final Set<String> coReceiverPersonIds;
  final Future<void> Function(Expectation expectation)? onArchiveInbox;
  /// Add Expectation / Add talking point — Recent: hover Delete (no under-avatar trash).
  final bool composerRecentListing;
  /// Tags pillar talking-point lists: hover Archive (non-terminal) + Delete when author.
  final bool talkingPointsBrowseListing;
  final List<String> talkingPointPersistedMentions;
  final Map<String, Person> peopleById;
  final Future<void> Function(Expectation expectation)? onArchiveTalkingPoint;
  /// Shadow talking points only: publish to echo when [Expectation.personId] is empty (no @-addressee).
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
    return _ledgerListingRowSurface(scheme: widget.scheme);
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
    final locale = Localizations.localeOf(context);
    final isDiscussionPoint = _isDiscussionPoint(widget.expectation);
    final baseWho = isDiscussionPoint
        ? talkingPointMentionWhoLabel(
            widget.expectation.summary,
            persistedMentionHandles: widget.talkingPointPersistedMentions,
            persistedMentionPersonIds: widget.coReceiverPersonIds,
            peopleById: widget.peopleById,
          )
        : expectationReceiverWhoLabel(
            summary: widget.expectation.summary,
            personDisplayName: widget.person?.displayName,
            personHandle: widget.person?.handle,
            personId: widget.expectation.personId,
            persistedMentionHandles: widget.talkingPointPersistedMentions,
          );
    final who =
        isDiscussionPoint ? baseWho : ledgerAtMentionLine(baseWho);
    final initials = ledgerPersonInitialLetter(who);
    final summaryStyle = widget.theme.textTheme.bodyMedium?.copyWith(
      color: widget.scheme.onSurfaceVariant,
      height: 1.35,
    );
    final tags = _extractInlineTags(widget.expectation.summary);
    final (healthLabel, healthColor) =
        _healthMeta(widget.expectation.health, widget.scheme);
    final colorTalkingSummaryTokens =
        widget.talkingPointsBrowseListing && isDiscussionPoint;
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
    final typeAccent = isDiscussionPoint
        ? LedgerListingAccents.topic
        : LedgerListingAccents.expectation;
    /// Left edge always uses [typeAccent]; unread = full color + wider stripe.
    final readStripeAlpha =
        widget.theme.brightness == Brightness.dark ? 0.30 : 0.48;
    final listingStripeColor = widget.hasUnreadChat
        ? typeAccent
        : typeAccent.withValues(alpha: readStripeAlpha);
    final listingStripeWidth = widget.hasUnreadChat ? 5.0 : 3.0;
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
    final isInboxReceiver = recvId.isNotEmpty &&
        (widget.expectation.personId.trim() == recvId ||
            widget.coReceiverPersonIds.contains(recvId));
    final canArchiveInbox = widget.inboxHoverListing &&
        widget.onArchiveInbox != null &&
        (isWriter || isInboxReceiver);
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
        widget.expectation.visibility == ExpectationVisibility.shadow &&
        isDiscussionPoint;
    final showTalkingPointsBrowseHoverBar = widget.talkingPointsBrowseListing &&
        _hoverTalkingPointsBrowseRow &&
        (canTpBrowsePublish || canTpBrowseArchive || canDelete);
    Widget card = Material(
      color: rowBackground,
      borderRadius: BorderRadius.circular(10),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        borderRadius: BorderRadius.circular(10),
        onTap: widget.onOpenDetails,
        child: DecoratedBox(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(10),
            border: Border(
              left: BorderSide(width: listingStripeWidth, color: listingStripeColor),
            ),
          ),
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
                                    colorTalkingSummaryTokens
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
                          message: _deadlineTooltip(widget.expectation, locale),
                          child: Container(
                            padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                            decoration: BoxDecoration(
                              borderRadius: BorderRadius.circular(999),
                              color: widget.scheme.surfaceContainerHigh.withValues(alpha: 0.42),
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
                          color: widget.scheme.surfaceContainerHigh.withValues(alpha: 0.42),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.center,
                          children: [
                            if (draftDeadlineRail)
                              Tooltip(
                                message: _deadlineTooltip(widget.expectation, locale),
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
                                        color: widget.scheme.error,
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
                                message: _seenTooltip(widget.expectation, locale),
                                child: Icon(
                                  Icons.visibility_off_outlined,
                                  size: 16,
                                  color: widget.scheme.onSurfaceVariant,
                                ),
                              ),
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
                                          .withValues(alpha: 0.42),
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
      ),
    );
    if (widget.hasUnreadChat) {
      card = Tooltip(
        message: 'Unread chat or activity',
        child: card,
      );
    }

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

Color _ledgerListingRowSurface({
  required ColorScheme scheme,
}) {
  return scheme.surfaceContainerHigh.withValues(alpha: 0.48);
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
    this.messageType = kExpectationMessageTypeChat,
    this.readAtByCounterparty,
  });

  final String id;
  final String senderPersonId;
  final String senderLabel;
  final String messageText;
  final DateTime createdAt;
  final List<_PendingAttachment> attachments;
  final int messageType;

  /// Latest `read_at` from a reader who is not [senderPersonId] (chat rows only).
  final DateTime? readAtByCounterparty;
}

enum _UnsavedDetailsCloseChoice { keepEditing, discard, save }

class _ExpectationDetailsPanel extends StatefulWidget {
  const _ExpectationDetailsPanel({
    super.key,
    required this.expectation,
    required this.person,
    this.talkingPointPersistedMentions = const [],
    this.coReceiverPersonIds = const {},
    this.receiverPeople = const [],
    required this.canEdit,
    this.onInviteReceivers,
    this.onChangelogReadSynced,
    this.onExpectationDataMutated,
  });

  final Expectation expectation;
  final Person? person;
  final List<String> talkingPointPersistedMentions;
  final Set<String> coReceiverPersonIds;
  final List<Person> receiverPeople;
  final bool canEdit;
  final Future<void> Function(List<Person> receivers)? onInviteReceivers;
  final VoidCallback? onChangelogReadSynced;
  final VoidCallback? onExpectationDataMutated;

  @override
  State<_ExpectationDetailsPanel> createState() => _ExpectationDetailsPanelState();
}

class _ExpectationDetailsPanelState extends State<_ExpectationDetailsPanel> {
  static final RegExp _tagsRegex = RegExp(r'#([a-zA-Z0-9._-]+)');
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
  DateTime? _updateRequestedAt;
  bool _requestingUpdate = false;

  /// Changelog bubbles compare [DateTime.isAfter] against this UTC instant:
  /// - On first load we seed from `expectation_changelog_reads.last_read_at` (your stored read
  ///   cursor). A **brighter / wider** left stripe means that row was still —unread— vs that
  ///   cursor (same idea as the activity bell).
  /// - After a successful [syncExpectationChangelogReadWatermark], we advance this to the latest
  ///   changelog `created_at` in the loaded thread so **opening details counts as reading**
  ///   everything shown here.
  DateTime _changelogVisitBaselineUtc =
      DateTime.fromMillisecondsSinceEpoch(0, isUtc: true);
  bool _changelogVisitBaselineCaptured = false;

  /// Bubble header: show sender as @name (one leading @).
  String _bubbleAtSenderLabel(String raw) => _expectationBubbleAtSenderLabel(raw);

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
    _updateRequestedAt = widget.expectation.updateRequestedAt;
    _senderLabel = _initialSenderLabel();
    _loadSenderLabel();
    _loadConversation();
  }

  @override
  void didUpdateWidget(covariant _ExpectationDetailsPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.expectation.id != oldWidget.expectation.id) {
      _updateRequestedAt = widget.expectation.updateRequestedAt;
    } else if (widget.expectation.updateRequestedAt !=
        oldWidget.expectation.updateRequestedAt) {
      _updateRequestedAt = widget.expectation.updateRequestedAt;
    }
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

  bool get _canPopDetailsWithoutPrompt =>
      !_saving && !_deleting && (!widget.canEdit || !_dirty);

  /// Returns true when the details route was dismissed (or user chose discard/save).
  Future<bool> tryCloseForQuickCapture() async {
    if (!mounted) return false;
    if (_saving || _deleting) return false;
    if (_canPopDetailsWithoutPrompt) {
      Navigator.of(context).pop(_hasSavedChanges);
      return true;
    }
    await _confirmUnsavedThenMaybeCloseDetails();
    if (!mounted) return true;
    return false;
  }

  Future<void> _attemptCloseDetails() async {
    await tryCloseForQuickCapture();
  }

  Future<void> _confirmUnsavedThenMaybeCloseDetails() async {
    if (!mounted) return;
    final noun = _isDiscussionPoint(widget.expectation)
        ? 'talking point'
        : 'expectation';
    final choice = await showDialog<_UnsavedDetailsCloseChoice>(
      context: context,
      builder: (dialogContext) {
        return AlertDialog(
          title: const Text('Save changes?'),
          content: Text(
            'You have unsaved changes to this $noun. Do you want to save before closing?',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext)
                  .pop(_UnsavedDetailsCloseChoice.keepEditing),
              child: const Text('Keep editing'),
            ),
            TextButton(
              onPressed: () => Navigator.of(dialogContext)
                  .pop(_UnsavedDetailsCloseChoice.discard),
              child: const Text("Don't save"),
            ),
            FilledButton(
              onPressed: () => Navigator.of(dialogContext)
                  .pop(_UnsavedDetailsCloseChoice.save),
              child: const Text('Save'),
            ),
          ],
        );
      },
    );
    if (!mounted) return;
    if (choice == null || choice == _UnsavedDetailsCloseChoice.keepEditing) {
      return;
    }
    if (choice == _UnsavedDetailsCloseChoice.discard) {
      Navigator.of(context).pop(_hasSavedChanges);
      return;
    }
    await _save();
    if (!mounted) return;
    if (!_dirty) {
      Navigator.of(context).pop(_hasSavedChanges);
    }
  }

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
    return insertExpectationAppMessage(
      client: Supabase.instance.client,
      companyId: _companyId!,
      expectationId: widget.expectation.id,
      senderPersonId: _myPersonId!,
      messageText: text,
      type: type,
    );
  }

  Future<void> _touchChatActivity() async {
    await touchExpectationChatActivityForAuthUser(
      client: Supabase.instance.client,
      expectationId: widget.expectation.id,
      expectationWriterUserId: widget.expectation.writerUserId,
    );
  }

  List<ChangelogSaveEvent> _collectSaveChangelogEvents(
    ColorScheme scheme, {
    required bool publish,
  }) {
    final isTopic = widget.expectation.type == ExpectationType.topic;
    final nextVisibility = publish ? ExpectationVisibility.echo : _visibility;
    final events = <ChangelogSaveEvent>[];
    if (_descriptionController.text.trim() != _savedSummary) {
      events.add(
        ChangelogSaveEvent(
          type: kExpectationMessageTypeChangelogDescription,
          messageText: encodeChangelogPayloadDescription(isTopic: isTopic),
        ),
      );
    }
    if (_deadlineAt != _savedDeadlineAt ||
        _deadlineLabel.trim() != _savedDeadlineLabel) {
      final deadlineText = _deadlineAt == null
          ? (_deadlineLabel.trim().isEmpty ? 'no deadline' : _deadlineLabel.trim())
          : _dateOnlyLabel(_deadlineAt!);
      events.add(
        ChangelogSaveEvent(
          type: kExpectationMessageTypeChangelogDeadline,
          messageText: encodeChangelogPayloadDeadline(
            deadlineAt: _deadlineAt,
            label: deadlineText,
          ),
        ),
      );
    }
    String? statusLabel;
    String? healthLabel;
    int? progressPct;
    if (_status != _savedStatus) {
      statusLabel = _statusMeta(_status, scheme).$1;
    }
    if (_health != _savedHealth) {
      healthLabel = _healthMeta(_health, scheme).$1;
    }
    if (_progress != _savedProgress) {
      progressPct = _progress ?? 0;
    }
    if (statusLabel != null || healthLabel != null || progressPct != null) {
      final onlyProgress =
          progressPct != null && statusLabel == null && healthLabel == null;
      if (onlyProgress) {
        events.add(
          ChangelogSaveEvent(
            type: kExpectationMessageTypeChangelogFields,
            messageText: encodeChangelogPayloadProgress(
              isTopic: isTopic,
              pct: progressPct!,
            ),
          ),
        );
      } else {
        events.add(
          ChangelogSaveEvent(
            type: kExpectationMessageTypeChangelogFields,
            messageText: encodeChangelogPayloadFields(
              isTopic: isTopic,
              statusLabel: statusLabel,
              healthLabel: healthLabel,
              progressPct: progressPct,
            ),
          ),
        );
      }
    }
    if (publish && _savedVisibility == ExpectationVisibility.shadow) {
      events.add(
        ChangelogSaveEvent(
          type: kExpectationMessageTypeChangelogPublished,
          messageText: encodeChangelogPayloadPublished(isTopic: isTopic),
        ),
      );
    } else if (nextVisibility != _savedVisibility) {
      events.add(
        ChangelogSaveEvent(
          type: kExpectationMessageTypeChangelogVisibility,
          messageText: encodeChangelogPayloadVisibility(
            isTopic: isTopic,
            echo: nextVisibility == ExpectationVisibility.echo,
          ),
        ),
      );
    }
    return events;
  }

  String _dateOnlyLabel(DateTime dt) {
    return formatDisplayDateOnly(dt, Localizations.localeOf(context));
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
    final loc = Localizations.localeOf(context);
    setState(() {
      _deadlineAt = DateTime(picked.year, picked.month, picked.day).toUtc();
      _deadlineLabel = formatDisplayDateOnly(
        DateTime(picked.year, picked.month, picked.day),
        loc,
      );
    });
  }

  Future<void> _archiveColleagueTalkingPoint() async {
    if (_saving || !widget.canEdit) return;
    setState(() => _status = ExpectationStatus.finished);
    await _save();
  }

  bool get _canRequestUpdate {
    final uid = Supabase.instance.client.auth.currentUser?.id;
    final writerId = widget.expectation.writerUserId;
    if (uid == null || writerId == null || writerId != uid) return false;
    final hasReceivers = widget.expectation.personId.trim().isNotEmpty ||
        widget.coReceiverPersonIds.isNotEmpty;
    return widget.canEdit &&
        !_editingDescription &&
        widget.expectation.visibility == ExpectationVisibility.echo &&
        _status != ExpectationStatus.finished &&
        _status != ExpectationStatus.abandoned &&
        hasReceivers;
  }

  Future<void> _requestUpdate() async {
    if (_requestingUpdate || !_canRequestUpdate) return;
    setState(() => _requestingUpdate = true);
    await _ensureActorContext();
    if (_myPersonId == null || _companyId == null) {
      if (mounted) {
        setState(() => _requestingUpdate = false);
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Could not resolve your profile.')),
        );
      }
      return;
    }
    final client = Supabase.instance.client;
    final uid = client.auth.currentUser?.id;
    final now = DateTime.now().toUtc();
    const eventType = 'update_requested';
    const note =
        'Update requested: consider updating progress, deadline, or status.';
    try {
      if (widget.expectation.type == ExpectationType.expectation) {
        try {
          final peopleRows = await client
              .from('people')
              .select(
                'id,created_at,display_name,handle,auth_user_id,email,title',
              )
              .eq('company_id', _companyId!);
          final people = <Person>[];
          for (final raw in peopleRows as List) {
            if (raw is! Map) continue;
            final row = Map<String, dynamic>.from(raw);
            people.add(
              Person(
                id: row['id'] as String,
                createdAt: DateTime.tryParse(
                      (row['created_at'] as String?) ?? '',
                    ) ??
                    DateTime.now().toUtc(),
                displayName: ((row['display_name'] as String?) ?? '').trim(),
                handle: ((row['handle'] as String?) ?? '').trim(),
                authUserId: (row['auth_user_id'] as String?)?.trim(),
                email: ((row['email'] as String?) ?? '').trim().isEmpty
                    ? null
                    : ((row['email'] as String?) ?? '').trim(),
                title: ((row['title'] as String?) ?? '').trim().isEmpty
                    ? null
                    : ((row['title'] as String?) ?? '').trim(),
              ),
            );
          }
          final primaryHandle = (widget.person?.handle ?? '').trim();
          final mentionLine = primaryHandle.isNotEmpty
              ? '@$primaryHandle ${widget.expectation.summary}'
              : widget.expectation.summary;
          await syncExpectationCoReceiverMentions(
            client: client,
            companyId: _companyId!,
            expectationId: widget.expectation.id,
            mentionSourceText: mentionLine,
            authorPersonId: _myPersonId!,
            people: people,
            resolveMe: (_) async {
              for (final p in people) {
                if (p.id == _myPersonId) return p;
              }
              return null;
            },
            createPlaceholder: (_) async {
              throw StateError('Unexpected unknown @mention on request update');
            },
          );
        } on PostgrestException {
          // Mentions table / policy not deployed.
        } catch (_) {}
      }

      await client.from('expectations').update({
        'update_requested_at': now.toIso8601String(),
        'expectation_health': _healthToDb(ExpectationHealth.atRisk),
        'responsible_updated_at': now.toIso8601String(),
      }).eq('id', widget.expectation.id);

      await client.from('expectation_events').insert({
        'company_id': _companyId,
        'expectation_id': widget.expectation.id,
        'event_type': eventType,
        'note': note,
        if (uid != null) 'actor_user_id': uid,
      });

      await _insertExpectationMessage(
        text: encodeChangelogPayloadUpdateRequested(
          isTopic: widget.expectation.type == ExpectationType.topic,
        ),
        type: kExpectationMessageTypeChangelogUpdateRequested,
      );
      await _touchChatActivity();

      if (!mounted) return;
      setState(() {
        _requestingUpdate = false;
        _updateRequestedAt = now;
        _health = ExpectationHealth.atRisk;
        _savedHealth = ExpectationHealth.atRisk;
      });
      widget.onExpectationDataMutated?.call();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Update requested — your counterparty was notified.'),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      setState(() => _requestingUpdate = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Request failed: $e')),
      );
    }
  }

  Future<void> _save({bool publish = false}) async {
    if (_saving) return;
    setState(() => _saving = true);
    final client = Supabase.instance.client;
    await _ensureActorContext();
    final isReceiverActor = _myPersonId != null &&
        (_myPersonId == widget.expectation.personId ||
            widget.coReceiverPersonIds.contains(_myPersonId));
    // If receiver saves while still pending, auto-promote to accepted.
    if (isReceiverActor && _status == ExpectationStatus.pending) {
      _status = ExpectationStatus.accepted;
    }
    final summary = normalizeHashtagsInText(_descriptionController.text.trim());
    final nextVisibility = publish ? ExpectationVisibility.echo : _visibility;
    final nextFinishedAt = _status == ExpectationStatus.finished
        ? (widget.expectation.finishedAt ?? DateTime.now().toUtc())
        : null;
    final responsibleFieldsChanged = _status != _savedStatus ||
        _health != _savedHealth ||
        _deadlineAt != _savedDeadlineAt ||
        _deadlineLabel.trim() != _savedDeadlineLabel ||
        _progress != _savedProgress;
    final summaryChanged = summary.trim() != _savedSummary;
    final clearUpdateRequest = _updateRequestedAt != null &&
        (summaryChanged || responsibleFieldsChanged);
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
    if (clearUpdateRequest) {
      updates['update_requested_at'] = null;
    }
    final scheme = Theme.of(context).colorScheme;
    final changeLogEvents = _collectSaveChangelogEvents(scheme, publish: publish);
    try {
      await client.from('expectations').update(updates).eq('id', widget.expectation.id);
      var actorReady = await _ensureActorContext();
      if (!actorReady) {
        await _loadConversation();
        actorReady = _myPersonId != null && _companyId != null;
      }
      if (actorReady &&
          _companyId != null &&
          _myPersonId != null &&
          changeLogEvents.isNotEmpty) {
        try {
          final peopleRows = await client
              .from('people')
              .select(
                'id,created_at,display_name,handle,auth_user_id,email,title',
              )
              .eq('company_id', _companyId!);
          final people = <Person>[];
          for (final raw in peopleRows as List) {
            if (raw is! Map) continue;
            final row = Map<String, dynamic>.from(raw);
            people.add(
              Person(
                id: row['id'] as String,
                createdAt: DateTime.tryParse(
                      (row['created_at'] as String?) ?? '',
                    ) ??
                    DateTime.now().toUtc(),
                displayName: ((row['display_name'] as String?) ?? '').trim(),
                handle: ((row['handle'] as String?) ?? '').trim(),
                authUserId: (row['auth_user_id'] as String?)?.trim(),
                email: ((row['email'] as String?) ?? '').trim().isEmpty
                    ? null
                    : ((row['email'] as String?) ?? '').trim(),
                title: ((row['title'] as String?) ?? '').trim().isEmpty
                    ? null
                    : ((row['title'] as String?) ?? '').trim(),
              ),
            );
          }
          if (widget.expectation.type == ExpectationType.expectation) {
            final primaryHandle = (widget.person?.handle ?? '').trim();
            final mentionLine = primaryHandle.isNotEmpty
                ? '@$primaryHandle $summary'
                : summary;
            await syncExpectationCoReceiverMentions(
              client: client,
              companyId: _companyId!,
              expectationId: widget.expectation.id,
              mentionSourceText: mentionLine,
              authorPersonId: _myPersonId!,
              people: people,
              resolveMe: (_) async {
                for (final p in people) {
                  if (p.id == _myPersonId) return p;
                }
                return null;
              },
              createPlaceholder: (_) async {
                throw StateError('Unexpected unknown @mention on save');
              },
            );
          } else if (nextVisibility == ExpectationVisibility.echo) {
            await syncTalkingPointMentions(
              client: client,
              companyId: _companyId!,
              expectationId: widget.expectation.id,
              summary: summary,
              authorPersonId: _myPersonId!,
              people: people,
              resolveMe: (_) async {
                for (final p in people) {
                  if (p.id == _myPersonId) return p;
                }
                return null;
              },
              createPlaceholder: (_) async {
                throw StateError('Unexpected unknown @mention on save');
              },
              replaceExisting: true,
            );
          }
        } on PostgrestException {
          // Mentions table / policy not deployed.
        } catch (_) {}
      }
      if (actorReady && changeLogEvents.isNotEmpty) {
        for (final ev in changeLogEvents) {
          await _insertExpectationMessage(
            text: ev.messageText,
            type: ev.type,
          );
        }
        await _touchChatActivity();
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
        if (clearUpdateRequest) {
          _updateRequestedAt = null;
        }
      });
      await _loadConversation();
      widget.onExpectationDataMutated?.call();
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            publish && widget.expectation.type == ExpectationType.topic
                ? 'Talking point published.'
                : 'Expectation saved.',
          ),
        ),
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

  Future<void> _inviteReceivers() async {
    if (_inviting || widget.onInviteReceivers == null) return;
    final targets = widget.receiverPeople;
    if (targets.isEmpty) return;
    setState(() => _inviting = true);
    try {
      await widget.onInviteReceivers!(targets);
      if (!mounted) return;
      setState(() => _inviting = false);
    } catch (_) {
      if (!mounted) return;
      setState(() => _inviting = false);
    }
  }

  void _maybeMarkPeerChatReadsOnce(List<_ExpectationMessageVm> mapped) {
    if (_myPersonId == null || _companyId == null) return;
    final peerIds = mapped
        .where(
          (m) =>
              expectationMessageTypeIsChatRow(m.messageType) &&
              m.senderPersonId.trim().isNotEmpty &&
              m.senderPersonId != _myPersonId,
        )
        .map((m) => m.id)
        .toList();
    if (peerIds.isEmpty) return;
    unawaited(
      markExpectationPeerChatMessagesRead(
        client: Supabase.instance.client,
        companyId: _companyId!,
        viewerPersonId: _myPersonId!,
        peerMessageIds: peerIds,
      ),
    );
  }

  static const _expectationMessagesSelectWithReads =
      'id,sender_person_id,message_text,created_at,type,'
      'people!expectation_messages_sender_person_id_fkey(display_name,handle),'
      'expectation_message_attachments(file_name,file_url),'
      'expectation_message_reads(reader_person_id,read_at)';

  static const _expectationMessagesSelectWithoutReads =
      'id,sender_person_id,message_text,created_at,type,'
      'people!expectation_messages_sender_person_id_fkey(display_name,handle),'
      'expectation_message_attachments(file_name,file_url)';

  /// Loads thread rows; omits read-receipt embed if prod RLS/grants are not deployed yet.
  Future<List<dynamic>> _fetchExpectationMessageRows({
    required SupabaseClient client,
    required String expectationId,
  }) async {
    try {
      return await client
          .from('expectation_messages')
          .select(_expectationMessagesSelectWithReads)
          .eq('expectation_id', expectationId)
          .order('created_at', ascending: false) as List;
    } on PostgrestException catch (e) {
      if (e.code != '42501') rethrow;
      return await client
          .from('expectation_messages')
          .select(_expectationMessagesSelectWithoutReads)
          .eq('expectation_id', expectationId)
          .order('created_at', ascending: false) as List;
    }
  }

  Future<void> _loadConversation() async {
    if (!_LedgerConsoleScreenState.isPersistedExpectationId(widget.expectation.id)) {
      if (!mounted) return;
      setState(() {
        _messagesLoading = false;
        _messagesError =
            'This item is not fully saved yet. Close, refresh the list, and open it again.';
      });
      return;
    }
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

      if (!_changelogVisitBaselineCaptured) {
        try {
          final readRows = await client
              .from('expectation_changelog_reads')
              .select('last_read_at')
              .eq('expectation_id', widget.expectation.id)
              .eq('reader_person_id', _myPersonId!)
              .eq('company_id', _companyId!)
              .limit(1);
          if ((readRows as List).isNotEmpty) {
            final raw = (readRows.first as Map<String, dynamic>)['last_read_at'] as String?;
            final parsed = raw != null ? DateTime.tryParse(raw)?.toUtc() : null;
            if (parsed != null) {
              _changelogVisitBaselineUtc = parsed;
            }
          }
        } on PostgrestException {
          // Reads table / policy not deployed — keep epoch baseline.
        }
        _changelogVisitBaselineCaptured = true;
      }

      final rows = await _fetchExpectationMessageRows(
        client: client,
        expectationId: widget.expectation.id,
      );

      String normalizeLoadedMessageText(dynamic raw) {
        if (raw == null) return '';
        final String s;
        if (raw is String) {
          s = raw;
        } else if (raw is Map) {
          s = jsonEncode(Map<String, dynamic>.from(raw as Map));
        } else {
          s = '$raw';
        }
        return s.replaceAll(RegExp(r'[\u200B-\u200D\uFEFF]'), '').trim();
      }

      Map<String, dynamic>? personRowFrom(dynamic personObj) {
        if (personObj is Map<String, dynamic>) return personObj;
        if (personObj is Map) return Map<String, dynamic>.from(personObj as Map);
        if (personObj is List && personObj.isNotEmpty) {
          final first = personObj.first;
          if (first is Map<String, dynamic>) return first;
          if (first is Map) return Map<String, dynamic>.from(first as Map);
        }
        return null;
      }

      final mapped = (rows as List).map((r) {
        if (r is! Map) {
          throw StateError('Expected message row map, got ${r.runtimeType}');
        }
        final row = r is Map<String, dynamic> ? r : Map<String, dynamic>.from(r);
        final personMap = personRowFrom(row['people']);
        final senderLabel = personMap != null
            ? ((personMap['display_name'] as String?)?.trim().isNotEmpty == true
                ? (personMap['display_name'] as String).trim()
                : '@${(personMap['handle'] as String?) ?? 'unknown'}')
            : '@unknown';
        final senderId =
            _LedgerConsoleScreenState._dbString(row['sender_person_id']).trim();
        final attachmentRows =
            row['expectation_message_attachments'] is List
                ? row['expectation_message_attachments'] as List
                : const <dynamic>[];
        final attachments = attachmentRows
            .map(
              (a) {
                if (a is! Map) return null;
                final att = a is Map<String, dynamic>
                    ? a
                    : Map<String, dynamic>.from(a);
                final url =
                    _LedgerConsoleScreenState._dbString(att['file_url']).trim();
                if (url.isEmpty) return null;
                final name =
                    _LedgerConsoleScreenState._dbString(att['file_name']).trim();
                return _PendingAttachment(
                  fileName: name.isNotEmpty ? name : 'Attachment',
                  fileUrl: url,
                );
              },
            )
            .whereType<_PendingAttachment>()
            .toList();
        final rawType = row['type'];
        final messageType = rawType is int
            ? rawType
            : (rawType is num ? rawType.toInt() : int.tryParse('$rawType') ?? 0);
        DateTime? readAtByCounterparty;
        final readRaw = row['expectation_message_reads'];
        final readList = readRaw is List ? readRaw : const <dynamic>[];
        for (final raw in readList) {
          if (raw is! Map) continue;
          final readRow =
              raw is Map<String, dynamic> ? raw : Map<String, dynamic>.from(raw);
          final rid = _LedgerConsoleScreenState._dbString(
            readRow['reader_person_id'],
          ).trim();
          if (rid.isEmpty || rid == senderId) continue;
          final readStr = readRow['read_at'] as String?;
          final parsed = readStr != null ? DateTime.tryParse(readStr)?.toUtc() : null;
          if (parsed == null) continue;
          if (readAtByCounterparty == null || parsed.isAfter(readAtByCounterparty!)) {
            readAtByCounterparty = parsed;
          }
        }
        final messageId =
            _LedgerConsoleScreenState._dbString(row['id']).trim();
        if (messageId.isEmpty) {
          throw StateError('Message row missing id');
        }
        return _ExpectationMessageVm(
          id: messageId,
          senderPersonId: senderId,
          senderLabel: senderLabel,
          messageText: normalizeLoadedMessageText(row['message_text']),
          createdAt: DateTime.tryParse(
                _LedgerConsoleScreenState._dbString(row['created_at']),
              ) ??
              DateTime.now().toUtc(),
          attachments: attachments,
          messageType: messageType,
          readAtByCounterparty: readAtByCounterparty,
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
      _maybeMarkPeerChatReadsOnce(mapped);
      final synced = await syncExpectationChangelogReadWatermark(
        client: client,
        companyId: _companyId!,
        expectationId: widget.expectation.id,
        readerPersonId: _myPersonId!,
      );
      if (synced && mounted) {
        var maxChangelogUtc =
            DateTime.fromMillisecondsSinceEpoch(0, isUtc: true);
        var anyChangelog = false;
        for (final m in _messages) {
          if (!expectationMessageTypeIsChangelog(m.messageType)) continue;
          anyChangelog = true;
          final u = m.createdAt.toUtc();
          if (u.isAfter(maxChangelogUtc)) maxChangelogUtc = u;
        }
        setState(() {
          _changelogVisitBaselineUtc = anyChangelog
              ? maxChangelogUtc
              : DateTime.now().toUtc();
        });
        widget.onChangelogReadSynced?.call();
      }
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
      final hasFiles = _pendingAttachments.isNotEmpty;
      final messageType = hasFiles
          ? kExpectationMessageTypeChatWithAttachment
          : kExpectationMessageTypeChat;
      final messageId = await _insertExpectationMessage(
        text: text,
        type: messageType,
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
    final locale = Localizations.localeOf(context);
    final handle = widget.person?.handle;
    final (statusLabel, statusColor) = _statusMeta(_status, scheme);
    final (healthLabel, healthColor) = _healthMeta(_health, scheme);
    final canEdit = widget.canEdit;
    final currentUserId = Supabase.instance.client.auth.currentUser?.id;
    final canSendMessage = !_sendingMessage &&
        (_messageController.text.trim().isNotEmpty ||
            _pendingAttachments.isNotEmpty);
    final canDelete = canEdit &&
        widget.expectation.writerUserId != null &&
        widget.expectation.writerUserId == currentUserId;
    final isDiscussionPoint = _isDiscussionPoint(widget.expectation);
    final receiverPeopleById = <String, Person>{
      for (final p in widget.receiverPeople) p.id: p,
      if (widget.person != null) widget.person!.id: widget.person!,
    };
    final receiverLabel = isDiscussionPoint
        ? talkingPointMentionWhoLabel(
            widget.expectation.summary,
            persistedMentionHandles: widget.talkingPointPersistedMentions,
            persistedMentionPersonIds: widget.coReceiverPersonIds,
            peopleById: receiverPeopleById,
          )
        : expectationReceiverWhoLabel(
            summary: widget.expectation.summary,
            personDisplayName: widget.person?.displayName,
            personHandle: widget.person?.handle,
            personId: widget.expectation.personId,
            persistedMentionHandles: widget.talkingPointPersistedMentions,
          );
    final hasReceiver = receiverLabel != kLedgerAllMentionLabel;
    final inviteRecipients = widget.receiverPeople.isNotEmpty
        ? widget.receiverPeople
        : [
            if (widget.person != null) widget.person!,
          ];
    final receiversMissingEmail = inviteRecipients
        .where((p) => (p.email ?? '').trim().isEmpty)
        .toList();
    final showInviteForReceivers =
        canEdit && receiversMissingEmail.isNotEmpty;
    final inviteButtonLabel = receiversMissingEmail.length > 1
        ? 'Invite all'
        : 'Invite';
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
      updateRequestedAt: _updateRequestedAt,
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

    return PopScope(
      canPop: _canPopDetailsWithoutPrompt,
      onPopInvokedWithResult: (didPop, result) {
        if (didPop) return;
        if (_saving || _deleting) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('Please wait for the current action to finish.'),
            ),
          );
          return;
        }
        unawaited(_confirmUnsavedThenMaybeCloseDetails());
      },
      child: Container(
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
                    onPressed: (_saving || _deleting) ? null : _attemptCloseDetails,
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
                              Flexible(
                                child: Text(
                                  isDiscussionPoint
                                      ? receiverLabel
                                      : ledgerAtMentionLine(receiverLabel),
                                  style: theme.textTheme.bodyMedium?.copyWith(
                                    color: scheme.onSurface,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                              ),
                              if (showInviteForReceivers) ...[
                                const SizedBox(width: 8),
                                TextButton(
                                  onPressed: _inviting ? null : _inviteReceivers,
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
                                      : Text(inviteButtonLabel),
                                ),
                              ],
                            ],
                          ),
                        )
                      else if (isDiscussionPoint)
                        _DetailRow(
                          label: 'To',
                          value: talkingPointMentionWhoLabel(
                            widget.expectation.summary,
                            persistedMentionHandles:
                                widget.talkingPointPersistedMentions,
                            persistedMentionPersonIds: widget.coReceiverPersonIds,
                            peopleById: receiverPeopleById,
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
                          hint: _exactDateTimeLabel(widget.expectation.seenAt!, locale),
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
                          hint: _exactDateTimeLabel(widget.expectation.publishedAt!, locale),
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
                          hint: _exactDateTimeLabel(working.responsibleUpdatedAt!, locale),
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
                          hint: _exactDateTimeLabel(widget.expectation.createdAt, locale),
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
                        hint: _deadlineTooltip(working, locale),
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
                    if (_canRequestUpdate) ...[
                      Tooltip(
                        message:
                            'Requests an update from the receiver regarding health, deadline, or status.',
                        child: OutlinedButton(
                          onPressed: (_saving || _deleting || _requestingUpdate)
                              ? null
                              : _requestUpdate,
                          child: _requestingUpdate
                              ? const SizedBox(
                                  width: 16,
                                  height: 16,
                                  child: CircularProgressIndicator(strokeWidth: 2),
                                )
                              : const Text('Request'),
                        ),
                      ),
                      const SizedBox(width: 8),
                    ],
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
                        : (_messages.isNotEmpty ? 0 : 24),
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
                      ? ListView.separated(
                          shrinkWrap: true,
                          physics: const NeverScrollableScrollPhysics(),
                          itemCount: _messages.length,
                          separatorBuilder: (_, __) => const SizedBox(height: 14),
                          itemBuilder: (context, i) {
                            final m = _messages[i];
                            final mine = m.senderPersonId == _myPersonId;
                            final isChangelog =
                                expectationMessageTypeIsChangelog(m.messageType);
                            final isAttachmentChat = !isChangelog &&
                                (m.messageType ==
                                        kExpectationMessageTypeChatWithAttachment ||
                                    m.attachments.isNotEmpty);
                            final atSender = _bubbleAtSenderLabel(m.senderLabel);
                            final labelLine = isChangelog
                                ? 'Activity · $atSender · ${_chatRelativeLabel(m.createdAt)}'
                                : isAttachmentChat
                                    ? 'Attachment · $atSender · ${_chatRelativeLabel(m.createdAt)}'
                                    : '$atSender · ${_chatRelativeLabel(m.createdAt)}';
                            String bodyPreview() {
                              if (isChangelog) {
                                return expectationChangelogActivityFeedLine(
                                  messageType: m.messageType,
                                  messageText: m.messageText,
                                  expectationType: widget.expectation.type,
                                );
                              }
                              final t = m.messageText.trim();
                              if (t.isEmpty) {
                                if (m.attachments.isEmpty) {
                                  return '(no message)';
                                }
                                return m.attachments.length == 1
                                    ? 'Attachment: ${m.attachments.first.fileName}'
                                    : '${m.attachments.length} attachments';
                              }
                              return t;
                            }

                            String clipBody(String s, int max) {
                              if (s.length <= max) return s;
                              return '${s.substring(0, max)}…';
                            }

                            var previewRaw = bodyPreview();
                            if (previewRaw.trim().isEmpty) {
                              previewRaw = isChangelog
                                  ? '(empty changelog body)'
                                  : '(empty message body)';
                            }
                            final preview = clipBody(previewRaw, 280);
                            final listingTypeAccent = _isDiscussionPoint(widget.expectation)
                                ? LedgerListingAccents.topic
                                : LedgerListingAccents.expectation;
                            final isChangelogNewSinceVisit = isChangelog &&
                                m.createdAt.isAfter(_changelogVisitBaselineUtc);
                            final readStripeAlpha =
                                theme.brightness == Brightness.dark ? 0.30 : 0.48;
                            final bubbleFill = mine
                                ? (isChangelog
                                    ? scheme.primary.withValues(alpha: 0.14)
                                    : isAttachmentChat
                                        ? scheme.primary.withValues(alpha: 0.12)
                                        : scheme.primary.withValues(alpha: 0.2))
                                : (isChangelog
                                    ? scheme.surfaceContainerHighest.withValues(alpha: 0.72)
                                    : isAttachmentChat
                                        ? scheme.surfaceContainerHigh.withValues(alpha: 0.55)
                                        : scheme.tertiaryContainer.withValues(alpha: 0.88));
                            final bubbleMeBorder = scheme.primary.withValues(alpha: 0.45);
                            final bubbleOtherBorder =
                                scheme.onTertiaryContainer.withValues(alpha: 0.35);
                            final singleAttachmentOnly = !isChangelog &&
                                m.messageText.trim().isEmpty &&
                                m.attachments.length == 1;

                            Widget bodyNode() {
                              if (singleAttachmentOnly) {
                                final a = m.attachments.first;
                                return InkWell(
                                  onTap: () => _openAttachmentUrl(a.fileUrl),
                                  borderRadius: BorderRadius.circular(6),
                                  child: Padding(
                                    padding: const EdgeInsets.symmetric(vertical: 2),
                                    child: ConstrainedBox(
                                      constraints: const BoxConstraints(maxWidth: 460),
                                      child: Row(
                                        children: [
                                          Icon(
                                            Icons.attach_file_rounded,
                                            size: 20,
                                            color: scheme.primary,
                                          ),
                                          const SizedBox(width: 8),
                                          Expanded(
                                            child: Text(
                                              a.fileName,
                                              textAlign: mine
                                                  ? TextAlign.left
                                                  : TextAlign.right,
                                              style: theme.textTheme.bodyMedium?.copyWith(
                                                color: scheme.primary,
                                                decoration: TextDecoration.underline,
                                                height: 1.35,
                                                fontWeight: FontWeight.w500,
                                              ),
                                              maxLines: 2,
                                              overflow: TextOverflow.ellipsis,
                                            ),
                                          ),
                                        ],
                                      ),
                                    ),
                                  ),
                                );
                              }
                              if (isChangelog) {
                                return ExpectationChangelogMessageBody(
                                  messageType: m.messageType,
                                  messageText: m.messageText,
                                  expectationType: widget.expectation.type,
                                  theme: theme,
                                  scheme: scheme,
                                  textAlign: mine ? TextAlign.left : TextAlign.right,
                                  compact: true,
                                );
                              }
                              return SelectableText(
                                preview,
                                textAlign: mine ? TextAlign.left : TextAlign.right,
                                style: theme.textTheme.bodyMedium?.copyWith(
                                  color: scheme.onSurface,
                                  height: 1.35,
                                ),
                              );
                            }

                            final changelogStripeW =
                                isChangelogNewSinceVisit ? 4.0 : 2.5;
                            final conversationBubblePadding = isChangelog
                                ? EdgeInsets.fromLTRB(
                                    changelogStripeW + 8,
                                    8,
                                    8,
                                    8,
                                  )
                                : const EdgeInsets.all(12);
                            final conversationBubbleBody = Padding(
                              padding: conversationBubblePadding,
                              child: SizedBox(
                                width: double.infinity,
                                child: Column(
                                  crossAxisAlignment: mine
                                      ? CrossAxisAlignment.start
                                      : CrossAxisAlignment.end,
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Text(
                                      labelLine,
                                      textAlign: mine
                                          ? TextAlign.left
                                          : TextAlign.right,
                                      style: theme.textTheme.labelSmall?.copyWith(
                                        color: scheme.onSurfaceVariant,
                                        fontWeight:
                                            isChangelog ? FontWeight.w500 : FontWeight.w600,
                                        fontSize: isChangelog ? 11 : null,
                                        height: isChangelog ? 1.2 : null,
                                      ),
                                    ),
                                    SizedBox(height: isChangelog ? 5 : 8),
                                    bodyNode(),
                                    if (mine &&
                                        expectationMessageTypeIsChatRow(
                                            m.messageType)) ...[
                                      const SizedBox(height: 3),
                                      Tooltip(
                                        message: m.readAtByCounterparty != null
                                            ? 'Seen ${formatDisplayDateTime(m.readAtByCounterparty!, locale)}'
                                            : 'Delivered — opens as read when the other person views this thread',
                                        child: Icon(
                                          m.readAtByCounterparty != null
                                              ? Icons.done_all_rounded
                                              : Icons.done_rounded,
                                          size: 15,
                                          color: m.readAtByCounterparty != null
                                              ? scheme.primary
                                              : scheme.onSurfaceVariant
                                                  .withValues(alpha: 0.72),
                                        ),
                                      ),
                                    ],
                                  ],
                                ),
                              ),
                            );

                            return Padding(
                              key: ValueKey<String>('conv-msg-${m.id}'),
                              padding: const EdgeInsets.symmetric(horizontal: 10),
                              child: Align(
                                alignment: mine
                                    ? Alignment.centerLeft
                                    : Alignment.centerRight,
                                child: ConstrainedBox(
                                  constraints: BoxConstraints(
                                    minWidth: isChangelog ? 196 : 220,
                                    maxWidth: 520,
                                  ),
                                  child: isChangelog
                                      ? ClipRRect(
                                          borderRadius: BorderRadius.circular(10),
                                          child: Stack(
                                            clipBehavior: Clip.hardEdge,
                                            children: [
                                              Positioned.fill(
                                                child: DecoratedBox(
                                                  decoration: BoxDecoration(
                                                    color: bubbleFill,
                                                    border: Border.all(
                                                      color: mine
                                                          ? bubbleMeBorder
                                                          : bubbleOtherBorder,
                                                      width: 1.2,
                                                    ),
                                                  ),
                                                ),
                                              ),
                                              Positioned(
                                                left: 0,
                                                top: 0,
                                                bottom: 0,
                                                width: changelogStripeW,
                                                child: ColoredBox(
                                                  color: isChangelogNewSinceVisit
                                                      ? listingTypeAccent
                                                      : listingTypeAccent.withValues(
                                                          alpha: readStripeAlpha,
                                                        ),
                                                ),
                                              ),
                                              conversationBubbleBody,
                                            ],
                                          ),
                                        )
                                      : DecoratedBox(
                                          decoration: BoxDecoration(
                                            color: bubbleFill,
                                            borderRadius: BorderRadius.circular(10),
                                            border: Border.all(
                                              color: mine
                                                  ? bubbleMeBorder
                                                  : bubbleOtherBorder,
                                              width: 1.2,
                                            ),
                                          ),
                                          child: conversationBubbleBody,
                                        ),
                                ),
                              ),
                            );
                          },
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
                          hintText: 'Message (optional when attaching a file)...',
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
