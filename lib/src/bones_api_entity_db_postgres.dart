import 'package:async_extension/async_extension.dart';
import 'package:collection/collection.dart';
import 'package:logging/logging.dart' as logging;
import 'package:postgres/postgres.dart';
import 'package:reflection_factory/reflection_factory.dart';
import 'package:statistics/statistics.dart';

import 'bones_api_condition_encoder.dart';
import 'bones_api_entity.dart';
import 'bones_api_entity_annotation.dart';
import 'bones_api_entity_db.dart';
import 'bones_api_entity_db_sql.dart';
import 'bones_api_extension.dart';
import 'bones_api_initializable.dart';
import 'bones_api_sql_builder.dart';
import 'bones_api_types.dart';
import 'bones_api_utils.dart';
import 'bones_api_utils_timedmap.dart';

final _log = logging.Logger('DBPostgreSQLAdapter');

/// A PostgreSQL adapter.
class DBPostgreSQLAdapter extends DBSQLAdapter<PostgreSQLExecutionContext> {
  static bool _boot = false;

  static void boot() {
    if (_boot) return;
    _boot = true;

    Transaction.registerErrorFilter((e, s) => e is PostgreSQLException);

    DBSQLAdapter.registerAdapter(['postgres', 'postgre', 'postgresql'],
        DBPostgreSQLAdapter, _instantiate);
  }

  static FutureOr<DBPostgreSQLAdapter?> _instantiate(config,
      {int? minConnections,
      int? maxConnections,
      EntityRepositoryProvider? parentRepositoryProvider,
      String? workingPath}) {
    try {
      return DBPostgreSQLAdapter.fromConfig(config,
          minConnections: minConnections,
          maxConnections: maxConnections,
          parentRepositoryProvider: parentRepositoryProvider,
          workingPath: workingPath);
    } catch (e, s) {
      _log.severe("Error instantiating from config", e, s);
      return null;
    }
  }

  final String host;
  final int port;
  final String databaseName;

  final String username;

  final String? _password;
  final PasswordProvider? _passwordProvider;

  DBPostgreSQLAdapter(this.databaseName, this.username,
      {String? host = 'localhost',
      Object? password,
      PasswordProvider? passwordProvider,
      int? port = 5432,
      int minConnections = 1,
      int maxConnections = 3,
      bool generateTables = false,
      Object? populateTables,
      Object? populateSource,
      EntityRepositoryProvider? parentRepositoryProvider,
      String? workingPath})
      : host = host ?? 'localhost',
        port = port ?? 5432,
        _password = (password != null && password is! PasswordProvider
            ? password.toString()
            : null),
        _passwordProvider = passwordProvider ??
            (password is PasswordProvider ? password : null),
        super(
          'postgresql',
          minConnections,
          maxConnections,
          const DBSQLAdapterCapability(
              dialect: SQLDialect(
                'PostgreSQL',
                elementQuote: '"',
                acceptsReturningSyntax: true,
                acceptsInsertDefaultValues: true,
                acceptsInsertOnConflict: true,
                acceptsVarcharWithoutMaximumSize: true,
              ),
              transactions: true,
              transactionAbort: true,
              tableSQL: true),
          generateTables: generateTables,
          populateTables: populateTables,
          populateSource: populateSource,
          parentRepositoryProvider: parentRepositoryProvider,
          workingPath: workingPath,
        ) {
    boot();

    if (_password == null && _passwordProvider == null) {
      throw ArgumentError("No `password` or `passwordProvider` ");
    }

    parentRepositoryProvider?.notifyKnownEntityRepositoryProvider(this);
  }

  factory DBPostgreSQLAdapter.fromConfig(Map<String, dynamic>? config,
      {String? defaultDatabase,
      String? defaultUsername,
      String? defaultHost,
      int? defaultPort,
      int? minConnections,
      int? maxConnections,
      EntityRepositoryProvider? parentRepositoryProvider,
      String? workingPath}) {
    boot();

    String? host = config?['host'] ?? defaultHost;
    int? port = config?['port'] ?? defaultPort;
    String? database = config?['database'] ?? config?['db'] ?? defaultDatabase;
    String? username =
        config?['username'] ?? config?['user'] ?? defaultUsername;
    String? password = config?['password'] ?? config?['pass'];

    minConnections ??= config?['minConnections'] ?? 1;
    maxConnections ??= config?['maxConnections'] ?? 3;

    var populate = config?['populate'];

    var generateTables = false;
    Object? populateTables;
    Object? populateSource;

    if (populate is Map) {
      generateTables = populate.getAsBool('generateTables', ignoreCase: true) ??
          populate.getAsBool('generate-tables', ignoreCase: true) ??
          populate.getAsBool('generate_tables', ignoreCase: true) ??
          false;

      populateTables = populate['tables'];
      populateSource = populate['source'];
    }

    if (database == null) throw ArgumentError.notNull('database');
    if (username == null) throw ArgumentError.notNull('username');

    return DBPostgreSQLAdapter(
      database,
      username,
      password: password,
      host: host,
      port: port,
      minConnections: minConnections!,
      maxConnections: maxConnections!,
      generateTables: generateTables,
      populateTables: populateTables,
      populateSource: populateSource,
      parentRepositoryProvider: parentRepositoryProvider,
      workingPath: workingPath,
    );
  }

  @override
  SQLDialect get dialect => super.dialect as SQLDialect;

  FutureOr<String> _getPassword() {
    if (_password != null) {
      return _password!;
    } else {
      return _passwordProvider!(username);
    }
  }

  @override
  Map<String, dynamic> information({bool extended = false, String? table}) {
    var info = <String, dynamic>{};

    if (table != null) {
      var executingTransaction = Transaction.executingTransaction;
      if (executingTransaction != null) {
        info['executingTransaction'] = executingTransaction;
      }
    }

    return info;
  }

  @override
  List<Initializable> initializeDependencies() {
    var parentRepositoryProvider = this.parentRepositoryProvider;
    return <Initializable>[
      if (parentRepositoryProvider != null) parentRepositoryProvider
    ];
  }

  @override
  Object resolveError(Object error, StackTrace stackTrace) {
    if (error is DBPostgreSQLAdapterException) {
      return error;
    } else if (error is PostgreSQLException) {
      if (error.severity == PostgreSQLSeverity.error) {
        if (error.code == '23505') {
          return EntityFieldInvalid("unique", error.detail,
              fieldName: error.columnName,
              tableName: error.tableName,
              parentError: error);
        } else if (error.code == '23503') {
          return DBPostgreSQLAdapterException("delete.constraint",
              '${error.message} ; Detail: ${error.detail} ; Table: ${error.tableName} ; Constraint: ${error.constraintName}',
              parentError: error, parentStackTrace: stackTrace);
        }
      }
    }

    return DBPostgreSQLAdapterException('error', '$error',
        parentError: error, parentStackTrace: stackTrace);
  }

  @override
  String getConnectionURL(PostgreSQLExecutionContext connection) {
    var c = connection as PostgreSQLConnection;
    return 'postgresql://${c.username}@${c.host}:${c.port}/${c.databaseName}';
  }

  int _connectionCount = 0;

  @override
  FutureOr<PostgreSQLConnection> createConnection() async {
    var password = await _getPassword();

    var count = ++_connectionCount;

    for (var i = 0; i < 3; ++i) {
      var timeout = i == 0 ? 3 : (i == 1 ? 10 : 30);

      var connection = await _createConnectionImpl(password, timeout);

      if (connection != null) {
        var connUrl = getConnectionURL(connection);
        _log.info('createConnection[$count]> $connUrl > $connection');

        return connection;
      }

      if (poolSize > 0) {
        var poolConn = peekFromPool();
        if (poolConn != null) {
          return poolConn.resolveMapped((conn) {
            if (conn is PostgreSQLConnection) {
              var connUrl = getConnectionURL(conn);
              _log.severe(
                  "Skipping connection retry. Returning connection from pool: $connUrl");
              return conn;
            }

            return _createConnectionImpl(password, timeout).then((conn) {
              if (conn == null) {
                var error = PostgreSQLException(
                    "Error connecting to: $databaseName@$host:$port");

                _log.severe(
                    "Can't connect to PostgreSQL: $databaseName@$host:$port");

                throw error;
              }
              return conn;
            });
          });
        }
      }
    }

    var error =
        PostgreSQLException("Error connecting to: $databaseName@$host:$port");

    _log.severe("Can't connect to PostgreSQL: $databaseName@$host:$port");

    throw error;
  }

  Future<PostgreSQLConnection?> _createConnectionImpl(
      String password, int timeout) async {
    var connection = PostgreSQLConnection(host, port, databaseName,
        username: username, password: password, timeoutInSeconds: timeout);
    var ok = await tryCallMapped(() => connection.open(),
        onSuccessValue: true, onErrorValue: false);
    return ok != null && ok ? connection : null;
  }

  @override
  FutureOr<bool> closeConnection(PostgreSQLExecutionContext connection) {
    _log.info('closeConnection> $connection > poolSize: $poolSize');

    if (connection is PostgreSQLConnection) {
      connection.close();
    }
    return true;
  }

  @override
  FutureOr<bool> isConnectionValid(PostgreSQLExecutionContext connection) {
    return connection is PostgreSQLConnection && !connection.isClosed;
  }

  @override
  FutureOr<Map<String, Type>?> getTableFieldsTypesImpl(String table) async {
    var connection = await catchFromPool();

    _log.info('getTableFieldsTypesImpl> $table');

    var sql =
        "SELECT column_name, data_type, column_default, is_updatable FROM information_schema.columns WHERE table_name = '$table'";

    var results = await connection.mappedResultsQuery(sql);

    if (results.isEmpty) return null;

    var scheme = results.map((e) => e['']!).toList(growable: false);

    if (scheme.isEmpty) return null;

    var fieldsTypes = Map<String, Type>.fromEntries(scheme.map((e) {
      var k = e['column_name'] as String;
      var v = _toFieldType(e['data_type'] as String);
      return MapEntry(k, v);
    }));

    return fieldsTypes;
  }

  @override
  Future<TableScheme?> getTableSchemeImpl(
      String table, TableRelationshipReference? relationship) async {
    var connection = await catchFromPool();

    _log.info('getTableSchemeImpl> $table ; relationship: $relationship');

    var sql =
        "SELECT column_name, data_type, column_default, is_updatable FROM information_schema.columns WHERE table_name = '$table'";

    var results = await connection.mappedResultsQuery(sql);

    if (results.isEmpty) return null;

    var scheme = results.map((e) => e['']!).toList(growable: false);

    if (scheme.isEmpty) return null;

    var idFieldName = await _findIDField(connection, table, scheme);

    var fieldsTypes = Map<String, Type>.fromEntries(scheme.map((e) {
      var k = e['column_name'] as String;
      var v = _toFieldType(e['data_type'] as String);
      return MapEntry(k, v);
    }));

    notifyTableFieldTypes(table, fieldsTypes);

    var fieldsReferencedTables =
        await _findFieldsReferencedTables(connection, table);

    var relationshipTables =
        await _findRelationshipTables(connection, table, idFieldName);

    await releaseIntoPool(connection);

    var tableScheme = TableScheme(table,
        relationship: relationship != null,
        idFieldName: idFieldName,
        fieldsTypes: fieldsTypes,
        fieldsReferencedTables: fieldsReferencedTables,
        relationshipTables: relationshipTables);

    _log.info('$tableScheme');

    return tableScheme;
  }

  Future<String> _findIDField(PostgreSQLExecutionContext connection,
      String table, List<Map<String, dynamic>> scheme) async {
    var sql = '''
    SELECT
      c.column_name, c.data_type
    FROM
      information_schema.table_constraints tc 
    JOIN
      information_schema.constraint_column_usage AS ccu USING (constraint_schema, constraint_name) 
    JOIN
      information_schema.columns AS c ON c.table_schema = tc.constraint_schema AND tc.table_name = c.table_name AND ccu.column_name = c.column_name
    WHERE
      constraint_type = 'PRIMARY KEY' and tc.table_name = '$table';
    ''';

    var results = await connection.mappedResultsQuery(sql);

    var columns = results.map((r) {
      return Map.fromEntries(r.values.expand((e) => e.entries));
    }).toList(growable: false);

    var primaryFields = Map.fromEntries(
        columns.map((m) => MapEntry(m['column_name'], m['data_type'])));

    if (primaryFields.length == 1) {
      return primaryFields.keys.first;
    } else if (primaryFields.length > 1) {
      return primaryFields.keys.first;
    }

    return 'id';
  }

  static final RegExp _regExpSpaces = RegExp(r'\s+');
  static final RegExp _regExpIgnoreWords =
      RegExp(r'unsigned|signed|varying|precision|\(.*?\)');

  Type _toFieldType(String dataType) {
    dataType = dataType.toLowerCase();
    dataType = dataType.replaceAll(_regExpIgnoreWords, ' ');
    dataType = dataType.replaceAll(_regExpSpaces, ' ');
    dataType = dataType.trim();

    switch (dataType) {
      case 'boolean':
      case 'bool':
        return bool;
      case 'integer':
      case 'int':
      case 'int2':
      case 'int4':
      case 'int8':
      case 'bigint':
      case 'serial':
      case 'serial2':
      case 'serial4':
      case 'serial8':
      case 'bigserial':
        return int;
      case 'decimal':
      case 'numeric':
        return Decimal;
      case 'float':
      case 'float4':
      case 'float8':
      case 'double':
        return double;
      case 'text':
      case 'char':
      case 'character':
      case 'varchar':
        return String;
      case 'timestamp':
      case 'timestampz':
      case 'timestamp without time zone':
      case 'timestamp with time zone':
      case 'date':
      case 'datetime':
        return DateTime;
      case 'time':
      case 'timez':
      case 'time without time zone':
      case 'time with time zone':
        return Time;
      default:
        return String;
    }
  }

  Future<List<TableRelationshipReference>> _findRelationshipTables(
      PostgreSQLExecutionContext connection,
      String table,
      String idFieldName) async {
    var tablesNames = await _listTablesNames(connection);

    var tablesReferences = await tablesNames
        .map((t) => _findFieldsReferencedTables(connection, t))
        .resolveAll();

    tablesReferences = tablesReferences.where((m) {
      return m.length > 1 &&
          m.values.where((r) => r.targetTable == table).isNotEmpty &&
          m.values.where((r) => r.targetTable != table).isNotEmpty;
    }).toList();

    var relationships = tablesReferences
        .map((e) {
          var refToTables = e.values
              .where((r) => r.targetTable == table)
              .toList(growable: false);
          var otherRefs = e.values
              .where((r) => r.targetTable != table)
              .toList(growable: false);

          if (refToTables.length != 1 || otherRefs.length != 1) {
            return null;
          }

          var refToTable = refToTables.single;
          var otherRef = otherRefs.single;

          return TableRelationshipReference(
            refToTable.sourceTable,
            refToTable.targetTable,
            refToTable.targetField,
            refToTable.targetFieldType,
            refToTable.sourceField,
            otherRef.targetTable,
            otherRef.targetField,
            otherRef.targetFieldType,
            otherRef.sourceField,
          );
        })
        .whereNotNull()
        .toList();

    return relationships;
  }

  Future<List<String>> _listTablesNames(
      PostgreSQLExecutionContext connection) async {
    var sql = '''
    SELECT table_name FROM information_schema.tables WHERE table_schema='public'
    ''';

    var results = await connection.mappedResultsQuery(sql);

    var names = results
        .map((e) {
          var v = e.values.first;
          return v.values.first;
        })
        .map((e) => '$e')
        .toList();

    return names;
  }

  final TimedMap<String, Map<String, TableFieldReference>>
      _findFieldsReferencedTablesCache =
      TimedMap<String, Map<String, TableFieldReference>>(Duration(seconds: 30));

  FutureOr<Map<String, TableFieldReference>> _findFieldsReferencedTables(
          PostgreSQLExecutionContext connection, String table) =>
      _findFieldsReferencedTablesCache.putIfAbsentCheckedAsync(
          table, () => _findFieldsReferencedTablesImpl(connection, table));

  Future<Map<String, TableFieldReference>> _findFieldsReferencedTablesImpl(
      PostgreSQLExecutionContext connection, String table) async {
    var sql = '''
    SELECT
      o.conname AS constraint_name,
      
      m.relname AS source_table,
      stc_attr.attname AS source_column,
      src_inf.data_type AS source_column_type,

      f.relname AS target_table,
      targ_attr.attname AS target_column,
      targ_inf.data_type AS target_column_type
      
    FROM
      pg_constraint o 
      LEFT JOIN pg_class f ON f.oid = o.confrelid 
      LEFT JOIN pg_class m ON m.oid = o.conrelid
	  INNER JOIN pg_attribute stc_attr ON stc_attr.attrelid = m.oid AND stc_attr.attnum = o.conkey[1] AND stc_attr.attisdropped = false
	  INNER JOIN information_schema.columns src_inf ON src_inf.table_name = m.relname and src_inf.column_name = stc_attr.attname
	  INNER JOIN pg_attribute targ_attr ON targ_attr.attrelid = f.oid AND targ_attr.attnum = o.confkey[1] AND targ_attr.attisdropped = false
	  INNER JOIN information_schema.columns targ_inf ON targ_inf.table_name = f.relname and targ_inf.column_name = targ_attr.attname
    WHERE
      o.contype = 'f' AND m.relname = '$table' AND o.conrelid IN (SELECT oid FROM pg_class c WHERE c.relkind = 'r') 
    ''';

    var results = await connection.mappedResultsQuery(sql);

    var referenceFields = results.map((r) {
      return Map.fromEntries(r.values.expand((e) => e.entries));
    }).toList(growable: false);

    var map =
        Map<String, TableFieldReference>.fromEntries(referenceFields.map((e) {
      var sourceTable = e['source_table'];
      var sourceField = e['source_column'];
      var sourceFieldDataType = e['source_column_type'];
      var targetTable = e['target_table'];
      var targetField = e['target_column'];
      var targetFieldDataType = e['target_column_type'];
      if (targetTable == null || targetField == null) return null;

      var sourceFieldType = sourceFieldDataType != null
          ? _toFieldType(sourceFieldDataType)
          : String;
      var targetFieldType = targetFieldDataType != null
          ? _toFieldType(targetFieldDataType)
          : String;

      var reference = TableFieldReference(sourceTable, sourceField,
          sourceFieldType, targetTable, targetField, targetFieldType);
      return MapEntry<String, TableFieldReference>(sourceField, reference);
    }).whereNotNull());

    return map;
  }

  @override
  String? typeToSQLType(TypeInfo type, String column,
      {List<EntityField>? entityFieldAnnotations}) {
    var sqlType = super.typeToSQLType(type, column,
        entityFieldAnnotations: entityFieldAnnotations);

    if (sqlType == 'TIME') {
      return 'TIME WITHOUT TIME ZONE';
    }

    return sqlType;
  }

  @override
  FutureOr<MapEntry<String, List<String>>?> enumTypeToSQLType(
      Type type, String column,
      {List<EntityField>? entityFieldAnnotations}) {
    return super
        .enumTypeToSQLType(type, column,
            entityFieldAnnotations: entityFieldAnnotations)
        .resolveMapped((enumType) {
      if (enumType == null) return null;

      var values = enumType.value;
      if (values.isEmpty) {
        return MapEntry('VARCHAR', values);
      }

      return MapEntry('VARCHAR CHECK', values);
    });
  }

  @override
  FutureOr<bool> executeTableSQL(String createTableSQL) => executeWithPool((c) {
        return c.execute(createTableSQL).then((_) => true, onError: (e, s) {
          _log.severe("Error executing table SQL:\n$createTableSQL", e, s);
          return false;
        });
      });

  @override
  FutureOr<int> doCountSQL(String entityName, String table, SQL sql,
      Transaction transaction, PostgreSQLExecutionContext connection) {
    return connection
        .mappedResultsQuery(sql.sql,
            substitutionValues: sql.parametersByPlaceholder)
        .resolveMapped((results) {
      var count = results
          .map((e) {
            var tableResults = e[table] ?? e[''];
            var count = tableResults?['count'] ?? 0;
            return count is int ? count : int.tryParse(count.toString().trim());
          })
          .whereType<int>()
          .first;
      return count;
    });
  }

  @override
  FutureOr<Iterable<Map<String, dynamic>>> doSelectSQL(
      String entityName,
      String table,
      SQL sql,
      Transaction transaction,
      PostgreSQLExecutionContext connection) {
    if (sql.isDummy) return <Map<String, dynamic>>[];

    return connection
        .mappedResultsQuery(sql.sql,
            substitutionValues: sql.parametersByPlaceholder)
        .resolveMapped((results) {
      var entries = results
          .map((e) => e[table])
          .whereType<Map<String, dynamic>>()
          .toList();

      return entries;
    });
  }

  @override
  FutureOr<Iterable<Map<String, dynamic>>> doDeleteSQL(
      String entityName,
      String table,
      SQL sql,
      Transaction transaction,
      PostgreSQLExecutionContext connection) {
    if (sql.isDummy) return <Map<String, dynamic>>[];

    return connection
        .mappedResultsQuery(sql.sql,
            substitutionValues: sql.parametersByPlaceholder)
        .resolveMapped((results) {
      var entries = results
          .map((e) => e[table])
          .whereType<Map<String, dynamic>>()
          .toList();

      return entries;
    });
  }

  @override
  FutureOr<dynamic> doInsertSQL(String entityName, String table, SQL sql,
      Transaction transaction, PostgreSQLExecutionContext connection) {
    if (sql.isDummy) return null;

    return connection
        .mappedResultsQuery(sql.sql,
            substitutionValues: sql.parametersByPlaceholder)
        .resolveMapped((results) => _resolveResultID(results, table, sql));
  }

  @override
  FutureOr doUpdateSQL(String entityName, String table, SQL sql, Object id,
      Transaction transaction, PostgreSQLExecutionContext connection,
      {bool allowAutoInsert = false}) {
    if (sql.isFullyDummy) return id;

    return connection
        .mappedResultsQuery(sql.sql,
            substitutionValues: sql.parametersByPlaceholder)
        .resolveMapped((results) {
      if (results.isEmpty) {
        var entry = sql.parametersByPlaceholder;
        if (!allowAutoInsert) {
          throw StateError(
              "Can't update not stored entity into table `$table`: $entry");
        }

        var fields = sql.namedParameters!;
        return _updateAutoInsert(
            transaction, entityName, table, fields, connection);
      }

      return _resolveResultID(results, table, sql, id);
    });
  }

  FutureOr<dynamic> _updateAutoInsert(
      Transaction transaction,
      String entityName,
      String table,
      Map<String, dynamic> fields,
      PostgreSQLExecutionContext connection) {
    return getTableScheme(table).resolveMapped((tableScheme) {
      if (tableScheme == null) {
        throw StateError("Can't find `TableScheme` for table `$table`");
      }

      var idFieldName = tableScheme.idFieldName ?? 'id';
      var idFieldType = tableScheme.fieldsTypes[idFieldName] ?? int;
      var id = fields[idFieldName];

      if (id == null) {
        throw StateError(
            "Can't auto-insert entry without ID> table: `$table`; idFieldName: $idFieldName");
      }

      return generateInsertSQL(transaction, entityName, table, fields)
          .resolveMapped((insertSQL) {
        _log.info('Update not affecting any row! Auto inserting: $insertSQL');

        return doInsertSQL(
                entityName, table, insertSQL, transaction, connection)
            .resolveMapped((res) => _fixeTableSequence(transaction, entityName,
                table, idFieldName, idFieldType, connection, res));
      });
    });
  }

  FutureOr<dynamic> _fixeTableSequence(
      Transaction transaction,
      String entityName,
      String table,
      String idFieldName,
      Type idFieldType,
      PostgreSQLExecutionContext connection,
      Object? lastInsertResult) {
    if (!idFieldType.isEntityIDType &&
        !idFieldType.isNumericOrDynamicNumberType) {
      return lastInsertResult;
    }

    var fixSql =
        "SELECT setval(pg_get_serial_sequence('$table', '$idFieldName'), coalesce(max(id),0) + 1, false) FROM \"$table\"";

    _log.info("Fixing table PRIMARY KEY sequence: <$fixSql>");

    return connection.query(fixSql).then((r) => lastInsertResult);
  }

  dynamic _resolveResultID(
      List<Map<String, Map<String, dynamic>>> results, String table, SQL sql,
      [Object? entityId]) {
    if (results.isEmpty) {
      return null;
    }

    var returning = results.first[table];

    if (returning == null || returning.isEmpty) {
      return null;
    } else if (returning.length == 1) {
      var id = returning.values.first;
      return id;
    } else {
      var idFieldName = sql.idFieldName;

      if (idFieldName != null) {
        var id = returning[idFieldName];
        return id;
      } else {
        var id = returning.values.first;
        return id;
      }
    }
  }

  @override
  FutureOr<PostgreSQLExecutionContext> openTransaction(
      Transaction transaction) {
    var contextCompleter = Completer<PostgreSQLExecutionContext>();

    var result = executeWithPool(
      (connection) {
        var theConnection = connection as PostgreSQLConnection;

        return theConnection.transaction((c) {
          contextCompleter.complete(c);

          return transaction.transactionFuture.catchError((e, s) {
            cancelTransaction(transaction, c, e, s);
            throw e;
          });
        });
      },
      validator: (c) => !transaction.isAborted,
    );

    transaction.transactionResult = result;

    return contextCompleter.future;
  }

  @override
  bool cancelTransaction(
      Transaction transaction,
      PostgreSQLExecutionContext connection,
      Object? error,
      StackTrace? stackTrace) {
    connection.cancelTransaction();
    return true;
  }

  @override
  bool get callCloseTransactionRequired => false;

  @override
  FutureOr<void> closeTransaction(
      Transaction transaction, PostgreSQLExecutionContext? connection) {}

  @override
  String toString() {
    var closedStr = isClosed ? ', closed' : '';
    return 'DBPostgreSQLAdapter#$instanceID{$databaseName@$host:$port$closedStr}';
  }
}

/// Exception thrown by [DBPostgreSQLAdapter] operations.
class DBPostgreSQLAdapterException extends DBSQLAdapterException {
  DBPostgreSQLAdapterException(String type, String message,
      {Object? parentError, StackTrace? parentStackTrace})
      : super(type, message,
            parentError: parentError, parentStackTrace: parentStackTrace);
}
