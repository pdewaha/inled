import 'package:flutter/material.dart';

/// Sidebar / thread context — pyramid layers.
enum LedgerPillar {
  stakeholders,
  goals,
  expectations,
  people,
}

extension LedgerPillarX on LedgerPillar {
  String get title => switch (this) {
        LedgerPillar.stakeholders => 'Stakeholders',
        LedgerPillar.goals => 'Goals',
        LedgerPillar.expectations => 'Expectations',
        LedgerPillar.people => 'People',
      };

  String get description => switch (this) {
        LedgerPillar.stakeholders =>
          'What the Board or Conseil expects from you — the why.',
        LedgerPillar.goals =>
          'Strategic objectives that answer those asks — the what.',
        LedgerPillar.expectations =>
          'Handshakes with your team — the how. Pending, Contracted, or Breached only.',
        LedgerPillar.people =>
          'Individuals responsible for those handshakes — the who.',
      };

  /// Accent for focus glow and sidebar selection (not full theme tint).
  Color get accent => switch (this) {
        LedgerPillar.stakeholders => const Color(0xFFE8B86D),
        LedgerPillar.goals => const Color(0xFF6EC9FF),
        LedgerPillar.expectations => const Color(0xFF7AE3B5),
        LedgerPillar.people => const Color(0xFFC4A7FF),
      };

  LedgerPillar get next => switch (this) {
        LedgerPillar.stakeholders => LedgerPillar.goals,
        LedgerPillar.goals => LedgerPillar.expectations,
        LedgerPillar.expectations => LedgerPillar.people,
        LedgerPillar.people => LedgerPillar.stakeholders,
      };
}
