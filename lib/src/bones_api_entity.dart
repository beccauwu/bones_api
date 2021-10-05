import 'dart:convert' as dart_convert;

import 'package:async_extension/async_extension.dart';
import 'package:collection/collection.dart';
import 'package:reflection_factory/reflection_factory.dart';

import 'bones_api_condition.dart';
import 'bones_api_mixin.dart';
import 'bones_api_utils.dart';

typedef JsonToEncodable = Object? Function(dynamic object);

typedef JsonReviver = Object? Function(Object? key, Object? value);

abstract class Entity {
  V? getID<V>() => getField('id');

  void setID<V>(V id) => setField('id', id);

  String get idFieldName;

  List<String> get fieldsNames;

  V? getField<V>(String key);

  TypeInfo? getFieldType(String key);

  void setField<V>(String key, V? value);

  Map<String, dynamic> toJson();

  String toJsonEncoded() => dart_convert.json.encode(toJson());
}

class EntityHandlerProvider {
  static final EntityHandlerProvider _globalProvider = EntityHandlerProvider();

  static EntityHandlerProvider get globalProvider => _globalProvider;

  final Map<Type, EntityHandler> _entityHandlers = <Type, EntityHandler>{};

  void _register<O>(EntityHandler<O> entityHandler) {
    _entityHandlers[entityHandler.type] = entityHandler;
  }

  EntityHandler<O>? getEntityHandler<O>({O? obj, Type? type}) =>
      _getEntityHandlerImpl<O>(obj: obj, type: type) ??
      _globalProvider._getEntityHandlerImpl<O>(obj: obj, type: type);

  EntityHandler<O>? _getEntityHandlerImpl<O>({O? obj, Type? type}) {
    var entityHandler = _entityHandlers[O];

    if (entityHandler == null && obj != null) {
      entityHandler = _entityHandlers[obj.runtimeType];
    }

    if (entityHandler == null && type != null) {
      entityHandler = _entityHandlers[type];
    }

    return entityHandler as EntityHandler<O>?;
  }

  EntityRepository<O>? getEntityRepository<O>(
      {O? obj, Type? type, String? name}) {
    var entityHandler = getEntityHandler<O>(obj: obj, type: type);

    if (entityHandler != null) {
      var entityRepository = entityHandler.getEntityRepository<O>(
          obj: obj, type: type, name: name);
      if (entityRepository != null) {
        return entityRepository;
      }
    }

    for (var entityHandler in _entityHandlers.values) {
      var entityRepository = entityHandler.getEntityRepository<O>(
          obj: obj, type: type, name: name);
      if (entityRepository != null) {
        return entityRepository;
      }
    }

    return null;
  }
}

abstract class EntityHandler<O> with FieldsFromMap {
  final EntityHandlerProvider provider;
  final Type type;

  EntityHandler(EntityHandlerProvider? provider, {Type? type})
      : provider = provider ?? EntityHandlerProvider.globalProvider,
        type = type ?? O {
    if (!isValidType(this.type)) {
      throw StateError('Invalid EntityHandler type: $type ?? $O');
    }

    if (O != type) {
      throw StateError(
          'EntityHandler generic type `O` should be the same of parameter `type`: O:$O != type:$type');
    }

    this.provider._register(this);

    _jsonReviver = _defaultJsonReviver;
  }

  static bool isValidType<T>([Type? type]) {
    type ??= T;
    return type != Object && type != dynamic && !isPrimitiveType(type);
  }

  static bool isPrimitiveType<T>([Type? type]) =>
      TypeParser.isPrimitiveType<T>(type);

  EntityHandler<T>? getEntityHandler<T>({T? obj, Type? type}) {
    if (T == O && isValidType<T>()) {
      return this as EntityHandler<T>;
    } else if (obj != null && obj.runtimeType == O && isValidType<O>()) {
      return this as EntityHandler<T>;
    } else if (type != null && type == O && isValidType<O>()) {
      return this as EntityHandler<T>;
    } else {
      return provider.getEntityHandler<T>(obj: obj, type: type);
    }
  }

  V? getID<V>(O o) => getField(o, 'id');

  void setID<V>(O o, V id) => setField(o, 'id', id);

  String idFieldsName([O? o]);

  List<String> fieldsNames([O? o]);

  Map<String, TypeInfo> fieldsTypes([O? o]);

  Map<String, TypeInfo>? _fieldsWithTypeList;

  Map<String, TypeInfo> fieldsWithTypeList([O? o]) => _fieldsWithTypeList ??=
      fieldsWithType((_, fieldType) => fieldType.isList, o);

  Map<String, TypeInfo>? _fieldsWithTypeListEntity;

  Map<String, TypeInfo> fieldsWithTypeListEntity([O? o]) =>
      _fieldsWithTypeListEntity ??=
          fieldsWithType((_, fieldType) => fieldType.isListEntity, o);

  Map<String, TypeInfo> fieldsWithType(
      bool Function(String fieldName, TypeInfo fieldType) typeFilter,
      [O? o]) {
    return Map<String, TypeInfo>.unmodifiable(
        Map<String, TypeInfo>.fromEntries(fieldsTypes(o).entries.where((e) {
      return typeFilter(e.key, e.value);
    })));
  }

  void inspectObject(O? o);

  FutureOr<Map<String, Object?>> resolveFieldsValues(
      Map<String, Object?> fields,
      [O? o]) {
    var fieldsTypes = this.fieldsTypes(o);

    var resolved = fields.map((f, v) {
      var t = fieldsTypes[f];
      var v2 = resolveFieldValue(f, t, v);
      return MapEntry(f, v2);
    });

    return resolved.resolveAllValuesNullable();
  }

  FutureOr<Object?> resolveFieldValue(
      String fieldName, TypeInfo? fieldType, Object? value) {
    if (value == null) return null;

    var resolved = fieldType?.parse(value);
    if (resolved != null) {
      return resolved;
    }

    if (value is num || value is String || value is Map<String, dynamic>) {
      var o = EntityRepository.resolveEntityFromMap(
          entityMap: value,
          entityType: fieldType?.type,
          entityHandlerProvider: provider);
      return o ?? value;
    }

    return value;
  }

  FutureOr<dynamic> resolveEntityFieldValue(O o, String key, dynamic value) {
    var fieldType = getFieldType(o, key);
    return resolveValueByType(fieldType, value);
  }

  T? resolveValueByType<T>(TypeInfo? type, Object? value) {
    if (type == null) {
      return value as T?;
    }

    if (value is Map<String, Object?>) {
      if (type.type == Map) {
        return type.parse<T>(value);
      } else {
        var valEntityHandler = _resolveEntityHandler(type);
        var resolved = valEntityHandler != null
            ? valEntityHandler.createFromMap(value)
            : value;
        return resolved as T?;
      }
    } else if (value is List<Object?>) {
      if (type.type == List && type.hasArguments) {
        var elementType = type.arguments.first;
        var valEntityHandler = _resolveEntityHandler(elementType);

        if (valEntityHandler != null) {
          var list = TypeParser.parseList(value,
              elementParser: (e) =>
                  valEntityHandler.resolveValueByType(elementType, e));

          if (list == null) return null;
          return valEntityHandler.castList(list, elementType.type)! as T;
        } else {
          var list = TypeParser.parseList(value,
              elementParser: (e) => resolveValueByType(elementType, e));

          if (list == null) return null;
          return list as T;
        }
      } else {
        return type.parse<T>(value);
      }
    } else {
      return type.parse<T>(value);
    }
  }

  List? castList(List list, Type type) {
    if (type == this.type) {
      return List<O>.from(list);
    }
    return null;
  }

  Iterable? castIterable(Iterable itr, Type type) {
    if (type == this.type) {
      return itr.cast<O>();
    }
    return null;
  }

  EntityHandler? _resolveEntityHandler(TypeInfo fieldType) {
    var valEntityHandler = getEntityHandler(type: fieldType.type);
    valEntityHandler ??=
        getEntityRepository(type: fieldType.type)?.entityHandler;
    return valEntityHandler;
  }

  Map<String, int>? _fieldsNamesIndexes;

  Map<String, int> fieldsNamesIndexes([O? o]) {
    if (_fieldsNamesIndexes == null) {
      var fieldsNames = this.fieldsNames(o);
      _fieldsNamesIndexes = buildFieldsNamesIndexes(fieldsNames);
    }
    return _fieldsNamesIndexes!;
  }

  List<String>? _fieldsNamesLC;

  List<String> fieldsNamesLC([O? o]) {
    if (_fieldsNamesLC == null) {
      var fieldsNames = this.fieldsNames(o);
      _fieldsNamesLC = buildFieldsNamesLC(fieldsNames);
    }
    return _fieldsNamesLC!;
  }

  List<String>? _fieldsNamesSimple;

  List<String> fieldsNamesSimple([O? o]) {
    if (_fieldsNamesSimple == null) {
      var fieldsNames = this.fieldsNames(o);
      _fieldsNamesSimple = buildFieldsNamesSimple(fieldsNames);
    }
    return _fieldsNamesSimple!;
  }

  TypeInfo? getFieldType(O? o, String key);

  V? getField<V>(O o, String key);

  Map<String, dynamic> getFields(O o) {
    return Map<String, dynamic>.fromEntries(fieldsNames(o)
        .map((key) => MapEntry<String, dynamic>(key, getField(o, key))));
  }

  void setField<V>(O o, String key, V? value);

  bool trySetField<V>(O o, String key, V? value) {
    try {
      setField(o, key, value);
      return true;
    } catch (e) {
      return false;
    }
  }

  late JsonReviver _jsonReviver;

  JsonReviver get jsonReviver => _jsonReviver;

  set jsonReviver(JsonReviver? value) {
    _jsonReviver = value ?? _defaultJsonReviver;
  }

  Object? _defaultJsonReviver(Object? key, Object? value) {
    if (key != null) {
      return value;
    }

    if (value is Map<String, dynamic>) {
      return createFromMap(value);
    }

    return value;
  }

  O decodeObjectJson(String json) =>
      dart_convert.json.decode(json, reviver: jsonReviver);

  List<O> decodeObjectListJson(String json) {
    var itr =
        dart_convert.json.decode(json, reviver: jsonReviver) as Iterable<O>;
    return itr is List<O> ? itr : itr.toList();
  }

  dynamic decodeJson(String json) =>
      dart_convert.json.decode(json, reviver: jsonReviver);

  JsonToEncodable? jsonToEncodable;

  String encodeObjectJson(O o) =>
      dart_convert.json.encode(o, toEncodable: jsonToEncodable);

  String encodeObjectListJson(Iterable<O> list) =>
      dart_convert.json.encode(list.toList(), toEncodable: jsonToEncodable);

  String encodeJson(dynamic o) =>
      dart_convert.json.encode(o, toEncodable: jsonToEncodable);

  FutureOr<O> createFromMap(Map<String, dynamic> fields);

  FutureOr<O> setFieldsFromMap(O o, Map<String, dynamic> fields) {
    var fieldsNames = this.fieldsNames(o);

    var fieldsValues = getFieldsValuesFromMap(fieldsNames, fields,
        fieldsNamesIndexes: fieldsNamesIndexes(o),
        fieldsNamesLC: fieldsNamesLC(o),
        fieldsNamesSimple: fieldsNamesSimple(o));

    var setFutures = fieldsValues.entries.map((e) {
      return setFieldValueDynamic(o, e.key, e.value).resolveWithValue(true);
    });

    return setFutures.resolveAllWithValue(o);
  }

  FutureOr<dynamic> setFieldValueDynamic(O o, String key, dynamic value) {
    var retValue2 = resolveEntityFieldValue(o, key, value);
    return retValue2.resolveMapped((value2) {
      setField(o, key, value2);
      return value2;
    });
  }

  final Set<EntityRepositoryProvider> _knownEntityRepositoryProviders =
      <EntityRepositoryProvider>{};

  void notifyKnownEntityRepositoryProvider(EntityRepositoryProvider provider) {
    if (!identical(provider, EntityHandlerProvider.globalProvider)) {
      _knownEntityRepositoryProviders.add(provider);
    }
  }

  EntityRepository<T>? getEntityRepository<T>(
      {T? obj, Type? type, String? name}) {
    for (var provider in _knownEntityRepositoryProviders) {
      var repository =
          provider.getEntityRepository(obj: obj, type: type, name: name);
      if (repository != null) {
        return repository;
      }
    }

    return EntityRepositoryProvider.globalProvider
        .getEntityRepository<T>(obj: obj, type: type, name: name);
  }
}

typedef InstantiatorDefault<O> = FutureOr<O> Function();

typedef InstantiatorFromMap<O> = FutureOr<O> Function(Map<String, dynamic>);

class GenericEntityHandler<O extends Entity> extends EntityHandler<O> {
  final InstantiatorDefault<O>? instantiatorDefault;

  final InstantiatorFromMap<O>? instantiatorFromMap;

  GenericEntityHandler(
      {this.instantiatorDefault,
      this.instantiatorFromMap,
      Type? type,
      O? sampleEntity,
      EntityHandlerProvider? provider})
      : super(provider, type: type ?? O) {
    if (instantiatorDefault == null && instantiatorFromMap == null) {
      throw ArgumentError(
          "Null instantiators: `instantiatorDefault`, `instantiatorFromMap`");
    }

    if (sampleEntity != null) {
      inspectObject(sampleEntity);
    }
  }

  String? _idFieldsName;

  @override
  String idFieldsName([O? o]) {
    var idFieldsName = _idFieldsName;

    if (idFieldsName == null && o != null) {
      inspectObject(o);
      idFieldsName = _idFieldsName;
    }

    if (idFieldsName == null) {
      throw StateError(
          "`idFieldsName` Not populated yet! No Entity instance presented to this EntityHandler yet.");
    }

    return idFieldsName;
  }

  List<String>? _fieldsNames;

  @override
  List<String> fieldsNames([O? o]) {
    var fieldsNames = _fieldsNames;

    if (fieldsNames == null && o != null) {
      inspectObject(o);
      fieldsNames = _fieldsNames;
    }

    if (fieldsNames == null) {
      throw StateError(
          "`fieldsNames` Not populated yet! No Entity instance presented to this EntityHandler yet. Type: $type");
    }

    return fieldsNames;
  }

  Map<String, TypeInfo>? _fieldsTypes;

  @override
  Map<String, TypeInfo> fieldsTypes([O? o]) {
    var fieldsTypes = _fieldsTypes;

    if (fieldsTypes == null && o != null) {
      inspectObject(o);
      fieldsTypes = _fieldsTypes;
    }

    if (fieldsTypes == null) {
      throw StateError(
          "`fieldsTypes` Not populated yet! No Entity instance presented to this EntityHandler yet. Type: $type");
    }

    return fieldsTypes;
  }

  @override
  void inspectObject(O? o) {
    if (o != null && _idFieldsName == null) {
      _idFieldsName = o.idFieldName;
      _fieldsNames ??= List<String>.unmodifiable(o.fieldsNames);
      _fieldsTypes ??= Map<String, TypeInfo>.unmodifiable(
          Map<String, TypeInfo>.fromEntries(
              _fieldsNames!.map((f) => MapEntry(f, o.getFieldType(f)!))));
    }
  }

  @override
  String encodeObjectJson(O o) {
    inspectObject(o);
    return super.encodeObjectJson(o);
  }

  @override
  String encodeJson(o) {
    inspectObject(o);
    return super.encodeJson(o);
  }

  @override
  String encodeObjectListJson(Iterable<O> list) {
    if (list.isNotEmpty) {
      inspectObject(list.first);
    }
    return super.encodeObjectListJson(list);
  }

  @override
  V? getID<V>(O o) {
    inspectObject(o);
    return o.getID();
  }

  @override
  void setID<V>(O o, V id) {
    inspectObject(o);
    o.setID(id);
  }

  @override
  V? getField<V>(O o, String key) {
    inspectObject(o);
    return o.getField<V>(key);
  }

  @override
  TypeInfo? getFieldType(O? o, String key) {
    inspectObject(o);
    return o?.getFieldType(key);
  }

  @override
  void setField<V>(O o, String key, V? value) {
    inspectObject(o);
    return o.setField<V>(key, value);
  }

  @override
  FutureOr<O> createFromMap(Map<String, dynamic> fields) {
    if (instantiatorFromMap != null) {
      var fieldsNames = this.fieldsNames();

      var fieldsValues = getFieldsValuesFromMap(fieldsNames, fields,
          fieldsNamesIndexes: fieldsNamesIndexes(),
          fieldsNamesLC: fieldsNamesLC(),
          fieldsNamesSimple: fieldsNamesSimple());

      var retFieldsResolved = resolveFieldsValues(fieldsValues);

      return retFieldsResolved.resolveMapped((fieldsResolved) {
        return instantiatorFromMap!(fieldsResolved);
      });
    } else {
      var oRet = instantiatorDefault!();
      return oRet.resolveMapped((o) => setFieldsFromMap(o, fields));
    }
  }

  @override
  String toString() {
    return 'GenericEntityHandler{$type}';
  }
}

class ClassReflectionEntityHandler<O> extends EntityHandler<O> {
  Type classType;

  ClassReflection<O>? _reflection;

  ClassReflectionEntityHandler(this.classType,
      {EntityHandlerProvider? provider, ClassReflection<O>? reflection})
      : _reflection = reflection,
        super(provider, type: classType);

  ClassReflection<O> get reflection {
    _reflection ??=
        ReflectionFactory().getRegisterClassReflection<O>(classType);
    return _reflection!;
  }

  @override
  void inspectObject(O? o) {}

  @override
  V? getField<V>(O o, String key) => reflection.getField(key, o);

  @override
  TypeInfo? getFieldType(O? o, String key) {
    var field = reflection.field(key, o);
    return field != null ? TypeInfo.from(field) : null;
  }

  @override
  void setField<V>(O o, String key, V? value) =>
      reflection.setField(key, value, o);

  @override
  bool trySetField<V>(O o, String key, V? value) {
    var field = reflection.field<V>(key, o);
    if (field == null) return false;

    if (value == null) {
      if (field.nullable) {
        field.set(value);
        return true;
      } else {
        return false;
      }
    }

    if (field.type.type == value.runtimeType) {
      field.set(value);
      return true;
    } else {
      return false;
    }
  }

  String? _idFieldsName;

  @override
  String idFieldsName([O? o]) {
    if (_idFieldsName == null) {
      // Just to populate:
      if (_fieldsNames == null) {
        fieldsNames(o);
      }

      var fieldName = findIdFieldName();
      _idFieldsName = fieldName ?? 'id';
    }
    return _idFieldsName!;
  }

  String? findIdFieldName() {
    var possibleFields = reflection.fieldsWhere((f) {
      return f.type.isPrimitiveType;
    }).toList(growable: false);

    if (possibleFields.isEmpty) {
      throw StateError(
          "Class without candidate for ID field: ${fieldsNames()}");
    }

    if (possibleFields.length == 1) {
      return possibleFields.first.name;
    }

    possibleFields.sort((a, b) {
      var n1 = a.nullable;
      var n2 = b.nullable;
      return n1 == n2 ? 0 : (n1 ? -1 : 1);
    });

    var idField = possibleFields.firstWhereOrNull((f) {
      var name = f.name.toLowerCase();
      return name == 'id' || name == 'key' || name == 'primary';
    });

    if (idField != null) {
      return idField.name;
    }

    idField = possibleFields.firstWhereOrNull((f) => f.type.isNumericType);

    if (idField != null) {
      return idField.name;
    }

    idField = possibleFields.firstWhereOrNull((f) => f.nullable);

    if (idField != null) {
      return idField.name;
    }

    return null;
  }

  List<String>? _fieldsNames;

  @override
  List<String> fieldsNames([O? o]) => _fieldsNames ??= reflection.fieldsNames;

  Map<String, TypeInfo>? _fieldsTypes;

  @override
  Map<String, TypeInfo> fieldsTypes([O? o]) => _fieldsTypes ??=
      Map<String, TypeInfo>.unmodifiable(Map<String, TypeInfo>.fromEntries(
          _fieldsNames!.map((f) => MapEntry(f, getFieldType(o, f)!))));

  @override
  FutureOr<O> createFromMap(Map<String, dynamic> fields) {
    var o = reflection.createInstance()!;
    return setFieldsFromMap(o, fields);
  }

  @override
  String toString() {
    return 'ClassReflectionEntityHandler{$classType}';
  }
}

mixin EntityFieldAccessor<O> {
  dynamic getID(O o, {EntityHandler<O>? entityHandler}) {
    if (o is Entity) {
      return o.getID();
    } else if (entityHandler != null) {
      return entityHandler.getID(o);
    } else if (o is Map) {
      return o['id'];
    } else {
      throw StateError('getID: No EntityHandler provided for: $o');
    }
  }

  void setID(O o, Object id, {EntityHandler<O>? entityHandler}) {
    if (o is Entity) {
      return o.setID(id);
    } else if (entityHandler != null) {
      return entityHandler.setID(o, id);
    } else if (o is Map) {
      o['id'] = id;
    } else {
      throw StateError('setID: No EntityHandler provided for: $o');
    }
  }

  dynamic getField(O o, String key, {EntityHandler<O>? entityHandler}) {
    if (o is Entity) {
      return o.getField(key);
    } else if (entityHandler != null) {
      return entityHandler.getField(o, key);
    } else if (o is Map) {
      return o[key];
    } else {
      throw StateError('getField($key): No EntityHandler provided for: $o');
    }
  }

  void setField(O o, String key, Object? value,
      {EntityHandler<O>? entityHandler}) {
    if (o is Entity) {
      o.setField(key, value);
    } else if (entityHandler != null) {
      entityHandler.setField(o, key, value);
    } else if (o is Map) {
      o[key] = value;
    } else {
      throw StateError('setField($key): No EntityHandler provided for: $o');
    }
  }
}

class EntityFieldAccessorGeneric<O> with EntityFieldAccessor<O> {}

abstract class EntityAccessor<O> {
  final String name;

  EntityAccessor(this.name);
}

abstract class EntitySource<O> extends EntityAccessor<O> {
  EntitySource(String name) : super(name);

  FutureOr<O?> selectByID(dynamic id, {Transaction? transaction}) {
    return select(ConditionID(id)).resolveMapped((sel) {
      return sel.isNotEmpty ? sel.first : null;
    });
  }

  FutureOr<List<O?>> selectByIDs(List<dynamic> ids,
      {Transaction? transaction}) {
    var ret = ids.map((id) => selectByID(id, transaction: transaction));
    return ret.resolveAll();
  }

  FutureOr<int> length({Transaction? transaction}) =>
      count(transaction: transaction);

  FutureOr<int> countByQuery(String query,
      {Object? parameters,
      List? positionalParameters,
      Map<String, Object?>? namedParameters,
      Transaction? transaction}) {
    var condition = _parseCache.parseQuery(query);

    return count(
        matcher: condition,
        parameters: parameters,
        positionalParameters: positionalParameters,
        namedParameters: namedParameters,
        transaction: transaction);
  }

  FutureOr<int> count(
      {EntityMatcher<O>? matcher,
      Object? parameters,
      List? positionalParameters,
      Map<String, Object?>? namedParameters,
      Transaction? transaction});

  final ConditionParseCache<O> _parseCache = ConditionParseCache.get<O>();

  FutureOr<Iterable<O>> selectByQuery(String query,
      {Object? parameters,
      List? positionalParameters,
      Map<String, Object?>? namedParameters,
      Transaction? transaction,
      int? limit}) {
    var condition = _parseCache.parseQuery(query);

    return select(condition,
        parameters: parameters,
        positionalParameters: positionalParameters,
        namedParameters: namedParameters,
        transaction: transaction,
        limit: limit);
  }

  FutureOr<Iterable<O>> select(EntityMatcher<O> matcher,
      {Object? parameters,
      List? positionalParameters,
      Map<String, Object?>? namedParameters,
      Transaction? transaction,
      int? limit});

  FutureOr<Iterable<dynamic>> selectRelationship<E>(O? o, String field,
      {Object? oId, TypeInfo? fieldType, Transaction? transaction});

  FutureOr<Iterable<O>> deleteByQuery(String query,
      {Object? parameters,
      List? positionalParameters,
      Map<String, Object?>? namedParameters,
      Transaction? transaction}) {
    var condition = _parseCache.parseQuery(query);

    return delete(condition,
        parameters: parameters,
        positionalParameters: positionalParameters,
        namedParameters: namedParameters,
        transaction: transaction);
  }

  FutureOr<Iterable<O>> delete(EntityMatcher<O> matcher,
      {Object? parameters,
      List? positionalParameters,
      Map<String, Object?>? namedParameters,
      Transaction? transaction});
}

abstract class EntityStorage<O> extends EntityAccessor<O> {
  EntityStorage(String name) : super(name);

  bool isStored(O o, {Transaction? transaction});

  FutureOr<dynamic> store(O o, {Transaction? transaction});

  FutureOr<Iterable> storeAll(Iterable<O> o, {Transaction? transaction});

  FutureOr<bool> setRelationship<E>(O o, String field, List<E> values,
      {TypeInfo? fieldType, Transaction? transaction});
}

class EntityRepositoryProvider with Closable {
  static final EntityRepositoryProvider _globalProvider =
      EntityRepositoryProvider._global();

  static EntityRepositoryProvider get globalProvider => _globalProvider;

  final Map<Type, EntityRepository> _entityRepositories =
      <Type, EntityRepository>{};

  EntityRepositoryProvider() {
    _globalProvider.notifyKnownEntityRepositoryProvider(this);
  }

  EntityRepositoryProvider._global();

  void registerEntityRepository<O>(EntityRepository<O> entityRepository) {
    checkNotClosed();

    _entityRepositories[entityRepository.type] = entityRepository;
  }

  List<EntityRepository> get registeredEntityRepositories =>
      _entityRepositories.values.toList();

  bool _callingGetEntityRepository = false;

  EntityRepository<O>? getEntityRepository<O>(
      {O? obj, Type? type, String? name}) {
    if (isClosed) return null;

    if (_callingGetEntityRepository) return null;
    _callingGetEntityRepository = true;

    try {
      var entityRepository =
          _getEntityRepositoryImpl<O>(obj: obj, type: type, name: name);
      if (entityRepository != null) {
        return entityRepository;
      }

      if (!identical(this, _globalProvider)) {
        return _globalProvider._getEntityRepositoryImpl<O>(
            obj: obj, type: type, name: name);
      }

      return null;
    } finally {
      _callingGetEntityRepository = false;
    }
  }

  EntityRepository<O>? _getEntityRepositoryImpl<O>(
      {O? obj, Type? type, String? name}) {
    if (!isClosed) {
      var entityRepository = _entityRepositories[O];
      if (entityRepository != null && entityRepository.isClosed) {
        entityRepository = null;
      }

      if (entityRepository != null) {
        return entityRepository as EntityRepository<O>;
      } else if (obj != null) {
        entityRepository = _entityRepositories[obj.runtimeType];
        if (entityRepository != null && entityRepository.isClosed) {
          entityRepository = null;
        }
      }

      if (entityRepository != null) {
        return entityRepository as EntityRepository<O>;
      } else if (type != null) {
        entityRepository = _entityRepositories[type];
        if (entityRepository != null && entityRepository.isClosed) {
          entityRepository = null;
        }
      }

      if (entityRepository != null) {
        return entityRepository as EntityRepository<O>;
      } else if (name != null) {
        entityRepository =
            _entityRepositories.values.where((e) => e.name == name).firstOrNull;
        if (entityRepository != null && entityRepository.isClosed) {
          entityRepository = null;
        }

        if (entityRepository != null) {
          return entityRepository as EntityRepository<O>;
        }
      }
    }

    for (var p in _knownEntityRepositoryProviders) {
      var entityRepository =
          p.getEntityRepository<O>(obj: obj, type: type, name: name);
      if (entityRepository != null) {
        return entityRepository;
      }
    }

    return null;
  }

  final Set<EntityRepositoryProvider> _knownEntityRepositoryProviders =
      <EntityRepositoryProvider>{};

  void notifyKnownEntityRepositoryProvider(EntityRepositoryProvider provider) {
    if (!identical(provider, globalProvider)) {
      _knownEntityRepositoryProviders.add(provider);
    }
  }
}

abstract class EntityRepository<O> extends EntityAccessor<O>
    with Initializable, Closable
    implements EntitySource<O>, EntityStorage<O> {
  static FutureOr<Map<String, dynamic>> resolveSubEntitiesFields(
      Map<String, dynamic> fields, Map<String, Type> subEntitiesFields,
      {Object? Function(String field, Map<String, dynamic> map)? fromMap,
      Object? Function(String field)? empty,
      EntityRepositoryProvider? entityRepositoryProvider,
      EntityHandlerProvider? entityHandlerProvider}) {
    if (subEntitiesFields.isEmpty) return fields;

    var entries = subEntitiesFields.entries.toList(growable: false);

    var futures = entries.map((e) {
      var f = e.key;
      var t = e.value;

      var fromMapField = fromMap != null ? (m) => fromMap(f, m) : null;
      var emptyField = empty != null ? () => empty(f) : null;

      return resolveEntityFromMap(
          parentMap: fields,
          entityField: f,
          fromMap: fromMapField,
          empty: emptyField,
          entityType: t,
          entityRepositoryProvider: entityRepositoryProvider,
          entityHandlerProvider: entityHandlerProvider);
    });

    return futures.resolveAllJoined((resolvedEntities) {
      var map2 = Map<String, dynamic>.from(fields);

      for (var i = 0; i < entries.length; ++i) {
        var f = entries[i].key;
        var o = resolvedEntities[i];
        map2[f] = o;
      }

      return map2;
    });
  }

  static FutureOr<E?> resolveEntityFromMap<E>(
      {Object? entityMap,
      Map<String, dynamic>? parentMap,
      String? entityField,
      E? Function(Map<String, dynamic> map)? fromMap,
      E? Function()? empty,
      Type? entityType,
      EntityRepositoryProvider? entityRepositoryProvider,
      EntityHandlerProvider? entityHandlerProvider}) {
    if (entityMap == null) {
      if (parentMap == null || entityField == null) {
        throw ArgumentError(
            'If `entityValue` is null, `parentMap` and `entityField` should be provided');
      }

      entityMap = parentMap[entityField];
    }

    FutureOr<E?> entity;

    if (entityMap is Map<String, dynamic>) {
      if (fromMap != null) {
        entity = fromMap(entityMap);
      }

      if (entity == null) {
        var entityRepository = _resolveEntityRepository<E>(entityField,
            entityType, entityRepositoryProvider, entityHandlerProvider);
        entity = entityRepository?.fromMap(entityMap);
      }

      if (entity == null) {
        entityHandlerProvider ??= EntityHandlerProvider.globalProvider;
        var entityHandler =
            entityHandlerProvider.getEntityHandler<E>(type: entityType);
        entity = entityHandler?.createFromMap(entityMap);
      }
    } else if (entityMap is num || entityMap is String) {
      var entityRepository = _resolveEntityRepository<E>(entityField,
          entityType, entityRepositoryProvider, entityHandlerProvider);
      entity = entityRepository?.selectByID(entityMap);
    }

    if (entity == null && empty != null) {
      return empty();
    } else {
      return entity;
    }
  }

  static EntityRepository<E>? _resolveEntityRepository<E>(
      String? entityField,
      Type? entityType,
      EntityRepositoryProvider? entityRepositoryProvider,
      EntityHandlerProvider? entityHandlerProvider) {
    if (entityRepositoryProvider == null && entityHandlerProvider != null) {
      var entityRepository = entityHandlerProvider.getEntityRepository<E>(
          type: entityType, name: entityField);
      if (entityRepository != null) {
        return entityRepository;
      }
    }

    entityRepositoryProvider ??= EntityRepositoryProvider.globalProvider;

    var entityRepository = entityRepositoryProvider.getEntityRepository<E>(
        type: entityType, name: entityField);
    return entityRepository;
  }

  final EntityRepositoryProvider provider;

  final EntityHandler<O> entityHandler;
  final Type type;

  EntityRepository(
      EntityRepositoryProvider? provider, String name, this.entityHandler,
      {Type? type})
      : provider = provider ?? EntityRepositoryProvider.globalProvider,
        type = type ?? O,
        super(name) {
    if (!EntityHandler.isValidType(this.type)) {
      throw StateError('Invalid EntityRepository type: $type ?? $O');
    }

    this.provider.registerEntityRepository(this);

    entityHandler.notifyKnownEntityRepositoryProvider(this.provider);
  }

  FutureOr<O> fromMap(Map<String, dynamic> fields) =>
      entityHandler.createFromMap(fields);

  @override
  FutureOr<O?> selectByID(dynamic id, {Transaction? transaction}) {
    checkNotClosed();

    return select(ConditionID(id), transaction: transaction)
        .resolveMapped((sel) {
      return sel.isNotEmpty ? sel.first : null;
    });
  }

  @override
  FutureOr<List<O?>> selectByIDs(List<dynamic> ids,
      {Transaction? transaction}) {
    var ret = ids.map((id) => selectByID(id, transaction: transaction));
    return ret.resolveAll();
  }

  FutureOr<dynamic> ensureStored(O o, {Transaction? transaction});

  FutureOr<bool> ensureReferencesStored(O o, {Transaction? transaction});

  @override
  final ConditionParseCache<O> _parseCache = ConditionParseCache.get<O>();

  @override
  FutureOr<int> countByQuery(String query,
      {Object? parameters,
      List? positionalParameters,
      Map<String, Object?>? namedParameters,
      Transaction? transaction}) {
    checkNotClosed();

    var condition = _parseCache.parseQuery(query);

    return count(
        matcher: condition,
        parameters: parameters,
        positionalParameters: positionalParameters,
        namedParameters: namedParameters,
        transaction: transaction);
  }

  @override
  FutureOr<Iterable<O>> selectByQuery(String query,
      {Object? parameters,
      List? positionalParameters,
      Map<String, Object?>? namedParameters,
      Transaction? transaction,
      int? limit}) {
    checkNotClosed();

    var condition = _parseCache.parseQuery(query);

    return select(condition,
        parameters: parameters,
        positionalParameters: positionalParameters,
        namedParameters: namedParameters,
        transaction: transaction,
        limit: limit);
  }

  @override
  FutureOr<Iterable<O>> deleteByQuery(String query,
      {Object? parameters,
      List? positionalParameters,
      Map<String, Object?>? namedParameters,
      Transaction? transaction}) {
    checkNotClosed();

    var condition = _parseCache.parseQuery(query);

    return delete(condition,
        parameters: parameters,
        positionalParameters: positionalParameters,
        namedParameters: namedParameters,
        transaction: transaction);
  }

  Map<String, dynamic> information();

  @override
  String toString() {
    var info = information();
    return 'EntityRepository{ name: $name, provider: $provider, type: $type, information: $info }';
  }
}

typedef TransactionExecution<R, C> = FutureOr<R> Function(C context);

class Transaction {
  static Transaction? _executingTransaction;

  static Transaction? get executingTransaction => _executingTransaction;

  static int _idCount = 0;
  final int id = ++_idCount;

  final List<TransactionOperation> _operations = <TransactionOperation>[];

  final List<TransactionOperation> _executedOperations =
      <TransactionOperation>[];

  final bool autoCommit;

  Transaction({this.autoCommit = false});

  Transaction.autoCommit() : this(autoCommit: true);

  factory Transaction.executingOrNew({bool autoCommit = true}) {
    return _executingTransaction ?? Transaction(autoCommit: autoCommit);
  }

  bool get isExecuting => identical(Transaction.executingTransaction, this);

  bool _committed = false;

  bool get isCommitted => _committed;

  int get length => _operations.length;

  bool get isEmpty => _operations.isEmpty;

  int get notExecutedOperationsSize =>
      _operations.length - _executedOperations.length;

  bool isLastExecutingOperation(TransactionOperation op) {
    if (isEmpty) return false;

    var notExecuted = notExecutedOperationsSize;
    if (notExecuted > 1) {
      return false;
    }

    if (!_operations.contains(op)) {
      throw StateError("Operation not in transaction: $op");
    }

    if (notExecuted == 1) {
      return !_executedOperations.contains(op);
    } else {
      return _executedOperations.last == op;
    }
  }

  bool _opening = false;

  bool get isOpening => _opening;

  void open(FutureOr<Object> Function() opener) {
    _opening = true;
    opener().resolveMapped(_setContext);
  }

  final Completer<bool> _openCompleter = Completer<bool>();

  bool _open = false;

  bool get isOpen => _open;

  Object? _context;

  Object? get context => _context;

  void _setContext(Object context) {
    _context = context;
    _open = true;
    _openCompleter.complete(true);
  }

  FutureOr<R> onOpen<R>(FutureOr<R> Function() f) {
    if (_open) {
      return f();
    } else {
      return _openCompleter.future.then((_) {
        return f();
      });
    }
  }

  FutureOr? transactionResult;

  final Completer _transactionCompleter = Completer();

  Future get transactionFuture => _transactionCompleter.future;

  final Completer _resultCompleter = Completer();

  Future get resultFuture => _resultCompleter.future;

  Object? _result;

  Object? get result => _result;

  void addOperation(TransactionOperation op) {
    if (_operations.contains(op)) {
      throw StateError("Operation already in transaction: $op");
    }
    _operations.add(op);
    op.id = _operations.length;
  }

  FutureOr<R> finishOperation<R>(TransactionOperation op, R result) {
    _markOperationExecuted(op, result);

    if (op.transactionRoot && !op.externalTransaction && length > 1) {
      return resultFuture.then((_) => result);
    } else {
      return result;
    }
  }

  Completer<bool>? _waitingExecutedOperation = Completer<bool>();

  Object? _lastResult;

  void _markOperationExecuted(TransactionOperation op, Object? result) {
    if (_executedOperations.contains(op)) {
      throw StateError("Operation already executed in transaction: $op");
    }
    _executedOperations.add(op);

    _lastResult = result;

    var waitingExecutedOperation = _waitingExecutedOperation;
    if (waitingExecutedOperation != null &&
        !waitingExecutedOperation.isCompleted) {
      waitingExecutedOperation.complete(true);
      _waitingExecutedOperation = null;
    }

    _doAutoCommit();
  }

  FutureOr<bool> waitAllExecuted() {
    if (_executedOperations.length == _operations.length) {
      return true;
    }
    return _waitAllExecutedImpl();
  }

  Future<bool> _waitAllExecutedImpl() async {
    while (_executedOperations.length < _operations.length) {
      var completer = _waitingExecutedOperation ??= Completer<bool>();
      await completer.future;
    }
    return true;
  }

  void _doAutoCommit() {
    if (autoCommit && _executedOperations.length == _operations.length) {
      commit();
    }
  }

  bool _commitCalled = false;

  FutureOr<R?> commit<R>() {
    if (_commitCalled) {
      FutureOr<dynamic> retFuture;
      if (transactionResult != null) {
        retFuture = transactionResult;
      } else {
        retFuture = _transactionCompleter.future;
      }
      return retFuture.resolveMapped((r) => r as R?);
    }

    _commitCalled = true;

    return waitAllExecuted().resolveMapped((_) => _commitImpl());
  }

  FutureOr<R?> _commitImpl<R>() {
    var result = _lastResult;
    _result = result;

    _transactionCompleter.complete(result);

    if (transactionResult != null) {
      return transactionResult!.resolveMapped((r) {
        _resultCompleter.complete(r);
        _committed = true;
        return r as R?;
      });
    } else {
      return _transactionCompleter.future.then((r) {
        _resultCompleter.complete(r);
        _committed = true;
        return r as R?;
      });
    }
  }

  /// Executes the transaction operations dispatches inside [block] then [commit]s.
  FutureOr<R?> execute<R>(FutureOr<R?> Function() block) {
    if (_commitCalled) {
      throw StateError('Transaction committed already dispatched: $this');
    }

    if (_executingTransaction != null) {
      throw StateError(
          'Already executing a Transaction: _executingTransaction');
    }

    _executingTransaction = this;

    return block().resolveMapped((r) {
      return commit().resolveMapped((result) {
        _executingTransaction = null;
        return r;
      });
    });
  }

  final List<FutureOr> _executionsFutures = <FutureOr>[];

  FutureOr<R> addExecution<R, C>(TransactionExecution<R, C> exec) {
    if (_executionsFutures.isEmpty) {
      var ret = exec(context! as C);
      _executionsFutures.add(ret);
      return ret;
    } else {
      var last = _executionsFutures.last;

      var ret = last.resolveWith(() {
        return exec(context! as C);
      });

      _executionsFutures.add(ret);
      return ret;
    }
  }

  @override
  String toString() {
    return [
      'Transaction[#$id]{\n',
      '  operations: [\n',
      if (_operations.isNotEmpty) '    ${_operations.join(',\n    ')}',
      '\n  ],\n',
      '  executedOperations: [\n',
      if (_executedOperations.isNotEmpty)
        '    ${_executedOperations.join(',\n    ')}',
      '\n  ]\n',
      '  result: $_result\n',
      '}'
    ].join();
  }
}

abstract class TransactionOperation {
  final TransactionOperationType type;
  Object? command;

  int? id;

  late final Transaction transaction;
  late final bool externalTransaction;
  late final bool transactionRoot;

  TransactionOperation(this.type, Transaction? transaction) {
    externalTransaction = transaction != null;

    var resolvedTransaction = transaction ?? Transaction.executingOrNew();
    this.transaction = resolvedTransaction;

    transactionRoot =
        resolvedTransaction.isEmpty && !resolvedTransaction.isExecuting;

    resolvedTransaction.addOperation(this);
  }

  int get transactionId => transaction.id;

  TransactionExecution? execution;

  String get _commandToString => command == null ? '' : ', command: $command';

  FutureOr<R> finish<R>(R result) => transaction.finishOperation(this, result);
}

class TransactionOperationSelect<O> extends TransactionOperation {
  final EntityMatcher matcher;

  TransactionOperationSelect(this.matcher, [Transaction? transaction])
      : super(TransactionOperationType.select, transaction);

  @override
  String toString() {
    return 'TransactionOperation[#$id:select]{matcher: $matcher$_commandToString}';
  }
}

class TransactionOperationCount<O> extends TransactionOperation {
  final EntityMatcher? matcher;

  TransactionOperationCount([this.matcher, Transaction? transaction])
      : super(TransactionOperationType.count, transaction);

  @override
  String toString() {
    return 'TransactionOperation[#$id:count]{matcher: $matcher$_commandToString}';
  }
}

class TransactionOperationStore<O> extends TransactionOperation {
  final O entity;

  TransactionOperationStore(this.entity, [Transaction? transaction])
      : super(TransactionOperationType.store, transaction);

  @override
  String toString() {
    return 'TransactionOperation[#$id:store]{entity: $entity$_commandToString}';
  }
}

class TransactionOperationUpdate<O> extends TransactionOperation {
  final O entity;

  TransactionOperationUpdate(this.entity, [Transaction? transaction])
      : super(TransactionOperationType.update, transaction);

  @override
  String toString() {
    return 'TransactionOperation[#$id:update]{entity: $entity$_commandToString}';
  }
}

class TransactionOperationStoreRelationship<O, E> extends TransactionOperation {
  final O entity;
  final List<E> others;

  TransactionOperationStoreRelationship(this.entity, this.others,
      [Transaction? transaction])
      : super(TransactionOperationType.storeRelationship, transaction);

  @override
  String toString() {
    return 'TransactionOperation[#$id:storeRelationship]{entity: $entity, other: $others$_commandToString}';
  }
}

class TransactionOperationConstrainRelationship<O, E>
    extends TransactionOperation {
  final O entity;
  final List<E> others;

  TransactionOperationConstrainRelationship(this.entity, this.others,
      [Transaction? transaction])
      : super(TransactionOperationType.constrainRelationship, transaction);

  @override
  String toString() {
    return 'TransactionOperation[#$id:constrainRelationship]{entity: $entity, other: $others$_commandToString}';
  }
}

class TransactionOperationSelectRelationship<O> extends TransactionOperation {
  final O entity;

  TransactionOperationSelectRelationship(this.entity,
      [Transaction? transaction])
      : super(TransactionOperationType.selectRelationship, transaction);

  @override
  String toString() {
    return 'TransactionOperation[#$id:selectRelationship]{entity: $entity$_commandToString}';
  }
}

class TransactionOperationDelete<O> extends TransactionOperation {
  final EntityMatcher matcher;

  TransactionOperationDelete(this.matcher, [Transaction? transaction])
      : super(TransactionOperationType.delete, transaction);

  @override
  String toString() {
    return 'TransactionOperation[#$id:delete]{matcher: $matcher$_commandToString}';
  }
}

enum TransactionOperationType {
  select,
  count,
  store,
  storeRelationship,
  constrainRelationship,
  selectRelationship,
  update,
  delete
}

extension TransactionOperationTypeExtension on TransactionOperationType {
  String get name {
    switch (this) {
      case TransactionOperationType.select:
        return 'select';
      case TransactionOperationType.count:
        return 'count';
      case TransactionOperationType.store:
        return 'store';
      case TransactionOperationType.storeRelationship:
        return 'storeRelationship';
      case TransactionOperationType.constrainRelationship:
        return 'constrainRelationship';
      case TransactionOperationType.selectRelationship:
        return 'selectRelationship';
      case TransactionOperationType.update:
        return 'update';
      case TransactionOperationType.delete:
        return 'delete';
      default:
        throw ArgumentError("Unknown: $this");
    }
  }
}

abstract class IterableEntityRepository<O> extends EntityRepository<O>
    with EntityFieldAccessor<O> {
  IterableEntityRepository(String name, EntityHandler<O> entityHandler,
      {EntityRepositoryProvider? provider})
      : super(provider, name, entityHandler);

  Iterable<O> iterable();

  dynamic nextID();

  void put(O o);

  void remove(O o);

  @override
  FutureOr<int> count(
      {EntityMatcher<O>? matcher,
      Object? parameters,
      List? positionalParameters,
      Map<String, Object?>? namedParameters,
      Transaction? transaction}) {
    checkNotClosed();

    if (matcher == null) {
      return iterable().length;
    }

    return iterable().where((o) {
      return matcher.matchesEntity(
        o,
        entityHandler: entityHandler,
        parameters: parameters,
        positionalParameters: positionalParameters,
        namedParameters: namedParameters,
      );
    }).length;
  }

  @override
  Iterable<O> select(EntityMatcher<O> matcher,
      {Object? parameters,
      List? positionalParameters,
      Map<String, Object?>? namedParameters,
      Transaction? transaction,
      int? limit}) {
    checkNotClosed();

    return matches(matcher,
        parameters: parameters,
        positionalParameters: positionalParameters,
        namedParameters: namedParameters,
        limit: limit);
  }

  @override
  O? selectByID(id, {Transaction? transaction}) {
    checkNotClosed();

    return iterable().firstWhereOrNull((o) {
      var oId = getID(o, entityHandler: entityHandler);
      return oId == id;
    });
  }

  @override
  bool isStored(O o, {Transaction? transaction}) {
    var id = entityHandler.getID(o);
    return id != null;
  }

  @override
  dynamic store(O o, {Transaction? transaction}) {
    checkNotClosed();

    var op = TransactionOperationStore(o, transaction);

    return ensureReferencesStored(o, transaction: op.transaction)
        .resolveWith(() {
      var oId = getID(o, entityHandler: entityHandler);

      if (oId == null) {
        oId = nextID();
        setID(o, oId, entityHandler: entityHandler);
        put(o);
      }

      op.transaction._markOperationExecuted(op, oId);

      return oId;
    });
  }

  @override
  Iterable<dynamic> storeAll(Iterable<O> os, {Transaction? transaction}) {
    checkNotClosed();

    transaction ??= Transaction.autoCommit();
    return os.map((o) => store(o, transaction: transaction)).toList();
  }

  @override
  FutureOr<bool> setRelationship<E>(O o, String field, List<E> values,
      {TypeInfo? fieldType, Transaction? transaction}) {
    checkNotClosed();

    fieldType ??= entityHandler.getFieldType(o, field)!;

    var op = TransactionOperationStoreRelationship(o, values, transaction);

    var valuesType = fieldType.listEntityType.type;
    var valuesRepository = provider.getEntityRepository<E>(type: valuesType)!;

    var oId = getID(o, entityHandler: entityHandler);

    var valuesIds = values.map((e) => valuesRepository.entityHandler.getID(e));

    var valuesIdsNotNull = IterableNullableExtension(valuesIds).whereNotNull();

    return putRelationship(oId, valuesType, valuesIdsNotNull)
        .resolveMapped((ok) {
      op.transaction._markOperationExecuted(op, ok);
      return ok;
    });
  }

  FutureOr<bool> putRelationship(
      Object oId, Type valuesType, Iterable<Object> valuesIds);

  @override
  FutureOr<Iterable<dynamic>> selectRelationship<E>(O? o, String field,
      {Object? oId, TypeInfo? fieldType, Transaction? transaction}) {
    checkNotClosed();

    fieldType ??= entityHandler.getFieldType(o, field)!;
    oId ??= getID(o!, entityHandler: entityHandler)!;
    var valuesType = fieldType.listEntityType.type;

    var op = TransactionOperationSelectRelationship(o ?? oId, transaction);

    var valuesIds = getRelationship(oId!, valuesType);
    op.transaction._markOperationExecuted(op, valuesIds);

    return valuesIds;
  }

  List<Object> getRelationship(Object oId, Type valuesType);

  @override
  FutureOr<dynamic> ensureStored(O o, {Transaction? transaction}) {
    checkNotClosed();

    transaction ??= Transaction.autoCommit();

    var id = getID(o, entityHandler: entityHandler);

    if (id == null) {
      return store(o, transaction: transaction);
    } else {
      return ensureReferencesStored(o, transaction: transaction)
          .resolveWithValue(id);
    }
  }

  @override
  FutureOr<bool> ensureReferencesStored(O o, {Transaction? transaction}) {
    checkNotClosed();

    transaction ??= Transaction.autoCommit();

    var fieldsNames = entityHandler.fieldsNames(o);

    var futures = fieldsNames.map((fieldName) {
      var value = entityHandler.getField(o, fieldName);
      if (value == null) return null;

      var fieldType = entityHandler.getFieldType(o, fieldName)!;

      if (!EntityHandler.isValidType(fieldType.type)) {
        return null;
      }

      if (value is List && fieldType.isList && fieldType.hasArguments) {
        var elementType = fieldType.arguments.first;

        var elementRepository =
            provider.getEntityRepository(type: elementType.type);
        if (elementRepository == null) return null;

        var futures = value.map((e) {
          return elementRepository.ensureStored(e, transaction: transaction);
        }).toList();

        return futures.resolveAll();
      } else {
        var repository =
            provider.getEntityRepository(type: fieldType.type, obj: value);
        if (repository == null) return null;

        return repository.ensureStored(value, transaction: transaction);
      }
    });

    return futures.resolveAllWithValue(true);
  }

  @override
  FutureOr<Iterable<O>> delete(EntityMatcher<O> matcher,
      {Object? parameters,
      List? positionalParameters,
      Map<String, Object?>? namedParameters,
      Transaction? transaction}) {
    checkNotClosed();

    var del = matches(matcher,
        parameters: parameters,
        positionalParameters: positionalParameters,
        namedParameters: namedParameters);

    for (var o in del) {
      remove(o);
    }

    return del;
  }

  List<O> matches(EntityMatcher<dynamic> matcher,
      {Object? parameters,
      List? positionalParameters,
      Map<String, Object?>? namedParameters,
      int? limit}) {
    var itr = iterable().where((o) {
      return matcher.matchesEntity(
        o,
        entityHandler: entityHandler,
        parameters: parameters,
        positionalParameters: positionalParameters,
        namedParameters: namedParameters,
      );
    });

    if (limit != null && limit > 0) {
      itr = itr.take(limit);
    }

    return itr.toList();
  }

  @override
  Map<String, dynamic> information() => {
        'length': length(),
        'nextID': nextID(),
      };
}

class SetEntityRepository<O> extends IterableEntityRepository<O> {
  SetEntityRepository(String name, EntityHandler<O> entityHandler,
      {EntityRepositoryProvider? provider})
      : super(name, entityHandler, provider: provider);

  final Set<O> _entries = <O>{};

  @override
  Iterable<O> iterable() => _entries;

  @override
  int nextID() => _entries.length + 1;

  @override
  int length({Transaction? transaction}) => _entries.length;

  @override
  void put(O o) {
    _entries.add(o);
  }

  @override
  void remove(O o) {
    _entries.remove(o);
  }

  final Map<Type, Map<Object, Set<Object>>> _relationships =
      <Type, Map<Object, Set<Object>>>{};

  @override
  FutureOr<bool> putRelationship(
      Object oId, Type valuesType, Iterable<Object> valuesIds) {
    var typeRelationships =
        _relationships.putIfAbsent(valuesType, () => <Object, Set<Object>>{});

    typeRelationships[oId] = valuesIds.toSet();

    return true;
  }

  @override
  List<Object> getRelationship(Object oId, Type valuesType) {
    var typeRelationships = _relationships[valuesType];

    var idReferences = typeRelationships?[oId];

    return idReferences?.toList() ?? <Object>[];
  }
}
