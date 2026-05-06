import 'package:inled/models/expectation.dart';
import 'package:inled/models/person.dart';

/// Replace with Supabase-backed implementation later.
abstract interface class LedgerDataSource {
  List<Person> getPeople();
  List<Expectation> getExpectations();
}
