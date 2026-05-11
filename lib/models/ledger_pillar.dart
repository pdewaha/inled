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

/// Row backgrounds in feeds blend these with state (unpublished → published → finished).
abstract final class LedgerListingAccents {
  /// Expectation rows (inbox, outbox, home list when type is expectation).
  static const expectation = Color(0xFF52C8E5);

  /// Talking-point rows (tags pillar, home list when type is topic, etc.).
  static const topic = Color(0xFFE8C547);
}

extension LedgerPillarX on LedgerPillar {
  String get title => switch (this) {
        LedgerPillar.home => 'Home',
        LedgerPillar.addExpectation => 'Add expectation',
        LedgerPillar.addTopic => 'Add talking point',
        LedgerPillar.expectationsMe => 'Inbox',
        LedgerPillar.expectationsOthers => 'Outbox',
        LedgerPillar.people => 'People',
        LedgerPillar.tags => 'Talking points',
      };

  String get description => switch (this) {
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
        LedgerPillar.addExpectation => const Color(0xFF45B8D4),
        LedgerPillar.addTopic => const Color(0xFFFF9A4D),
        LedgerPillar.expectationsMe => const Color(0xFF7AE3B5),
        LedgerPillar.expectationsOthers => const Color(0xFF7AA3E8),
        LedgerPillar.people => const Color(0xFFC4A7FF),
        LedgerPillar.tags => LedgerListingAccents.topic,
      };

  /// Composer glow, main header bar, and capture-focused chrome.
  Color get captureAccent => switch (this) {
        LedgerPillar.home => const Color(0xFFF2F2F2),
        LedgerPillar.addExpectation => const Color(0xFF42C5EB),
        LedgerPillar.addTopic => const Color(0xFFFFA64D),
        LedgerPillar.expectationsMe => LedgerListingAccents.expectation,
        LedgerPillar.expectationsOthers => LedgerListingAccents.expectation,
        LedgerPillar.people => const Color(0xFFC4A7FF),
        LedgerPillar.tags => LedgerListingAccents.topic,
      };
}
