import 'package:inled/utils/capture_parser.dart';

/// One row in the command thread (mock data or a user capture).
class FeedEntry {
  const FeedEntry({
    required this.id,
    required this.createdAt,
    required this.body,
    this.parse,
    this.linkedExpectationId,
    this.isUserCapture = false,
  });

  final String id;
  final DateTime createdAt;
  final String body;
  final CaptureParseResult? parse;
  final String? linkedExpectationId;
  final bool isUserCapture;
}
