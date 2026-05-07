/// Deterministic lifecycle — no "in progress".
enum ExpectationStatus {
  pending,
  accepted,
  finished,
  abandoned,
}
