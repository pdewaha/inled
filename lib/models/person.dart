/// Individual — the "Who". [handle] is the short name after ! in capture.
class Person {
  const Person({
    required this.id,
    required this.createdAt,
    required this.displayName,
    required this.handle,
  });

  final String id;
  final DateTime createdAt;
  final String displayName;
  final String handle;
}
