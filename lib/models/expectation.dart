import 'package:inled/models/expectation_status.dart';
import 'package:inled/models/expectation_visibility.dart';

/// Specific handshake — the "How".
class Expectation {
  const Expectation({
    required this.id,
    required this.createdAt,
    required this.personId,
    required this.goalId,
    required this.summary,
    required this.deadlineLabel,
    required this.status,
    required this.visibility,
  });

  final String id;
  final DateTime createdAt;
  final String personId;
  final String goalId;
  final String summary;
  final String deadlineLabel;
  final ExpectationStatus status;
  final ExpectationVisibility visibility;
}
