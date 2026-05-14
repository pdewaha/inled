import 'package:flutter/material.dart';

/// Sidebar / main-pane section.
///
/// Intent: remove ideation for now and focus on expectation entering + two
/// expectation views (towards me / towards others).
enum LedgerPillar {
  home,
  addExpectation,
  addTopic,
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
        LedgerPillar.expectationsMe => 'Inbox',
        LedgerPillar.expectationsOthers => 'Outbox',
        LedgerPillar.people => 'People',
        LedgerPillar.tags => 'Talking points',
      };

  String get description => switch (this) {
        // Home uses [_HomeDashboardPanel] as the only intro; no duplicate header copy.
        LedgerPillar.home => '',
        LedgerPillar.addExpectation =>
          'Capture an expectation. Use @mentions and #hashtags. Hit Enter to save it.',
        LedgerPillar.addTopic =>
          'Jot something to raise with someone later, or prep for a tagged '
          'thread (e.g. #weeklymeeting). #hashtags and @mentions help you find it.',
        LedgerPillar.expectationsMe =>
          'Expectations received from others',
        LedgerPillar.expectationsOthers =>
          'Dispatched expectations',
        LedgerPillar.people => 'Your colleagues',
        LedgerPillar.tags =>
          'Private: @people, private #tags, and prep only you see. Public: published '
          '#hashtags you (and others) chose to share.',
      };

  /// Accent for sidebar selection chips and non-capture pillars.
  Color get accent => switch (this) {
        LedgerPillar.home => const Color(0xFFC8C8C8),
        LedgerPillar.addExpectation => const Color(0xFF42A8C8),
        LedgerPillar.addTopic => const Color(0xFFF0A050),
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
        LedgerPillar.expectationsMe => LedgerListingAccents.expectation,
        LedgerPillar.expectationsOthers => LedgerListingAccents.expectation,
        LedgerPillar.people => const Color(0xFFC4A7FF),
        LedgerPillar.tags => LedgerListingAccents.topic,
      };
}
