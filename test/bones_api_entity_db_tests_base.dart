@Timeout(Duration(seconds: 180))
import 'dart:convert';
import 'dart:typed_data';

import 'package:bones_api/bones_api_logging.dart';
import 'package:bones_api/bones_api_test_vm.dart';
import 'package:collection/collection.dart';
import 'package:logging/logging.dart' as logging;
import 'package:statistics/statistics.dart';
import 'package:test/test.dart';

import 'bones_api_test_entities.dart';

final _log = logging.Logger('bones_api_test_adapter');

typedef DBAdapterCreator<A extends DBAdapter> = A Function(
    EntityRepositoryProvider? parentRepositoryProvider, int dbPort);

class TestEntityRepositoryProvider extends DBSQLEntityRepositoryProvider {
  final DBAdapterCreator<DBSQLAdapter> sqlAdapterCreator;
  final int dbPort;

  final EntityHandler<Store> storeEntityHandler;
  final EntityHandler<Address> addressEntityHandler;
  final EntityHandler<Role> roleEntityHandler;
  final EntityHandler<UserInfo> userInfoEntityHandler;
  final EntityHandler<User> userEntityHandler;

  late final StoreAPIRepository storeAPIRepository;
  late final AddressAPIRepository addressAPIRepository;
  late final RoleAPIRepository roleAPIRepository;
  late final UserInfoAPIRepository userInfoAPIRepository;
  late final UserAPIRepository userAPIRepository;

  TestEntityRepositoryProvider(
      this.storeEntityHandler,
      this.addressEntityHandler,
      this.roleEntityHandler,
      this.userInfoEntityHandler,
      this.userEntityHandler,
      this.sqlAdapterCreator,
      this.dbPort);

  @override
  Map<String, dynamic> get adapterConfig => {};

  @override
  FutureOr<DBSQLAdapter<Object>> buildAdapter() =>
      sqlAdapterCreator(this, dbPort);

  List<DBSQLEntityRepository<Object>>? _repositories;

  @override
  List<DBSQLEntityRepository<Object>> buildRepositories(
      DBSQLAdapter<Object> adapter) {
    return _repositories ??= [
      DBSQLEntityRepository<Store>(adapter, 'store', storeEntityHandler),
      DBSQLEntityRepository<Address>(adapter, 'address', addressEntityHandler),
      DBSQLEntityRepository<Role>(adapter, 'role', roleEntityHandler),
      DBSQLEntityRepository<UserInfo>(
          adapter, 'user_info', userInfoEntityHandler),
      DBSQLEntityRepository<User>(adapter, 'user', userEntityHandler)
    ].asUnmodifiableView;
  }

  @override
  FutureOr<List<Initializable>> extraDependencies() => [
        storeAPIRepository = StoreAPIRepository(this),
        addressAPIRepository = AddressAPIRepository(this),
        roleAPIRepository = RoleAPIRepository(this),
        userInfoAPIRepository = UserInfoAPIRepository(this),
        userAPIRepository = UserAPIRepository(this),
      ];
}

class TestEntityRepositoryProvider2 extends DBEntityRepositoryProvider {
  final DBAdapterCreator<DBAdapter> objectAdapterCreator;
  final int dbPort;

  final EntityHandler<Photo> photoEntityHandler;

  late final PhotoAPIRepository photoAPIRepository;

  TestEntityRepositoryProvider2(
      this.photoEntityHandler, this.objectAdapterCreator, this.dbPort);

  @override
  Map<String, dynamic> get adapterConfig => {};

  @override
  FutureOr<DBAdapter<Object>> buildAdapter() =>
      objectAdapterCreator(this, dbPort);

  List<DBEntityRepository<Object>>? _repositories;

  @override
  List<DBEntityRepository<Object>> buildRepositories(
      DBAdapter<Object> adapter) {
    return _repositories ??= [
      DBEntityRepository<Photo>(adapter, 'photo', photoEntityHandler),
    ].asUnmodifiableView;
  }

  @override
  FutureOr<List<Initializable>> extraDependencies() => [
        photoAPIRepository = PhotoAPIRepository(this),
      ];
}

TestEntityRepositoryProvider createEntityRepositoryProvider(
        bool entityByReflection,
        DBAdapterCreator<DBSQLAdapter> sqlAdapterCreator,
        int dbPort) =>
    entityByReflection
        ? TestEntityRepositoryProvider(
            Store$reflection().entityHandler,
            Address$reflection().entityHandler,
            Role$reflection().entityHandler,
            UserInfo$reflection().entityHandler,
            User$reflection().entityHandler,
            sqlAdapterCreator,
            dbPort,
          )
        : TestEntityRepositoryProvider(
            storeEntityHandler..inspectObject(Store.empty()),
            addressEntityHandler..inspectObject(Address.empty()),
            roleEntityHandler..inspectObject(Role.empty()),
            userInfoEntityHandler..inspectObject(UserInfo.empty()),
            userEntityHandler..inspectObject(User.empty()),
            sqlAdapterCreator,
            dbPort,
          );

TestEntityRepositoryProvider2 createEntityRepositoryProvider2(
        bool entityByReflection,
        DBAdapterCreator<DBAdapter> objectAdapterCreator,
        int dbPort) =>
    entityByReflection
        ? TestEntityRepositoryProvider2(
            Photo$reflection().entityHandler,
            objectAdapterCreator,
            dbPort,
          )
        : TestEntityRepositoryProvider2(
            photoEntityHandler..inspectObject(Photo.empty()),
            objectAdapterCreator,
            dbPort,
          );

const String png1PixelBase64 =
    'R0lGODlhAQABAIAAAP///wAAACH5BAEAAAAALAAAAAABAAEAAAICRAEAOw==';

const String png1PixelSha256 =
    'b1442e85b03bdcaf66dc58c7abb98745dd2687d86350be9a298a1d9382ac849b';

Future<bool> runAdapterTests(
    String dbName,
    APITestConfigDB testConfigDB,
    DBAdapterCreator<DBSQLAdapter> sqlAdapterCreator,
    DBAdapterCreator<DBAdapter> objectAdapterCreator,
    String cmdQuote,
    String serialIntType,
    {required bool entityByReflection}) async {
  _log.handler.logToConsole();

  User$reflection.boot();

  final testLog = logging.Logger(
      'TEST:SQLAdapter:$dbName${entityByReflection ? '+reflection' : ''}');

  testLog.info('[[[ Checking $testConfigDB ]]]');

  var configSupported = await testConfigDB.resolveSupported();

  if (!configSupported) {
    testLog
        .warning('[[[ ${testConfigDB.unsupportedReason} -> Skipping tests ]]]');
  }

  var testDomain = '${dbName.toLowerCase()}.com';

  group('SQLAdapter[$dbName${entityByReflection ? '+reflection' : ''}]', () {
    late final TestEntityRepositoryProvider entityRepositoryProvider;
    late final TestEntityRepositoryProvider2 entityRepositoryProvider2;

    setUpAll(() async {
      testLog.info('[[[ setUpAll ]]]');

      expect(configSupported, isTrue);

      var startOk = await testConfigDB.start();

      var dbPort = await testConfigDB.dbPort;

      testLog
          .info('Container start: $startOk > dbPort: $dbPort > $testConfigDB');

      entityRepositoryProvider = createEntityRepositoryProvider(
          entityByReflection, sqlAdapterCreator, dbPort);

      entityRepositoryProvider2 = createEntityRepositoryProvider2(
          entityByReflection, objectAdapterCreator, dbPort);

      await entityRepositoryProvider2.ensureInitialized();
      await entityRepositoryProvider.ensureInitialized();
    });

    tearDownAll(() async {
      testLog.info('[[[ tearDownAll ]]]');

      expect(configSupported, isTrue);

      entityRepositoryProvider.close();
      entityRepositoryProvider2.close();

      await testConfigDB.stop();
    });

    test('generateFullCreateTableSQLs', () async {
      var sqlAdapter = await entityRepositoryProvider.adapter;
      expect(sqlAdapter, isNotNull);

      var fullCreateTableSQLs = await sqlAdapter.generateFullCreateTableSQLs(
          title: 'Test Generated SQL', withDate: false);

      print(fullCreateTableSQLs);

      expect(fullCreateTableSQLs, contains('-- Test Generated SQL'));
      expect(fullCreateTableSQLs,
          contains('-- SQLAdapter: ${sqlAdapter.runtimeType}'));
      expect(fullCreateTableSQLs,
          contains('-- Dialect: ${sqlAdapter.dialect.name}'));
      expect(fullCreateTableSQLs,
          contains('-- Generator: BonesAPI/${BonesAPI.VERSION}'));

      expect(fullCreateTableSQLs, contains('-- Entity: Address @ address'));

      var q = sqlAdapter.dialect.elementQuote;
      var reS = r'(?:\s+|--[^\n]+\n?)+';
      var reAnyType = r'\w+[^\n]*?';
      var reArg = r'(?:\([^ \t\(\)]+\))';

      var tableAddressRegexp =
          RegExp('CREATE TABLE IF NOT EXISTS ${q}address$q \\($reS'
              '${q}id$q $reAnyType PRIMARY KEY,$reS'
              '${q}city$q VARCHAR$reArg?,$reS'
              '${q}number$q INT,$reS'
              '${q}state$q VARCHAR$reArg?,$reS'
              '${q}street$q VARCHAR$reArg?$reS'
              '\\)$reS;');

      expect(fullCreateTableSQLs, contains(tableAddressRegexp),
          reason: "`address` table SQL");

      var tableRoleRegexp =
          RegExp('CREATE TABLE IF NOT EXISTS ${q}role$q \\($reS'
              '${q}id$q $reAnyType PRIMARY KEY,$reS'
              '${q}enabled$q BOOLEAN,$reS'
              '${q}type$q $reAnyType,$reS'
              '${q}value$q DECIMAL$reArg?$reS'
              '\\)$reS;');

      expect(fullCreateTableSQLs, contains(tableRoleRegexp),
          reason: "`role` table SQL");

      var tableUserRegexp =
          RegExp('CREATE TABLE IF NOT EXISTS ${q}user$q \\(\\s*'
              '${q}id$q $reAnyType PRIMARY KEY,\\s*'
              '${q}address$q BIGINT[^,\\n]*?,\\s*'
              '${q}creation_time$q TIMESTAMP,\\s*'
              '${q}email$q VARCHAR$reArg?,\\s*'
              '${q}level$q INT,\\s*'
              '${q}password$q VARCHAR$reArg?,\\s*'
              '${q}photo$q VARCHAR$reArg?,\\s*'
              '${q}user_info$q BIGINT[^,\\n]*?,\\s*'
              '${q}wake_up_time$q TIME[^,\\n]*?,\\s*'
              'CONSTRAINT');

      print('-- Checking `user` table SQL...');

      var fullCreateTableSQLsNoComments =
          fullCreateTableSQLs.replaceAll(RegExp(r'--[^\n]+'), '');

      expect(fullCreateTableSQLsNoComments, contains(tableUserRegexp),
          reason: "`user` table SQL");

      var tableUserUniqueRegexp = RegExp('UNIQUE\\s\\(${q}email$q\\)');

      expect(fullCreateTableSQLs, contains(tableUserUniqueRegexp),
          reason: "`user.email` unique SQL");

      print('-- Tables SQL OK');
    });

    test('sqlAdapter', () async {
      _log.info('APITestConfigDB: $testConfigDB');

      expect(testConfigDB.isStarted, isTrue);

      var sqlAdapter = await entityRepositoryProvider.adapter;
      expect(sqlAdapter, isNotNull);

      _log.info('SQLDialect: ${sqlAdapter.dialect}');

      expect(sqlAdapter.capability.transactions, isTrue);
      expect(sqlAdapter.capability.transactionAbort, isTrue);
      expect(sqlAdapter.capability.fullTransaction, isTrue);

      expect(
          DBAdapter.registeredAdaptersNames.contains(sqlAdapter.name), isTrue);

      expect(DBAdapter.registeredAdaptersTypes.contains(sqlAdapter.runtimeType),
          isTrue);
    });

    test('objectAdapter', () async {
      _log.info('APITestConfigDB: $testConfigDB');

      expect(testConfigDB.isStarted, isTrue);

      var objectAdapter = await entityRepositoryProvider2.adapter;
      expect(objectAdapter, isNotNull);

      _log.info('ObjectDialect: ${objectAdapter.dialect}');

      expect(objectAdapter.capability.transactions, isTrue);
      expect(objectAdapter.capability.transactionAbort, isTrue);
      expect(objectAdapter.capability.fullTransaction, isTrue);

      expect(DBAdapter.registeredAdaptersNames.contains(objectAdapter.name),
          isTrue);

      expect(
          DBAdapter.registeredAdaptersTypes.contains(objectAdapter.runtimeType),
          isTrue);
    });

    test('create table', () async {
      if (testConfigDB is! APITestConfigDBSQL) {
        _log.info("Not a `APITestConfigDBSQL`: skipping table creation SQLs.");
        return;
      }

      expect(testConfigDB.isStarted, isTrue);

      if (testConfigDB is APITestConfigDocker) {
        var testConfigDocker = testConfigDB as APITestConfigDocker;
        print('----------------------------------------------');
        print(testConfigDocker.stdout);
        print('----------------------------------------------');
      }

      var sqlAdapter = await entityRepositoryProvider.adapter;
      expect(sqlAdapter, isA<DBSQLAdapter>());

      var fullCreateTableSQLs = await sqlAdapter.generateFullCreateTableSQLs(
          title: 'Test Generated SQL', withDate: false);

      var tables = await sqlAdapter.populateTables(fullCreateTableSQLs);

      _log.info("Populated tables: $tables");

      expect(
          tables,
          allOf(
            contains('address'),
            contains('user'),
            contains('role'),
            contains('address__stores__rel'),
            contains('address__closed_stores__rel'),
            contains('user__roles__rel'),
          ));

      var tablesNames = await testConfigDB.listTables();

      _log.info("Created tables: $tablesNames");

      expect(
          tablesNames,
          allOf(
            contains('address'),
            contains('user'),
            contains('role'),
            contains('address__stores__rel'),
            contains('address__closed_stores__rel'),
            contains('user__roles__rel'),
          ));
    });

    test('TestEntityRepositoryProvider', () async {
      var storeAPIRepository = entityRepositoryProvider.storeAPIRepository;
      var addressAPIRepository = entityRepositoryProvider.addressAPIRepository;
      var roleAPIRepository = entityRepositoryProvider.roleAPIRepository;
      var userInfoAPIRepository =
          entityRepositoryProvider.userInfoAPIRepository;
      var userAPIRepository = entityRepositoryProvider.userAPIRepository;
      var photoAPIRepository = entityRepositoryProvider2.photoAPIRepository;

      expect(await userAPIRepository.length(), equals(0));

      {
        var user = await userAPIRepository.selectByID(1);
        expect(user, isNull);

        expect((await userAPIRepository.selectAll()), isEmpty);

        expect((await userAPIRepository.existsID(1)), isFalse);
        expect((await userAPIRepository.existsID(2)), isFalse);
        expect((await userAPIRepository.existsID(3)), isFalse);
      }

      {
        var del = await userAPIRepository.deleteByQuery(' email == "foo" ');
        expect(del, isEmpty);
      }

      {
        var role = await roleAPIRepository.selectByID(1);
        expect(role, isNull);
      }

      var user1CreationTime = DateTime.utc(2021, 9, 20, 10, 11, 12, 0, 0);
      int user1Id;

      var store1 = Store('s11', 11);
      var store2 = Store('s12', 12);
      var storeClosed = Store('s9', 9);

      {
        var address = Address('NY', 'New York', 'street A', 101,
            stores: [store1, store2], closedStores: [storeClosed]);
        var role = Role(RoleType.admin);

        var photo = Photo.from(png1PixelBase64);

        expect(photo.id, equals(png1PixelSha256));
        expect(photo.data,
            equals(Uint8List.fromList(base64.decode(png1PixelBase64))));

        {
          var invalidUser = User('joe at $testDomain', '123', address, [role],
              level: 100, creationTime: user1CreationTime);

          expect(invalidUser.reflection.allFieldsValids(), isFalse);

          EntityFieldInvalid? error;
          try {
            await userAPIRepository.store(invalidUser);
          } on EntityFieldInvalid catch (e) {
            error = e;
          }

          expect(error, isNotNull);
          expect(error.toString(),
              contains('Invalid entity(User) field(email)> reason: regexp'));
        }

        {
          var invalidAddress = Address('NYXZ', 'New York', 'street A', 101);
          var role = Role(RoleType.admin);

          var user = User('joe@$testDomain', '123', invalidAddress, [role],
              level: 100, creationTime: user1CreationTime);

          expect(user.reflection.allFieldsValids(), isFalse);

          EntityFieldInvalid? error;
          try {
            await userAPIRepository.store(user);
          } on EntityFieldInvalid catch (e) {
            error = e;
          }

          expect(error, isNotNull);
          expect(
              error.toString(),
              contains(
                  'Invalid entity(Address) field(state)> reason: maximum(3)'));
        }

        expect((await storeAPIRepository.selectAll()).length, equals(0));
        expect((await addressAPIRepository.selectAll()).length, equals(0));
        expect((await userInfoAPIRepository.selectAll()).length, equals(0));
        expect((await userAPIRepository.selectAll()).length, equals(0));

        expect((await photoAPIRepository.count()), equals(0));

        var user = User('joe@$testDomain', '123', address, [role],
            level: 100,
            userInfo: UserInfo('The user joe'),
            photo: photo,
            creationTime: user1CreationTime);

        expect(user.reflection.allFieldsValids(), isTrue);

        var id = await userAPIRepository.store(user);
        expect(id, equals(1));

        user1Id = id;

        expect(user.id, equals(1));
        expect(user.userInfo.id, equals(1));
        expect(address.id, equals(1));
        expect(role.id, equals(1));
        expect(user.userInfo.id, equals(1));
        expect(user.userInfo.entity?.id, equals(1));

        expect(user.address.isEntityReference, isFalse);
        expect(user.userInfo.isEntityReference, isTrue);

        expect(user.address.resolveEntityInstance, isA<Address>());
        expect(user.userInfo.resolveEntityInstance, isA<UserInfo>());
        expect(user.photo.resolveEntityInstance, isA<Photo>());

        expect((await userInfoAPIRepository.selectAll()).length, equals(1));
        expect((await userAPIRepository.selectAll()).length, equals(1));
        expect((await addressAPIRepository.selectAll()).length, equals(1));
        expect((await storeAPIRepository.selectAll()).length, equals(3));

        expect((await photoAPIRepository.count()), equals(1));

        expect((await userInfoAPIRepository.existsID(1)), isTrue);
        expect((await userAPIRepository.existsID(1)), isTrue);
        expect((await addressAPIRepository.existsID(1)), isTrue);

        expect((await photoAPIRepository.existsID(png1PixelSha256)), isTrue);

        {
          var user = await userAPIRepository.selectByID(1);
          expect(user!.email, equals('joe@$testDomain'));

          expect(user.userInfo.isNull, isFalse);
          expect(user.userInfo.id, equals(1));
          expect(user.userInfo.isEntitySet, isFalse);

          expect(user.photo?.id, equals(png1PixelSha256));
          expect(user.photo?.data, equals(base64.decode(png1PixelBase64)));
        }

        {
          var sel1 = await addressAPIRepository.selectByStore(store1);

          expect(sel1.length, equals(1));
          expect(sel1.first.number, equals(101));

          var sel2 = await addressAPIRepository.selectByStore(storeClosed);
          expect(sel2, isEmpty);
        }

        {
          var sel1 =
              await addressAPIRepository.selectByClosedStore(storeClosed);

          expect(sel1.length, equals(1));
          expect(sel1.first.number, equals(101));

          var sel2 = await addressAPIRepository.selectByClosedStore(store2);
          expect(sel2, isEmpty);
        }

        {
          var user = await userAPIRepository.selectByID(1,
              resolutionRules:
                  EntityResolutionRules.fetch(eagerEntityTypes: [UserInfo]));
          expect(user!.email, equals('joe@$testDomain'));

          expect(user.userInfo.isNull, isFalse);
          expect(user.userInfo.id, equals(1));
          expect(user.userInfo.isEntitySet, isTrue);
          expect(user.userInfo.entityToJson(),
              equals(UserInfo('The user joe', id: 1).toJson()));
        }

        expect((await addressAPIRepository.selectByID(1))?.city,
            equals('New York'));

        expect(
            (await addressAPIRepository.selectByID(1))
                ?.stores
                .map((e) => e.name),
            equals(['s11', 's12']));

        expect(
            (await addressAPIRepository.selectByID(1))?.closedStores.entities,
            isNull);

        expect(
            (await addressAPIRepository.selectByID(1,
                    resolutionRules: EntityResolutionRules.fetchEagerAll()))
                ?.closedStores
                .entities
                ?.map((e) => e?.name)
                .toList(),
            equals(['s9']));

        expect((await userAPIRepository.selectByAddress(address)).single.email,
            equals('joe@$testDomain'));
        expect(
            (await userAPIRepository.selectByAddressID(address.id!))
                .single
                .email,
            equals('joe@$testDomain'));

        expect((await userAPIRepository.selectByRole(role)).single.email,
            equals('joe@$testDomain'));

        expect((await userAPIRepository.selectByRoleId(role.id!)).single.email,
            equals('joe@$testDomain'));

        var userDuplicated = User('joe@$testDomain', '456', address, [role],
            level: 100, creationTime: user1CreationTime);

        EntityFieldInvalid? error;
        try {
          await userAPIRepository.store(userDuplicated);
        } on EntityFieldInvalid catch (e) {
          error = e;
        }

        expect(error, isA<EntityFieldInvalid>());
        expect(
          error.toString(),
          matches(RegExp(
              r'Invalid entity\((?:User)?@table:user\) field(?:\(.*?email.*?\))?> reason: unique ; value: <.*?joe@\w+\.com.*?>.*',
              dotAll: true)),
        );
      }

      var user2CreationTime = DateTime.utc(2021, 9, 21, 22, 11, 12, 0, 0);
      var user2WakeupTime = Time(9, 10, 11);

      int user2Id;

      {
        var address = Address('CA', 'Los Angeles', 'street B', 201);

        var user = User('smith@$testDomain', 'abc', address,
            [Role(RoleType.guest, value: Decimal.parse('123.45'))],
            wakeUpTime: user2WakeupTime, creationTime: user2CreationTime);

        final id = await userAPIRepository.store(user);
        expect(id, greaterThanOrEqualTo(2));

        user2Id = id;

        expect((await userAPIRepository.selectAll()).length, equals(2));

        var user2 = await userAPIRepository.selectByID(id);

        expect(user2!.userInfo.isNull, isTrue);
        expect(user2.wakeUpTime, equals(user2WakeupTime));

        user2.wakeUpTime = null;
        var id2 = await userAPIRepository.store(user2);
        expect(id2, equals(id));

        user2 = await userAPIRepository.selectByID(id);
        expect(user2!.wakeUpTime, isNull);

        user2.wakeUpTime = user2WakeupTime;
        id2 = await userAPIRepository.store(user2);
        expect(id2, equals(id));

        user2 = await userAPIRepository.selectByID(id);
        expect(user2!.wakeUpTime, equals(user2WakeupTime));

        var user2Role = user2.roles.first;

        expect((await userAPIRepository.selectByRole(user2Role)).first,
            equals(user2));
        expect((await userAPIRepository.selectByRoleId(user2Role.id!)).first,
            equals(user2));
      }

      var user3CreationTime = DateTime.utc(2021, 9, 22);
      var user3WakeupTime = Time(12, 10, 11);

      int user3Id;

      {
        var address = Address('CA', 'Los Angeles', 'street B', 101);

        var user = User('john@$testDomain', '456', address, [],
            wakeUpTime: user3WakeupTime, creationTime: user3CreationTime);
        var id = await userAPIRepository.store(user);
        expect(id, greaterThanOrEqualTo(3));

        user3Id = id;
      }

      expect(await addressAPIRepository.length(), equals(3));
      expect(await userAPIRepository.length(), equals(3));

      {
        var sel1 = await addressAPIRepository.selectByStore(store1);

        expect(sel1.length, equals(1));
        expect(sel1.first.number, equals(101));

        var sel2 = await addressAPIRepository.selectByStore(storeClosed);
        expect(sel2, isEmpty);
      }

      {
        var sel1 = await addressAPIRepository.selectByClosedStore(storeClosed);

        expect(sel1.length, equals(1));
        expect(sel1.first.number, equals(101));

        var sel2 = await addressAPIRepository.selectByClosedStore(store2);
        expect(sel2, isEmpty);
      }

      {
        var user = await userAPIRepository.selectByID(user1Id);
        expect(user!.email, equals('joe@$testDomain'));
        expect(user.address.state, equals('NY'));
        expect(
            user.roles.map(
                (e) => entityByReflection ? e.toJsonFromFields() : e.toJson()),
            equals([
              {'enabled': true, 'id': 1, 'type': 'admin', 'value': null}
            ]));
        expect(user.level, equals(100));
        expect(user.wakeUpTime, isNull);
        expect(user.creationTime, equals(user1CreationTime));

        var user2 = await userAPIRepository.selectByEmail('joe@$testDomain');
        expect(user2!.toJsonEncoded(), equals(user.toJsonEncoded()));

        var user3 = (await userAPIRepository.select(
                Condition.parse('email == ?'),
                parameters: ['joe@$testDomain']))
            .first;
        expect(user3.toJsonEncoded(), equals(user.toJsonEncoded()));

        var user4 = (await userAPIRepository.select(
                Condition.parse('email == ?'),
                parameters: ['joex@$testDomain']))
            .firstOrNull;
        expect(user4, isNull);
      }

      {
        var user = await userAPIRepository.selectByID(user2Id);
        expect(user!.email, equals('smith@$testDomain'));
        expect(user.address.state, equals('CA'));
        expect(
            user.roles.map(
                (e) => entityByReflection ? e.toJsonFromFields() : e.toJson()),
            anyOf(
                equals([
                  {
                    'id': 2,
                    'type': 'guest',
                    'enabled': true,
                    'value': '123.4500'
                  }
                ]),
                equals([
                  {
                    'id': 2,
                    'type': 'guest',
                    'enabled': true,
                    'value': '123.45',
                  }
                ])));
        expect(user.level, isNull);
        expect(user.wakeUpTime, user2WakeupTime);
        expect(user.creationTime, equals(user2CreationTime));
      }

      {
        var user = await userAPIRepository.selectByID(user3Id);
        expect(user!.email, equals('john@$testDomain'));
        expect(user.address.state, equals('CA'));
        expect(user.roles, isEmpty);
        expect(user.level, isNull);
        expect(user.wakeUpTime, user3WakeupTime);
        expect(user.creationTime, equals(user3CreationTime));
      }

      {
        var user = await userAPIRepository.selectByID(3000);
        expect(user, isNull);
      }

      {
        var user = await userAPIRepository.selectByEmail('joe@$testDomain');
        expect(user!.email, equals('joe@$testDomain'));
        expect(user.address.state, equals('NY'));
      }

      {
        var user = await userAPIRepository.selectByEmail('smith@$testDomain');
        expect(user!.email, equals('smith@$testDomain'));
        expect(user.address.state, equals('CA'));
      }

      {
        var sel = await userAPIRepository.selectByAddressState('NY');

        var user = sel.first;
        expect(user.email, equals('joe@$testDomain'));
        expect(user.address.state, equals('NY'));
      }

      {
        var sel = await userAPIRepository.selectByINAddressStates(['NY', 'CA']);

        expect(sel.length, equals(3));
        expect(sel.map((e) => e.address.state),
            unorderedEquals(['NY', 'CA', 'CA']));
      }

      {
        var user = await userAPIRepository.selectByEmail('joe@$testDomain');
        expect(user!.email, equals('joe@$testDomain'));

        expect(user.id, greaterThanOrEqualTo(1));
        expect(user.roles.length, equals(1));

        user.roles.add(Role(RoleType.unknown));

        expect(await userAPIRepository.store(user), equals(user.id));
        expect(user.roles.length, equals(2));

        var user2 = await userAPIRepository.selectByID(user.id);
        expect(user2!.roles.length, equals(2));
        expect(user2.roles.map((e) => e.id), unorderedEquals([1, 3]));
        expect(user2.roles.map((e) => e.type),
            unorderedEquals([RoleType.admin, RoleType.unknown]));

        expect(user2.password, equals('123'));
        user2.password = '321';

        expect(await userAPIRepository.store(user2), equals(user.id));
        expect(user2.roles.length, equals(2));

        var user3 = await userAPIRepository.selectByID(user.id);

        expect(user3!.password, equals('321'));

        expect(user3.roles.length, equals(2));
        expect(user3.roles.map((e) => e.id), unorderedEquals([1, 3]));
        expect(user3.roles.map((e) => e.type),
            unorderedEquals([RoleType.admin, RoleType.unknown]));
      }

      {
        var transaction = Transaction();

        var result = await transaction.execute(() async {
          var sel =
              await userAPIRepository.selectByINAddressStates(['NY', 'CA']);

          expect(sel.length, equals(3));
          expect(sel.map((e) => e.address.state),
              unorderedEquals(['NY', 'CA', 'CA']));

          expect(sel.map((e) => e.userInfo.entity?.info),
              equals([null, null, null]));

          var sel2 =
              await userAPIRepository.selectByINAddressStates(['NY', 'CA']);

          expect(sel2.length, equals(3));
          expect(sel2.map((e) => e.address.state),
              unorderedEquals(['NY', 'CA', 'CA']));

          return sel2;
        });

        print(transaction);

        expect(result!.length, equals(3));
        expect(transaction.isAborted, isFalse);
        expect(transaction.length, equals(9));
        expect(transaction.cachedEntitiesLength, equals(12));
      }

      {
        var transaction = Transaction();

        var result = await transaction.execute(() async {
          var sel = await userAPIRepository.selectByINAddressStates(
              ['NY', 'CA'],
              resolutionRules: EntityResolutionRules.fetchEagerAll());

          expect(sel.length, equals(3));
          expect(sel.map((e) => e.address.state),
              unorderedEquals(['NY', 'CA', 'CA']));

          expect(sel.map((e) => e.userInfo.entity?.info).toList(),
              unorderedEquals(['The user joe', null, null]));

          var sel2 =
              await userAPIRepository.selectByINAddressStates(['NY', 'CA']);

          expect(sel2.length, equals(3));
          expect(sel2.map((e) => e.address.state),
              unorderedEquals(['NY', 'CA', 'CA']));

          return sel2;
        });

        print(transaction);

        expect(result!.length, equals(3));
        expect(transaction.isAborted, isFalse);
        expect(transaction.length, equals(10));
        expect(transaction.cachedEntitiesLength, equals(13));
      }

      {
        var transaction = Transaction();

        var result = await transaction.execute(() async {
          var sel =
              await userAPIRepository.selectByINAddressStates(['NY', 'CA']);

          expect(sel.length, equals(3));
          expect(sel.map((e) => e.address.state),
              unorderedEquals(['NY', 'CA', 'CA']));

          expect(sel.map((e) => e.userInfo.entity?.info).toList(),
              equals([null, null, null]));

          var user1 = sel.first;

          user1.level = 123;

          var storeId = await userAPIRepository.store(user1);
          expect(storeId, equals(user1.id));

          var sel2 =
              await userAPIRepository.selectByINAddressStates(['NY', 'CA']);

          expect(sel2.length, equals(3));
          expect(sel2.map((e) => e.address.state),
              unorderedEquals(['NY', 'CA', 'CA']));

          return sel2;
        });

        print(transaction);

        expect(result!.length, equals(3));
        expect(transaction.isAborted, isFalse);
        expect(transaction.length, greaterThanOrEqualTo(7));
        expect(transaction.cachedEntitiesLength, equals(12));
      }

      {
        var transaction = Transaction();

        var result = await transaction.execute(() async {
          var sel = await userAPIRepository.selectByINAddressStates(
              ['NY', 'CA'],
              resolutionRules: EntityResolutionRules.fetchEagerAll());

          expect(sel.length, equals(3));
          expect(sel.map((e) => e.address.state),
              unorderedEquals(['NY', 'CA', 'CA']));

          expect(sel.map((e) => e.userInfo.entity?.info).toList(),
              unorderedEquals(['The user joe', null, null]));

          var user1 = sel.first;

          user1.level = 123;

          var storeId = await userAPIRepository.store(user1);
          expect(storeId, equals(user1.id));

          var sel2 =
              await userAPIRepository.selectByINAddressStates(['NY', 'CA']);

          expect(sel2.length, equals(3));
          expect(sel2.map((e) => e.address.state),
              unorderedEquals(['NY', 'CA', 'CA']));

          return sel2;
        });

        print(transaction);

        expect(result!.length, equals(3));
        expect(transaction.isAborted, isFalse);
        expect(transaction.length, greaterThanOrEqualTo(7));
        expect(transaction.cachedEntitiesLength, equals(13));
      }

      {
        var transaction = Transaction();

        var result = await transaction.execute(() async {
          var sel =
              await userAPIRepository.selectByINAddressStates(['NY', 'CA']);

          expect(sel.length, equals(3));
          expect(sel.map((e) => e.address.state),
              unorderedEquals(['NY', 'CA', 'CA']));

          expect(sel.map((e) => e.userInfo.entity?.info).toList(),
              equals([null, null, null]));

          var user1 = sel.firstWhere((e) => e.address.state == 'NY');

          user1.address.city = 'Jersey City';

          var storeId = await userAPIRepository.store(user1);
          expect(storeId, equals(user1.id));

          var sel2 =
              await userAPIRepository.selectByINAddressStates(['NY', 'CA']);

          expect(sel2.length, equals(3));
          expect(sel2.map((e) => e.address.state),
              unorderedEquals(['NY', 'CA', 'CA']));

          var user2 = sel.firstWhere((e) => e.address.state == 'NY');

          expect(user2.address.city, equals('Jersey City'));

          return sel2;
        });

        print(transaction);

        expect(result!.length, equals(3));
        expect(transaction.length, greaterThanOrEqualTo(8));
        expect(transaction.cachedEntitiesLength, equals(12));
      }

      {
        var transaction = Transaction();

        var result = await transaction.execute(() async {
          var sel = await userAPIRepository.selectByINAddressStates(
              ['NY', 'CA'],
              resolutionRules: EntityResolutionRules.fetchEagerAll());

          expect(sel.length, equals(3));
          expect(sel.map((e) => e.address.state),
              unorderedEquals(['NY', 'CA', 'CA']));

          expect(sel.map((e) => e.userInfo.entity?.info).toList(),
              unorderedEquals(['The user joe', null, null]));

          var user1 = sel.firstWhere((e) => e.address.state == 'NY');

          user1.address.city = 'Jersey City';

          var storeId = await userAPIRepository.store(user1);
          expect(storeId, equals(user1.id));

          var sel2 =
              await userAPIRepository.selectByINAddressStates(['NY', 'CA']);

          expect(sel2.length, equals(3));
          expect(sel2.map((e) => e.address.state),
              unorderedEquals(['NY', 'CA', 'CA']));

          var user2 = sel.firstWhere((e) => e.address.state == 'NY');

          expect(user2.address.city, equals('Jersey City'));

          return sel2;
        });

        print(transaction);

        expect(result!.length, equals(3));
        expect(transaction.length, greaterThanOrEqualTo(8));
        expect(transaction.cachedEntitiesLength, equals(13));
      }

      {
        var sel = await userAPIRepository
            .selectByINAddressStates(['NY', 'CA', 'N/A']);

        expect(sel.length, equals(3));
        expect(sel.map((e) => e.address.state),
            unorderedEquals(['NY', 'CA', 'CA']));
        expect(sel.map((e) => e.address.city),
            unorderedEquals(['Los Angeles', 'Los Angeles', 'Jersey City']));
      }

      {
        var sel = await userAPIRepository.selectByINAddressStates(['NY']);

        expect(sel.length, equals(1));
        expect(sel.map((e) => e.address.state), equals(['NY']));
      }

      {
        var sel =
            await userAPIRepository.selectByINAddressStatesSingleValue('CA');

        expect(sel.length, equals(2));
        expect(sel.map((e) => e.address.state), unorderedEquals(['CA', 'CA']));
      }

      {
        var sel = await userAPIRepository.selectByINAddressStates(
            ['NY', 'CA', ...List.generate(10, (i) => '$i')]);

        expect(sel.length, equals(3));
        expect(sel.map((e) => e.address.state),
            unorderedEquals(['NY', 'CA', 'CA']));
      }

      {
        var sel = await userAPIRepository.selectByINAddressStates(
            ['NY', 'CA', ...List.generate(100, (i) => '$i')]);

        expect(sel.length, equals(3));
        expect(sel.map((e) => e.address.state),
            unorderedEquals(['NY', 'CA', 'CA']));
      }

      {
        var sel = await userAPIRepository.selectByRoleType('admin');

        var user = sel.first;
        print(entityByReflection ? user.toJsonFromFields() : user.toJson());

        expect(user.email, equals('joe@$testDomain'));
        expect(user.address.state, equals('NY'));

        var sel2 = await userAPIRepository.selectByRole(user.roles.first);
        var user2 = sel2.first;
        expect(user2.id, equals(user.id));
      }

      {
        var sel = await userAPIRepository.selectByRoleType('guest');

        var user = sel.first;
        print(entityByReflection ? user.toJsonFromFields() : user.toJson());

        expect(user.email, equals('smith@$testDomain'));
        expect(user.address.state, equals('CA'));

        var sel2 = await userAPIRepository.selectByRole(user.roles.first);
        var user2 = sel2.first;
        expect(user2.id, equals(user.id));
      }

      {
        var sel = await userAPIRepository.selectByAddressState('CA');

        expect(sel.length, equals(2));

        expect(sel.map((e) => e.email),
            unorderedEquals(['smith@$testDomain', 'john@$testDomain']));

        expect(sel.map((e) => e.address.state), equals(['CA', 'CA']));

        var user = sel.firstWhere((e) => e.email.startsWith('smith'));
        expect(user.email, equals('smith@$testDomain'));
        expect(user.address.state, equals('CA'));

        user.email = 'smith2@$testDomain';

        var ok = await userAPIRepository.store(user);
        expect(ok, equals(user.id));
      }

      {
        var user = await userAPIRepository.selectByEmail('smith2@$testDomain');

        expect(user!.email, equals('smith2@$testDomain'));
        expect(user.address.state, equals('CA'));

        user.email = 'smith3@$testDomain';

        var ok = await userAPIRepository.store(user);
        expect(ok, equals(user.id));

        var user2 = await userAPIRepository.selectByEmail('smith3@$testDomain');

        expect(user2!.id, equals(user.id));
        expect(user2.email, equals('smith3@$testDomain'));
      }

      {
        var transaction = Transaction();

        var result = await transaction.execute(() async {
          var executingTransaction = Transaction.executingTransaction;
          expect(executingTransaction, isNotNull);
          expect(executingTransaction!.isEmpty, isTrue);

          var user =
              await userAPIRepository.selectByEmail('smith3@$testDomain');

          expect(executingTransaction.isNotEmpty, isTrue);

          expect(user!.email, equals('smith3@$testDomain'));
          expect(user.address.state, equals('CA'));

          user.email = 'smith4@$testDomain';
          var ok = await userAPIRepository.store(user);
          expect(ok, equals(user.id));

          var user2 =
              await userAPIRepository.selectByEmail('smith4@$testDomain');

          expect(user2!.email, equals('smith4@$testDomain'));

          return user2.email;
        });

        print(transaction);

        expect(result, equals('smith4@$testDomain'));

        expect(transaction.isOpen, isTrue);
        expect(transaction.isAborted, isFalse);
        expect(transaction.isCommitted, isTrue);
        expect(transaction.length, greaterThanOrEqualTo(7));
        expect(transaction.abortedError, isNull);
      }

      var sqlAdapter = await entityRepositoryProvider.adapter;

      // If `Transaction.abort` is supported:
      if (sqlAdapter.capability.transactionAbort) {
        var transaction = Transaction();

        var result = await transaction.execute(() async {
          try {
            var user =
                await userAPIRepository.selectByEmail('smith4@$testDomain');

            expect(user!.email, equals('smith4@$testDomain'));

            user.email = 'smith5@$testDomain';
            var ok = await userAPIRepository.store(user);
            expect(ok, equals(user.id));

            transaction.abort(reason: 'Test');
          } catch (e, s) {
            print(e);
            print(s);
          }
        });

        print(transaction);

        expect(result, isNull);

        expect(transaction.isOpen, isTrue);
        expect(transaction.isAborted, isTrue);
        expect(transaction.isCommitted, isFalse);
        expect(transaction.length, greaterThanOrEqualTo(6));
        expect(transaction.abortedError, isNotNull);
        expect(transaction.abortedError?.reason, equals('Test'));
      }

      {
        var user = await userAPIRepository.selectByID(user2Id);

        expect(user!.email, equals('smith4@$testDomain'));

        user.roles.add(Role(RoleType.unknown));

        var ok = await userAPIRepository.store(user);
        expect(ok, equals(user.id));

        var rolesJson2a = [
          {'id': 2, 'type': 'guest', 'enabled': true, 'value': '123.4500'},
          {'id': 4, 'type': 'unknown', 'enabled': true, 'value': null}
        ];

        var rolesJson2b = [
          {'id': 2, 'type': 'guest', 'enabled': true, 'value': '123.45'},
          {'id': 4, 'type': 'unknown', 'enabled': true, 'value': null}
        ];

        expect(
            user.roles.map(
                (e) => entityByReflection ? e.toJsonFromFields() : e.toJson()),
            anyOf(equals(rolesJson2a), equals(rolesJson2b)));

        var user2 = await userAPIRepository.selectByID(user.id);
        expect(user2!.email, equals(user.email));
        expect(
            user2.roles.map(
                (e) => entityByReflection ? e.toJsonFromFields() : e.toJson()),
            anyOf(equals(rolesJson2a), equals(rolesJson2b)));

        user2.roles.removeWhere((r) => r.type == RoleType.guest);

        var ok2 = await userAPIRepository.store(user2);
        expect(ok2, equals(user.id));

        var user3 = await userAPIRepository.selectByID(user.id);
        expect(user3!.email, equals(user.email));

        var rolesJson3 = [
          {'id': 4, 'type': 'unknown', 'enabled': true, 'value': null}
        ];
        expect(
            user3.roles.map(
                (e) => entityByReflection ? e.toJsonFromFields() : e.toJson()),
            equals(rolesJson3));

        user3.roles = [];

        var ok4 = await userAPIRepository.store(user3);
        expect(ok4, equals(user.id));

        var user4 = await userAPIRepository.selectByID(user.id);
        expect(user4!.email, equals(user.email));
        expect(user4.roles, isEmpty);
      }

      {
        var del = await userAPIRepository
            .deleteByQuery(' #ID == ? ', parameters: [user2Id]);
        var user = del.first;
        expect(user.email, equals('smith4@$testDomain'));
        expect(user.address.state, equals('CA'));
        expect(user.wakeUpTime, equals(user2WakeupTime));
        expect(user.creationTime, equals(user2CreationTime));
      }

      expect(await userAPIRepository.length(), equals(2));

      {
        var user = await userAPIRepository.selectByID(2);
        expect(user, isNull);
      }

      {
        var del1 = await userAPIRepository.delete(
            Condition.parse(' email == ? '),
            parameters: {'email': 'joex@$testDomain'});
        expect(del1, isEmpty);

        var del2 = await userAPIRepository.delete(
            Condition.parse(' email == ? '),
            parameters: {'email': 'joe@$testDomain'});
        expect(del2.length, equals(1));
        expect(del2.first.email, equals('joe@$testDomain'));
      }

      {
        var address1 = await addressAPIRepository.storeFromJson({
          'state': 'EX',
          'city': 'Extra',
          'street': 'Street x',
          'number': 777
        });

        expect(address1, isNotNull);
        expect(address1.id, isNotNull);
        expect(address1.number, 777);

        var address2 = await addressAPIRepository.selectByID(address1.id);
        expect(address2!.toJsonEncoded(), equals(address1.toJsonEncoded()));

        var del1 = await addressAPIRepository.deleteByID(address1.id);

        expect(del1, isNotNull);
        expect(del1!.id, address1.id);
        expect(del1.number, address1.number);
      }

      {
        var address1 = await addressAPIRepository.storeFromJson({
          'state': 'EX',
          'city': 'Extra2',
          'street': 'Street z',
          'number': 888
        });

        expect(address1, isNotNull);
        expect(address1.id, isNotNull);
        expect(address1.number, 888);

        var address2 = await addressAPIRepository.selectByID(address1.id);
        expect(address2!.toJsonEncoded(), equals(address1.toJsonEncoded()));

        var del1 = await addressAPIRepository.deleteEntity(address1);

        expect(del1, isNotNull);
        expect(del1!.id, address1.id);
        expect(del1.number, address1.number);
      }

      {
        var address1 = await addressAPIRepository.storeFromJson({
          'id': 11001,
          'state': 'EX',
          'city': 'Extra',
          'street': 'Street x',
          'number': 999
        });

        expect(address1, isNotNull);
        expect(address1.id, 11001);
        expect(address1.number, 999);

        var address2 = await addressAPIRepository.selectByID(address1.id);
        expect(address2!.toJsonEncoded(), equals(address1.toJsonEncoded()));
      }
    });

    test('populate', () async {
      var result = await entityRepositoryProvider.storeAllFromJson({
        'user': [
          {
            'id': 1001,
            'email': 'extra@mail.com',
            'password': 'abc789',
            'roles': [
              {'type': 'guest', 'enabled': true, 'value': 3.33}
            ],
            'wakeUpTime': Time(10, 0),
            'creationTime': DateTime(2022, 10, 1),
            'address': 11001,
          },
          {
            'id': 1002,
            'email': 'extra2@mail.com',
            'password': 'abc7890',
            'roles': [],
            'wakeUpTime': Time(11, 0),
            'creationTime': DateTime(2022, 10, 2),
            'address': {
              'id': 11111,
              'state': 'EX2',
              'city': 'Extra2',
              'street': 'Street x2',
              'number': 2
            }
          },
        ]
      });

      var sqlAdapter = await entityRepositoryProvider.adapter;

      var information = sqlAdapter.information(extended: true);

      _log.info('${sqlAdapter.runtimeType} INFORMATION:');
      _log.info(Json.encode(information, pretty: true).replaceAllMapped(
          RegExp(r'\[\s*(?:\d+,\s*|\d+\s*)+\]'),
          (m) => m[0]!.replaceAll(RegExp(r'\s+'), ' ')));

      expect(result.length, equals(1));

      var usersResult = (result['user'] as List).cast<User>();

      expect(usersResult.length, equals(2));

      var usersResult0 = usersResult[0];
      expect(usersResult0.address.id, equals(11001));
      expect(usersResult0.address.state, equals('EX'));
      expect(usersResult0.roles.length, equals(1));
      expect(usersResult0.roles[0].enabled, isTrue);
      expect(usersResult0.roles[0].type, equals(RoleType.guest));
      expect(usersResult0.roles[0].value, equals(Decimal.from(3.33)));

      var usersResult1 = usersResult[1];
      expect(usersResult1.address.id, equals(11111));
      expect(usersResult1.address.state, equals('EX2'));
      expect(usersResult1.roles, isEmpty);

      var addressAPIRepository = entityRepositoryProvider.addressAPIRepository;
      var userAPIRepository = entityRepositoryProvider.userAPIRepository;

      print('DELETE CASCADE [ERROR]:');
      print('<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<');

      expect(Transaction.executingTransaction, isNull);

      await expectLater(
          () async => await addressAPIRepository
              .deleteEntityCascade(usersResult0.address),
          throwsA(isA<TransactionAbortedError>()));

      print('DELETE CASCADE:');
      print('<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<');

      expect(Transaction.executingTransaction, isNull);

      var deleted = await userAPIRepository.deleteEntityCascade(usersResult0);

      expect(Transaction.executingTransaction, isNull);

      print(deleted);

      expect(deleted, isNotEmpty);

      expect(deleted.length, 3);

      var delUser = deleted.whereType<User>().firstOrNull;
      expect(delUser, isNotNull);
      expect(delUser!.email, 'extra@mail.com');
      expect(delUser.roles, isEmpty);
      expect(delUser.address, isNotNull);

      var delRole = deleted.whereType<Role>().firstOrNull;
      expect(delRole, isNotNull);
      expect(delRole!.enabled, isTrue);
      expect(delRole.type, equals(RoleType.guest));

      var delAddress = deleted.whereType<Address>().firstOrNull;
      expect(delAddress, isNotNull);
      expect(delAddress!.state, equals('EX'));

      print('>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>');
    });
  }, skip: testConfigDB.unsupportedReason);

  return configSupported;
}
