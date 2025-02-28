@TestOn('vm')
@Tags(['docker', 'mysql', 'slow'])
@Timeout(Duration(minutes: 4))
import 'package:bones_api/bones_api_db_mysql.dart';
import 'package:bones_api/bones_api_test_mysql.dart';
import 'package:test/test.dart';

import 'bones_api_entity_db_tests_base.dart';

final dbUser = 'myuser';
final dbPass = 'mypass';
final dbName = 'mydb';

class MySQLTestConfig extends APITestConfigDockerMySQL {
  MySQLTestConfig()
      : super({
          'db': {
            'mysql': {
              'username': dbUser,
              'password': dbPass,
              'database': dbName,
              'port': -3306,
            }
          }
        },
            containerNamePrefix: 'bones_api_test_mysql',
            forceNativePasswordAuthentication: true);
}

Future<void> main() async {
  await _runTest(false);
  await _runTest(true);
}

Future<bool> _runTest(bool useReflection) => runAdapterTests(
      'MySQL',
      MySQLTestConfig(),
      (provider, dbPort) => DBMySQLAdapter(
        dbName,
        dbUser,
        password: dbPass,
        host: '127.0.0.1',
        port: dbPort,
        parentRepositoryProvider: provider,
      ),
      (provider, dbPort) =>
          DBMemoryObjectAdapter(parentRepositoryProvider: provider),
      '`',
      'bigint unsigned',
      entityByReflection: useReflection,
    );
