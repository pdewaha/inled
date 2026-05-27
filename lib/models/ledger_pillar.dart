import 'package:flutter/material.dart';

/// Sidebar / main-pane section.
///
/// Intent: remove ideation for now and focus on expectation entering + two
/// expectation views (towards me / towards others).
enum LedgerPillar {
  home,
  addExpectation,
  addTopic,
  expectationsPersonal,
  expectationsMe,
  expectationsOthers,
  people,
  tags,
}

/// Thin row accents (left stripe / icons). Row fills use [ColorScheme] neutrals only.
abstract final class LedgerListingAccents {
  /// Expectation rows (inbox, outbox, home list when type is expectation).
  static const expectation = Color(0xFF4ABAD8);

  /// Talking-point rows (tags pillar, home list when type is topic, etc.).
  static const topic = Color(0xFFD9BC5E);
}

extension LedgerPillarX on LedgerPillar {
  String get title => switch (this) {
        LedgerPillar.home => 'Welcome',
        LedgerPillar.addExpectation => 'Add expectation',
        LedgerPillar.addTopic => 'Add talking point',
        LedgerPillar.expectationsPersonal => 'Personal',
        LedgerPillar.expectationsMe => 'Inbox',
        LedgerPillar.expectationsOthers => 'Outbox',
        LedgerPillar.people => 'People',
        LedgerPillar.tags => 'Talking points',
      };

  String get description => switch (this) {
        // Home uses [_HomeDashboardPanel] as the only intro; no duplicate header copy.
        LedgerPillar.home => '',
        LedgerPillar.addExpectation =>
          'Write what you want someone to do. You must @mention who it is for '
          '(e.g. @name or @me). Optional #tags classify it. Save as draft or send when ready.',
        LedgerPillar.addTopic =>
          'Note something for later. Use #tags and @mentions for your own reference '
          '(saved to your notepad).',
        LedgerPillar.expectationsPersonal =>
          'Only you — self-authored expectations. Tag yourself with @me',
        LedgerPillar.expectationsMe =>
            'From others — as receiver or co-@mentioned.',
        LedgerPillar.expectationsOthers =>
            'By you — drafts and published to receivers.',
        LedgerPillar.people => 'Your colleagues',
        LedgerPillar.tags =>
          'Notepad: your talking points — @people and #tags for your own reference.',
      };

  /// Accent for sidebar selection chips and non-capture pillars.
  Color get accent => switch (this) {
        LedgerPillar.home => const Color(0xFFC8C8C8),
        LedgerPillar.addExpectation => const Color(0xFF42A8C8),
        LedgerPillar.addTopic => const Color(0xFFF0A050),
        LedgerPillar.expectationsPersonal => const Color(0xFFE8B86D),
        LedgerPillar.expectationsMe => const Color(0xFF7AE3B5),
        LedgerPillar.expectationsOthers => const Color(0xFF7AA3E8),
        LedgerPillar.people => const Color(0xFFC4A7FF),
        LedgerPillar.tags => LedgerListingAccents.topic,
      };

  /// Composer glow, main header bar, and capture-focused chrome.
  Color get captureAccent => switch (this) {
        LedgerPillar.home => const Color(0xFFF2F2F2),
        LedgerPillar.addExpectation => const Color(0xFF3EB8DC),
        LedgerPillar.addTopic => const Color(0xFFF0A855),
        LedgerPillar.expectationsPersonal =>
            const Color(0xFFE8B86D), // warm solo — distinct from shared expectation chrome
        LedgerPillar.expectationsMe => LedgerListingAccents.expectation,
        LedgerPillar.expectationsOthers => LedgerListingAccents.expectation,
        LedgerPillar.people => const Color(0xFFC4A7FF),
        LedgerPillar.tags => LedgerListingAccents.topic,
      };
}
