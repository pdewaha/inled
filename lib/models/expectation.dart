import 'package:exled/models/expectation_health.dart';
import 'package:exled/models/expectation_status.dart';
import 'package:exled/models/expectation_type.dart';
import 'package:exled/models/expectation_visibility.dart';

/// Specific handshake — the "How".
class Expectation {
  const Expectation({
    required this.id,
    required this.createdAt,
    this.writerUserId,
    required this.personId,
    required this.summary,
    required this.deadlineLabel,
    this.deadlineAt,
    this.finishedAt,
    this.responsibleUpdatedAt,
    this.publishedAt,
    this.seenAt,
    this.lastChattedSenderAt,
    this.lastChattedReceiverAt,
    this.updateRequestedAt,
    this.progress,
    this.health = ExpectationHealth.unknown,
    this.type = ExpectationType.expectation,
    required this.status,
    required this.visibility,
  });

  final String id;
  final DateTime createdAt;
  final String? writerUserId;
  final String personId;
  final String summary;
  final String deadlineLabel;
  final DateTime? deadlineAt;
  final DateTime? finishedAt;
  final DateTime? responsibleUpdatedAt;
  final DateTime? publishedAt;
  final DateTime? seenAt;
  final DateTime? lastChattedSenderAt;
  final DateTime? lastChattedReceiverAt;
  /// When non-null, the other party was asked for a substantive update; cleared on save when
  /// summary or status/health/deadline/progress changes.
  final DateTime? updateRequestedAt;
  /// 0..100, nullable when unknown.
  final int? progress;
  final ExpectationHealth health;
  final ExpectationType type;
  final ExpectationStatus status;
  final ExpectationVisibility visibility;
}
