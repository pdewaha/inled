import 'package:flutter/material.dart';

/// Sidebar / main-pane context (data keys stay stable; labels live in [LedgerPillarX]).
enum LedgerPillar {
  stakeholders,
  goals,
  expectations,
  people,
}

/// Rail section **Expectations**: towards me, then towards others.
const List<LedgerPillar> kLedgerPillarExpectationsSection = [
  LedgerPillar.stakeholders,
  LedgerPillar.expectations,
];

/// Rail section **Team**: ideation and roster.
const List<LedgerPillar> kLedgerPillarTeamSection = [
  LedgerPillar.goals,
  LedgerPillar.people,
];

extension LedgerPillarX on LedgerPillar {
  String get title => switch (this) {
        LedgerPillar.stakeholders => 'Towards me',
        LedgerPillar.goals => 'Ideation',
        LedgerPillar.expectations => 'Towards others',
        LedgerPillar.people => 'People',
      };

  String get description => switch (this) {
        LedgerPillar.stakeholders =>
          'Expectations from my upper hierarchy or stakeholders.',
        LedgerPillar.goals =>
          'Launch ideation campaign to solve problem, and create objectives for others.',
        LedgerPillar.expectations =>
          'Expectations or tasks delegated to your team or others.',
        LedgerPillar.people => 'Your team and collaborators.',
      };

  /// Accent for focus glow and sidebar selection (not full theme tint).
  Color get accent => switch (this) {
        LedgerPillar.stakeholders => const Color(0xFFE8B86D),
        LedgerPillar.goals => const Color(0xFF6EC9FF),
        LedgerPillar.expectations => const Color(0xFF7AE3B5),
        LedgerPillar.people => const Color(0xFFC4A7FF),
      };

  /// Top-to-bottom rail order: **Expectations** section then **Team** (matches Tab cycle).
  LedgerPillar get next => switch (this) {
        LedgerPillar.stakeholders => LedgerPillar.expectations,
        LedgerPillar.expectations => LedgerPillar.goals,
        LedgerPillar.goals => LedgerPillar.people,
        LedgerPillar.people => LedgerPillar.stakeholders,
      };
}
