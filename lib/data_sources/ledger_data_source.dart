import 'package:exled/models/expectation.dart';
import 'package:exled/models/person.dart';

/// Replace with Supabase-backed implementation later.
abstract interface class LedgerDataSource {
  List<Person> getPeople();
  List<Expectation> getExpectations();
}
