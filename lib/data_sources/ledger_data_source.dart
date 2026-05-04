import 'package:inled/models/expectation.dart';
import 'package:inled/models/goal.dart';
import 'package:inled/models/person.dart';
import 'package:inled/models/stakeholder.dart';

/// Replace with Supabase-backed implementation later.
abstract interface class LedgerDataSource {
  List<Stakeholder> getStakeholders();
  List<Goal> getGoals();
  List<Person> getPeople();
  List<Expectation> getExpectations();
}
