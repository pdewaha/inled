import 'package:inled/data_sources/ledger_data_source.dart';
import 'package:inled/models/expectation.dart';
import 'package:inled/models/expectation_health.dart';
import 'package:inled/models/expectation_status.dart';
import 'package:inled/models/expectation_visibility.dart';
import 'package:inled/models/person.dart';

/// Static ledger — UI prototype only.
class LocalLedgerDataSource implements LedgerDataSource {
  const LocalLedgerDataSource();

  static final DateTime _t = DateTime.utc(2026, 5, 4, 9);

  @override
  List<Person> getPeople() => [
        Person(
          id: 'person_john',
          createdAt: _t,
          displayName: 'John Mercer',
          handle: 'John',
          authUserId: null,
          email: 'john.mercer@company.com',
          title: 'Head of Operations',
        ),
        Person(
          id: 'person_ava',
          createdAt: _t,
          displayName: 'Ava Lindström',
          handle: 'Ava',
          authUserId: null,
          email: 'ava.lindstrom@company.com',
          title: 'Engineering Lead',
        ),
      ];

  @override
  List<Expectation> getExpectations() => [
        Expectation(
          id: 'exp_1',
          createdAt: _t,
          personId: 'person_john',
          summary: 'Audit access reviews for prod admin roles.',
          deadlineLabel: 'Fri 9 May',
          deadlineAt: null,
          responsibleUpdatedAt: _t,
          publishedAt: _t,
          seenAt: null,
          progress: 35,
          health: ExpectationHealth.onTrack,
          status: ExpectationStatus.accepted,
          visibility: ExpectationVisibility.echo,
        ),
        Expectation(
          id: 'exp_2',
          createdAt: _t,
          personId: 'person_ava',
          summary: 'Publish error-budget policy draft to leadership.',
          deadlineLabel: 'Mon 12 May',
          deadlineAt: null,
          responsibleUpdatedAt: _t,
          publishedAt: null,
          seenAt: null,
          progress: 0,
          health: ExpectationHealth.unknown,
          status: ExpectationStatus.pending,
          visibility: ExpectationVisibility.shadow,
        ),
        Expectation(
          id: 'exp_3',
          createdAt: _t,
          personId: 'person_john',
          summary: 'Rotate legacy integration secrets.',
          deadlineLabel: 'Wed 30 Apr',
          deadlineAt: null,
          responsibleUpdatedAt: _t,
          publishedAt: _t,
          seenAt: null,
          progress: 80,
          health: ExpectationHealth.offTrack,
          status: ExpectationStatus.finished,
          visibility: ExpectationVisibility.echo,
        ),
      ];
}
