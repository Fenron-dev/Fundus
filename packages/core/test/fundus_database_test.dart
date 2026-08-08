import 'package:fundus_core/fundus_core.dart';
import 'package:test/test.dart';

void main() {
  test('schema v1 is created atomically with FTS and session tables', () {
    final database = FundusDatabase.inMemory();
    addTearDown(database.close);

    expect(database.userVersion, FundusDatabase.schemaVersion);
    expect(database.tableExists('files'), isTrue);
    expect(database.tableExists('works'), isTrue);
    expect(database.tableExists('playback_sessions'), isTrue);
    expect(database.tableExists('search_index'), isTrue);
  });
}
