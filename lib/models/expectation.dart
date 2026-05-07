import 'package:inled/models/expectation_health.dart';
import 'package:inled/models/expectation_status.dart';
import 'package:inled/models/expectation_visibility.dart';

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
    this.progress,
    this.health = ExpectationHealth.unknown,
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
  /// 0..100, nullable when unknown.
  final int? progress;
  final ExpectationHealth health;
  final ExpectationStatus status;
  final ExpectationVisibility visibility;
}
