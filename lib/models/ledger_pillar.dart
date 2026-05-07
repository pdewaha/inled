import 'package:flutter/material.dart';

/// Sidebar / main-pane section.
///
/// Intent: remove ideation for now and focus on expectation entering + two
/// expectation views (towards me / towards others).
enum LedgerPillar {
  home,
  expectationsMe,
  expectationsOthers,
  people,
  tags,
}

extension LedgerPillarX on LedgerPillar {
  String get title => switch (this) {
        LedgerPillar.home => 'Home',
        LedgerPillar.expectationsMe => 'Towards me',
        LedgerPillar.expectationsOthers => 'Towards others',
        LedgerPillar.people => 'People',
        LedgerPillar.tags => 'Topics',
      };

  String get description => switch (this) {
        LedgerPillar.home =>
          'Capture a commitment line. Hit Enter to save it.',
        LedgerPillar.expectationsMe =>
          'Inbound commitments',
        LedgerPillar.expectationsOthers =>
          'Dispatched expectations',
        LedgerPillar.people => 'Your team and collaborators.',
        LedgerPillar.tags => 'Browse and manage topics grouped by #hashtags.',
      };

  /// Accent for focus glow and sidebar selection (not full theme tint).
  Color get accent => switch (this) {
        LedgerPillar.home => const Color(0xFFE8B86D),
        LedgerPillar.expectationsMe => const Color(0xFF7AE3B5),
        LedgerPillar.expectationsOthers => const Color(0xFF7AA3E8),
        LedgerPillar.people => const Color(0xFFC4A7FF),
        LedgerPillar.tags => const Color(0xFFE8D57A),
      };
}
