/// Strategic objective — the "What". [tag] matches console #tags.
class Goal {
  const Goal({
    required this.id,
    required this.createdAt,
    required this.stakeholderId,
    required this.title,
    required this.tag,
  });

  final String id;
  final DateTime createdAt;
  final String stakeholderId;
  final String title;
  final String tag;
}
