/// Board / Conseil — the "Why".
class Stakeholder {
  const Stakeholder({
    required this.id,
    required this.createdAt,
    required this.name,
    required this.ask,
  });

  final String id;
  final DateTime createdAt;
  final String name;
  final String ask;
}
