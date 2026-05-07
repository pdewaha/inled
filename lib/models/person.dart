/// Individual — the "Who". [handle] is the short name after ! in capture.
class Person {
  const Person({
    required this.id,
    required this.createdAt,
    required this.displayName,
    required this.handle,
    this.authUserId,
    this.email,
    this.title,
  });

  final String id;
  final DateTime createdAt;
  final String displayName;
  final String handle;
  final String? authUserId;
  final String? email;
  final String? title;
}
