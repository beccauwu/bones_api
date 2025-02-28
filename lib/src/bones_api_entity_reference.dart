import 'package:async_extension/async_extension.dart';
import 'package:collection/collection.dart';
import 'package:logging/logging.dart' as logging;
import 'package:reflection_factory/reflection_factory.dart';
import 'package:statistics/statistics.dart' show IterableExtension;

import 'bones_api_entity.dart';
import 'bones_api_extension.dart';
import 'bones_api_utils_collections.dart';

final _log = logging.Logger('EntityReference');

typedef EntityFetcher<T> = FutureOr<T?> Function(Object? id, Type type);

typedef EntitiesFetcher<T> = FutureOr<List<T?>?> Function(
    List<Object?> ids, Type type);

/// Base class for [EntityReference] and [EntityReferenceList].
abstract class EntityReferenceBase<T> {
  Type? _type;

  String? _typeName;

  EntityHandler<T>? _entityHandler;

  final EntityHandlerProvider? _entityHandlerProvider;

  EntityProvider? _entityProvider;

  EntityReferenceBase._(
      Type? type,
      String? typeName,
      EntityHandler<T>? entityHandler,
      EntityProvider? entityProvider,
      EntityHandlerProvider? entityHandlerProvider)
      : _type = type,
        _typeName = typeName,
        _entityHandler = entityHandler,
        _entityHandlerProvider = entityHandlerProvider,
        _entityProvider = entityProvider {
    _resolveType();
    _resolveEntityHandler();
    _resolveEntityProvider();
  }

  EntityReferenceBase<E> cast<E>();

  EntityReferenceBase<T> copy({bool withEntity = true});

  /// The entity [Type].
  Type get type => _type ??= _resolveType();

  Type _resolveType() {
    var type = _resolveTypeImpl();

    _checkValidEntityType(type);

    _type = type!;

    return type;
  }

  /// The entity [Type] name.
  String get typeName => _typeName ??= _resolveTypeName();

  String _resolveTypeName() {
    var entityHandler = this.entityHandler;
    if (entityHandler != null) {
      return entityHandler.typeName;
    }

    var classReflection = ReflectionFactory().getRegisterClassReflection(type);
    if (classReflection != null) {
      return classReflection.className;
    }

    var typeName = '$type';
    return typeName;
  }

  static final String _typeEntityReferenceStr =
      _getTypeNamePrefix(EntityReference);

  static final String _typeEntityReferenceListStr =
      _getTypeNamePrefix(EntityReferenceList);

  static String _getTypeNamePrefix(Type type) {
    var s = '$type<';
    var idx = s.indexOf('<');
    assert(idx > 0);
    var prefix = s.substring(0, idx + 1);
    return prefix;
  }

  void _checkGenericType() {
    var typeStr = type.toString();

    if (type == EntityReference ||
        type == EntityReferenceList ||
        (typeStr.startsWith(_typeEntityReferenceStr) ||
            typeStr.startsWith(_typeEntityReferenceListStr))) {
      throw StateError(
          "Can't have an entity reference (`$runtimeType`) pointing to another reference type (`$type`).");
    }

    var typeName = this.typeName;

    if (typeName.isEmpty || typeName.startsWith("minify:")) {
      throw StateError("Invalid `Type` name: $typeName");
    }

    if (T != type) {
      _log.warning("`T` ($T) != `type` ($type): $this");
    }
  }

  void _checkValidEntityType(Type? type) {
    if (type == null) {
      throw StateError(
          "Can't resolve `$runtimeType` type> T: $T ; type: $_type ; typeName: $_typeName");
    }

    if (_isInvalidEntityType(type)) {
      throw StateError(
          "Invalid `$runtimeType` type `$type`. Please declare it with a correct `T` ($T), `type` ($_type) or `typeName` ($_typeName).");
    }
  }

  Type? _resolveTypeImpl() {
    var type = _type;
    if (type != null) return type;

    type = T;
    if (!_isInvalidEntityType(type)) return type;

    var typeName = _typeName;

    if (typeName != null && typeName.isNotEmpty) {
      var entityHandler = _resolveEntityHandler();

      if (entityHandler != null) {
        var typeEntityHandler =
            entityHandler.getEntityHandler(typeName: typeName);
        if (typeEntityHandler != null) {
          return typeEntityHandler.type;
        }

        var entityRepository =
            entityHandler.getEntityRepository(name: typeName);
        if (entityRepository != null) {
          return entityRepository.type;
        }
      }
    }

    return type;
  }

  bool _isInvalidEntityType(Type type) =>
      type == Object ||
      type == dynamic ||
      type == int ||
      type == String ||
      type == BigInt ||
      type == List ||
      type == Iterable ||
      type == Map ||
      type == Set;

  bool _isInvalidEntity(Object entity) =>
      entity is EntityReference ||
      entity is List ||
      entity is Map ||
      entity is Set;

  /// The [EntityHandler] for this entity [type].
  EntityHandler<T>? get entityHandler => _resolveEntityHandler();

  EntityHandler<T>? _resolveEntityHandler() =>
      _entityHandler ??= _resolveEntityHandlerImpl();

  EntityHandler<T>? _resolveEntityHandlerImpl() {
    EntityHandler<T>? entityHandler;

    var entityHandlerProvider = _entityHandlerProvider;

    if (entityHandlerProvider != null) {
      entityHandler = entityHandlerProvider.getEntityHandler(
          type: _type, typeName: _typeName);

      if (entityHandler != null) {
        return entityHandler;
      }
    }

    var entityProvider = _entityProvider;

    if (entityProvider is EntityHandlerProvider) {
      var handlerProvider = entityProvider as EntityHandlerProvider;
      entityHandler =
          handlerProvider.getEntityHandler(type: _type, typeName: _typeName);

      if (entityHandler != null) {
        return entityHandler;
      }
    }

    entityHandler = EntityHandlerProvider.globalProvider
        .getEntityHandler(type: _type, typeName: _typeName);

    if (entityHandler != null) {
      return entityHandler;
    }

    var typeName = _typeName;
    if ((typeName == null || typeName.isEmpty) && !_isInvalidEntityType(type)) {
      typeName = '$type';
    }

    if (typeName != null && typeName.isNotEmpty) {
      var classReflection =
          ReflectionFactory().getRegisterClassReflectionByName(typeName);

      if (classReflection != null) {
        var classEntityHandler = classReflection.entityHandler;
        if (classEntityHandler is EntityHandler<T>) {
          entityHandler = classEntityHandler as EntityHandler<T>;
        }
      }
    }

    return entityHandler;
  }

  /// The [EntityProvider] for this entity [type].
  EntityProvider? get entityProvider => _resolveEntityProvider();

  EntityProvider? _resolveEntityProvider() {
    var entityProvider = _entityProvider;
    if (entityProvider != null) return entityProvider;

    var entityHandler = _resolveEntityHandler();
    var entityRepository = entityHandler?.getEntityRepositoryByType(type);

    _entityProvider = entityProvider = entityRepository?.provider;

    return entityProvider;
  }

  Object? _getEntityID(T? o) {
    if (o == null) return null;

    var entityHandler = _resolveEntityHandler();
    return entityHandler?.getID(o);
  }

  void _checkValidEntity(entity) {
    if (_isInvalidEntity(entity)) {
      var type = this.type;
      throw StateError(
          "Invalid entity instance (${entity.runtimeType}) for `EntityReference<$type>` (`T` ($T), `type` ($_type) or `typeName` ($_typeName)).");
    }
  }

  /// Encodes to JSON.
  Map<String, dynamic>? toJson();

  Map<String, dynamic>? _entityToJsonDefault(Object? entity) {
    if (entity == null) return null;

    try {
      var o = entity as dynamic;
      return o.toJson();
    } catch (_) {
      return null;
    }
  }

  /// Returns `true` if this reference is `null`.
  bool get isNull;

  /// Returns the current entity/entities or fetches.
  FutureOr<Object?> get();

  /// Same as [get] but non-nullable.
  FutureOr getNotNull();

  /// Returns `true` if the entity is loaded;
  bool get isLoaded;

  /// Returns the current internal value (entity or ID).
  Object? get currentValue;

  /// Refreshes fetching it.
  FutureOr refresh();

  @override
  String toString({bool withT = true});
}

/// Reference wrapper to an entity.
class EntityReference<T> extends EntityReferenceBase<T> {
  /// Creates an [EntityReference] with a null [entity] and null [id].
  /// See [isNull].
  EntityReference.asNull(
      {Type? type,
      String? typeName,
      EntityHandler<T>? entityHandler,
      EntityProvider? entityProvider,
      EntityHandlerProvider? entityHandlerProvider,
      EntityFetcher<T>? entityFetcher,
      bool checkGenericType = true})
      : this._(type, typeName, null, null, null, entityHandler, entityProvider,
            entityHandlerProvider, entityFetcher, checkGenericType);

  /// Creates an [EntityReference] with the entity [id] (without a loaded [entity] instance).
  /// See [id] and [isIdSet].
  EntityReference.fromID(Object? id,
      {Type? type,
      String? typeName,
      EntityHandler<T>? entityHandler,
      EntityProvider? entityProvider,
      EntityHandlerProvider? entityHandlerProvider,
      EntityFetcher<T>? entityFetcher,
      bool checkGenericType = true})
      : this._(type, typeName, id, null, null, entityHandler, entityProvider,
            entityHandlerProvider, entityFetcher, checkGenericType);

  /// Creates an [EntityReference] with the [entity] instance.
  /// The [id] is resolved through the [entity] instance.
  /// See [entity] and [isEntitySet].
  EntityReference.fromEntity(T? entity,
      {Type? type,
      String? typeName,
      EntityHandler<T>? entityHandler,
      EntityProvider? entityProvider,
      EntityHandlerProvider? entityHandlerProvider,
      EntityFetcher<T>? entityFetcher,
      bool checkGenericType = true})
      : this._(
            type,
            typeName,
            null,
            entity,
            null,
            entityHandler,
            entityProvider,
            entityHandlerProvider,
            entityFetcher,
            checkGenericType);

  /// Creates an [EntityReference] with an [entity] instance from [entityMap].
  EntityReference.fromEntityMap(Map<String, dynamic>? entityMap,
      {Type? type,
      String? typeName,
      EntityHandler<T>? entityHandler,
      EntityProvider? entityProvider,
      EntityHandlerProvider? entityHandlerProvider,
      EntityFetcher<T>? entityFetcher,
      bool checkGenericType = true})
      : this._(
            type,
            typeName,
            null,
            null,
            entityMap,
            entityHandler,
            entityProvider,
            entityHandlerProvider,
            entityFetcher,
            checkGenericType);

  /// Creates an [EntityReference] from a JSON [Map].
  /// If [json] has an entry `EntityReference` it will be treated as a [Map] from [toJson],
  /// otherwise will be treated as an entity JSON (a [Map] from [entityToJson])
  /// and instantiated through [fromEntityMap].
  factory EntityReference.fromJson(Map<String, dynamic> json,
      {Type? type,
      String? typeName,
      EntityHandler<T>? entityHandler,
      EntityProvider? entityProvider,
      EntityHandlerProvider? entityHandlerProvider,
      EntityFetcher<T>? entityFetcher}) {
    var entityReferenceType = json['EntityReference'];

    if (entityReferenceType != null) {
      if (entityReferenceType is! String) {
        throw ArgumentError("Invalid `EntityReference` JSON: $json");
      }

      typeName ??= entityReferenceType;
      var id = json['id'];
      var entity = json['entity'];

      if (entity != null) {
        var entityMap = entity is Map
            ? entity
            : TypeParser.parseMap(entity) ?? <String, dynamic>{};

        var entityMapCast = entityMap is Map<String, dynamic>
            ? entityMap
            : entityMap.map((key, value) => MapEntry('$key', value));

        return EntityReference<T>.fromEntityMap(entityMapCast,
                type: type,
                typeName: typeName,
                entityHandler: entityHandler,
                entityProvider: entityProvider,
                entityHandlerProvider: entityHandlerProvider,
                entityFetcher: entityFetcher,
                checkGenericType: false)
            ._autoCast();
      } else if (id != null) {
        return EntityReference<T>.fromID(id,
                type: type,
                typeName: typeName,
                entityHandler: entityHandler,
                entityProvider: entityProvider,
                entityHandlerProvider: entityHandlerProvider,
                entityFetcher: entityFetcher,
                checkGenericType: false)
            ._autoCast();
      } else {
        return EntityReference<T>.asNull(
                type: type,
                typeName: typeName,
                entityHandler: entityHandler,
                entityProvider: entityProvider,
                entityHandlerProvider: entityHandlerProvider,
                entityFetcher: entityFetcher,
                checkGenericType: false)
            ._autoCast();
      }
    } else {
      return EntityReference<T>.fromEntityMap(json,
              type: type,
              typeName: typeName,
              entityHandler: entityHandler,
              entityProvider: entityProvider,
              entityHandlerProvider: entityHandlerProvider,
              entityFetcher: entityFetcher,
              checkGenericType: false)
          ._autoCast();
    }
  }

  /// Creates an [EntityReference] from [o] trying to resolve it in the best way.
  factory EntityReference.from(Object? o,
      {Type? type,
      String? typeName,
      EntityHandler<T>? entityHandler,
      EntityProvider? entityProvider,
      EntityHandlerProvider? entityHandlerProvider,
      EntityFetcher<T>? entityFetcher}) {
    if (o == null) {
      return EntityReference<T>.asNull(
              type: type,
              typeName: typeName,
              entityHandler: entityHandler,
              entityProvider: entityProvider,
              entityFetcher: entityFetcher,
              checkGenericType: false)
          ._autoCast();
    } else if (o is EntityReference) {
      return o.cast<T>()._autoCast();
    } else if (o.isEntityIDType) {
      return EntityReference<T>.fromID(o,
              type: type,
              typeName: typeName,
              entityHandler: entityHandler,
              entityProvider: entityProvider,
              entityFetcher: entityFetcher,
              checkGenericType: false)
          ._autoCast();
    } else if (o is Map<String, dynamic>) {
      return EntityReference<T>.fromJson(o,
          type: type,
          typeName: typeName,
          entityHandler: entityHandler,
          entityProvider: entityProvider,
          entityFetcher: entityFetcher);
    } else if (o is T) {
      return EntityReference<T>.fromEntity(o as T,
              type: type,
              typeName: typeName,
              entityHandler: entityHandler,
              entityProvider: entityProvider,
              entityFetcher: entityFetcher,
              checkGenericType: false)
          ._autoCast();
    }

    throw StateError(
        "`T`($T) and `o`($o) not of the same type. Can't resolve `EntityReference`!");
  }

  EntityFetcher<T>? _entityFetcher;

  Object? _id;

  EntityReference._(
      Type? type,
      String? typeName,
      Object? id,
      T? entity,
      Map<String, dynamic>? entityMap,
      EntityHandler<T>? entityHandler,
      EntityProvider? entityProvider,
      EntityHandlerProvider? entityHandlerProvider,
      EntityFetcher<T>? entityFetcher,
      bool checkGenericType)
      : _id = id,
        _entity = entity,
        _entityFetcher = entityFetcher,
        super._(type, typeName, entityHandler, entityProvider,
            entityHandlerProvider) {
    if (entityMap != null) {
      // _id == null && _entity == null
      var entityHandler = this.entityHandler;

      if (entityHandler != null) {
        _id = entityHandler.resolveIDFromMap(entityMap);

        entityHandler.createFromMap(entityMap).resolveMapped((o) {
          set(o);
        });
      } else {
        _id = entityMap['id'];
        _resolveID();
      }
    } else {
      _resolveID();
    }

    var id = _id;
    if (id != null && !id.isEntityIDType) {
      throw ArgumentError("Invalid ID type: ${id.runtimeType} <$id>");
    }

    _resolveEntity();

    if (checkGenericType) {
      _checkGenericType();
    }
  }

  EntityReference<T> _autoCast() {
    var o = _autoCastImpl();
    o._checkGenericType();
    return o;
  }

  EntityReference<T> _autoCastImpl() {
    var genericType = T;
    if (!_isInvalidEntityType(genericType)) return this;

    var o = entityHandler?.typeInfo.callCasted<EntityReference>(<E>() {
      if (_isInvalidEntityType(E)) return this;
      return cast<E>();
    });

    return o is EntityReference<T> ? o : this;
  }

  @override
  EntityReference<E> cast<E>({bool checkGenericType = true}) {
    var o = this;

    if (o is EntityReference<E>) {
      return o as EntityReference<E>;
    } else {
      var entityReference = EntityReference<E>._(
          o._type,
          o._typeName,
          o._id,
          o._entity as E?,
          null,
          o._entityHandler as EntityHandler<E>?,
          o._entityProvider,
          o._entityHandlerProvider,
          o._entityFetcher as EntityFetcher<E>?,
          checkGenericType);

      entityReference._entityTime = o._entityTime;

      return entityReference;
    }
  }

  /// Returns a copy of `this` [EntityReference] instance.
  @override
  EntityReference<T> copy({bool withEntity = true}) {
    var cp = EntityReference<T>._(
        _type,
        _typeName,
        _id,
        withEntity ? _entity : null,
        null,
        _entityHandler,
        _entityProvider,
        _entityHandlerProvider,
        _entityFetcher,
        false);

    if (withEntity) cp._entityTime = _entityTime;

    return cp;
  }

  /// The [entity] [Type].
  @override
  Type get type => super.type;

  /// The [entity] [Type] name.
  @override
  String get typeName => super.typeName;

  /// The entity ID.
  Object? get id => _resolveID();

  Object? _resolveID() {
    var id = _id;
    if (id != null) return id;

    var entity = _entity;
    if (entity == null) return null;

    _id = id = _getEntityID(entity);

    return id;
  }

  T? _entity;

  /// The already loaded entity.
  T? get entity => _resolveEntity();

  T? _resolveEntity() {
    var entity = _entity;

    if (entity == null) {
      var id = this.id;
      var entityProvider = this.entityProvider;

      if (id != null && entityProvider != null) {
        _entity = entity =
            entityProvider.getEntityByID<T>(id, type: type, sync: true) as T?;
      }
    }

    if (entity == null) return null;

    _entityTime ??= DateTime.now();

    if (_id == null) {
      _resolveID();
    }

    _checkValidEntity(entity);

    return entity;
  }

  /// Returns [entity] or [id].
  /// See [isEntitySet] and [isIdSet].
  Object? get entityOrID {
    if (isEntitySet) {
      return entity;
    } else if (isIdSet) {
      return id;
    } else {
      return null;
    }
  }

  DateTime? _entityTime;

  /// The [DateTime] of when the [entity] was [set].
  DateTime? get entityTime => _entityTime;

  /// Returns [entity] as a JSON [Map].
  Map<String, dynamic>? entityToJson() {
    var entity = this.entity;
    if (entity == null) return null;

    var entityHandler = this.entityHandler;

    if (entityHandler != null) {
      return entityHandler.toJson(entity);
    }

    return _entityToJsonDefault(entity);
  }

  /// Encodes [entity] or [id] as JSON. If [isNull] returns `null`.
  Object? entityOrIdToJson() {
    if (isNull) return null;

    if (isEntitySet) {
      return entityToJson();
    } else if (isIdSet) {
      return id!;
    } else {
      return null;
    }
  }

  /// Encodes this [EntityReference] instance to JSON.
  ///
  /// Fields:
  /// - `EntityReference`: the reference type.
  /// - `id`: the entity ID (if [isIdSet]).
  /// - `entity`: the entity as JSON (if [isEntitySet]). See [entityToJson].
  @override
  Map<String, dynamic>? toJson() {
    if (isNull) return null;

    if (isEntitySet) {
      var id = this.id;
      return <String, dynamic>{
        'EntityReference': typeName,
        if (id != null) 'id': id,
        'entity': entityToJson(),
      };
    } else if (isIdSet) {
      var id = this.id!;
      return <String, dynamic>{
        'EntityReference': typeName,
        'id': id,
      };
    } else {
      return <String, dynamic>{
        'EntityReference': typeName,
      };
    }
  }

  /// Sets the [entity] to [o] and returns the current [entity].
  T? set(T? o) {
    if (identical(o, _entity)) return o;

    if (o == null) {
      _id = null;
      _entity = null;
      _entityTime = null;
    } else {
      var id = _getEntityID(o);
      _id = id;
      _entity = o;
      _entityTime = DateTime.now();
    }

    return _entity;
  }

  /// Sets the [entity] [id] and returns the current [id].
  /// If the ID is changing the previous loaded [entity] instance is disposed.
  Object? setID(Object? id) {
    if (id == null) {
      _id = null;
      _entity = null;
      _entityTime = null;
    } else if (id != _id) {
      var prevID = _getEntityID(_entity);

      _id = id;

      if (id != prevID) {
        _entity = null;
        _entityTime = null;
      }
    }

    return _id;
  }

  /// Updates [id] from [entity] instance ID.
  bool updateIdFromEntity() {
    var entity = _entity;
    if (entity == null) return false;

    _id = _getEntityID(entity);
    return true;
  }

  /// Returns `true` if the [entity] instance is loaded.
  bool get isEntitySet => _entity != null;

  /// Returns `true` if [id] is set.
  bool get isIdSet {
    _resolveID();
    return _id != null;
  }

  /// Returns `true` if this reference is `null` (no [id] or [entity] set).
  @override
  bool get isNull => _entity == null && _id == null;

  /// Returns the current [entity] or fetches it.
  @override
  FutureOr<T?> get() {
    var o = entity;
    if (o != null) return o;

    return _fetchAndSet();
  }

  /// Same as [get] but won't return `null`.
  @override
  FutureOr<T> getNotNull() => get().resolveMapped((o) {
        if (o == null) {
          throw StateError(
              "Null entity. Can't `get` entity `$type` with ID `$id`> entityProvider: $entityProvider ; entityFetcher: $_entityFetcher");
        }
        return o;
      });

  /// Returns `true` if the [entity] is loaded;
  @override
  bool get isLoaded => isEntitySet;

  /// Returns the current internal value ([entity] OR [id]).
  @override
  Object? get currentValue => isEntitySet ? entity : id;

  /// Disposes the current loaded [entity] instance and returns it.
  /// Id [id] is defined it will keep it.
  T? disposeEntity() {
    var prev = entity;
    _entity = null;
    _entityTime = null;
    return prev;
  }

  /// Refreshes the [entity] fetching it.
  @override
  FutureOr<T?> refresh() => _fetchAndSet();

  FutureOr<T?> _fetchAndSet() => fetchImpl().resolveMapped(set);

  /// Fetches the [entity], but won't [set] it. Do not call this directly.
  FutureOr<T?> fetchImpl() {
    var entityProvider = this.entityProvider;
    var entityFetcher = _entityFetcher;
    var id = this.id;

    if (id == null) return entity;

    if (entityFetcher != null) {
      return entityFetcher(id, type);
    }

    if (entityProvider == null) return entity;

    return entityProvider.getEntityByID<T>(id, type: type);
  }

  bool? equalsEntityID(Object? otherEntity) {
    if (otherEntity == null) {
      return isNull;
    }

    if (identical(this, otherEntity)) {
      return true;
    }

    if (otherEntity is EntityReference) {
      if (type != otherEntity.type) return false;

      if (otherEntity.isNull) {
        return isNull;
      }

      if (otherEntity.isEntitySet &&
          isEntitySet &&
          identical(entity, otherEntity.entity)) {
        return true;
      }

      if (otherEntity.isIdSet) {
        if (isIdSet) {
          return id == otherEntity.id;
        } else {
          return false;
        }
      } else {
        if (isIdSet) {
          return false;
        } else {
          return null;
        }
      }
    } else if (otherEntity is T) {
      if (isEntitySet && identical(entity, otherEntity)) return true;

      var entityHandler = this.entityHandler;

      if (entityHandler != null) {
        var otherId = entityHandler.getID(otherEntity as T);
        return id == otherId;
      }

      return null;
    } else if (otherEntity.isEntityIDType) {
      return id == otherEntity;
    } else {
      return null;
    }
  }

  @override
  String toString({bool withT = true}) {
    var typeStr = _type?.toString() ?? _typeName ?? '?';
    var prefix = 'EntityReference<$typeStr>';
    if (withT) prefix = '<T:$T> $prefix';

    if (isNull) {
      return '$prefix{null}';
    }

    var id = _id;
    var entity = _entity;

    if (id != null) {
      if (entity != null) {
        return '$prefix{id: $id}<$entity>';
      } else {
        return '$prefix{id: $id}';
      }
    } else {
      return '$prefix<$entity>';
    }
  }

  /// Returns `this` as an [EntityReferenceList] instance.
  EntityReferenceList<T> toEntityReferenceList() {
    var id = this.id;
    var entity = this.entity;

    EntitiesFetcher<T>? fetcher;

    var entityFetcher = _entityFetcher;
    if (entityFetcher != null) {
      fetcher = (ids, type) =>
          ids.map((id) => entityFetcher(id, type)).toList().resolveAll();
    }

    return EntityReferenceList<T>._(
        type,
        null,
        id == null ? null : [id],
        entity == null ? null : [entity],
        null,
        entityHandler,
        entityProvider,
        _entityHandlerProvider,
        fetcher,
        false);
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;

    if (other is! EntityReference || runtimeType != other.runtimeType) {
      return false;
    }

    if (isNull) {
      return other.isNull;
    }

    if (isEntitySet && other.isEntitySet) {
      if (isIdSet && other.isIdSet) {
        return id == other.id && entity == other.entity;
      } else {
        return entity == other.entity;
      }
    }

    if (isIdSet && other.isIdSet) {
      return id == other.id;
    }

    if (isEntitySet && other.isIdSet) {
      return _getEntityID(entity) == other.id;
    }

    return false;
  }

  @override
  int get hashCode {
    if (isNull) return 0;

    if (isIdSet) return _id!.hashCode;

    if (isEntitySet) return _entity!.hashCode;

    return -1;
  }
}

/// Reference wrapper to an entity [List].
class EntityReferenceList<T> extends EntityReferenceBase<T> {
  /// Creates an [EntityReferenceList] with null [entities] and null [ids].
  /// See [isNull], [ids] and [isIDsSet].
  EntityReferenceList.asNull(
      {Type? type,
      String? typeName,
      EntityHandler<T>? entityHandler,
      EntityProvider? entityProvider,
      EntityHandlerProvider? entityHandlerProvider,
      EntitiesFetcher<T>? entitiesFetcher,
      bool checkGenericType = true})
      : this._(type, typeName, null, null, null, entityHandler, entityProvider,
            entityHandlerProvider, entitiesFetcher, checkGenericType);

  /// Creates an empty [EntityReferenceList] (like an empty list).
  /// See [isEmpty], [ids] and [isIDsSet].
  EntityReferenceList.asEmpty(
      {Type? type,
      String? typeName,
      EntityHandler<T>? entityHandler,
      EntityProvider? entityProvider,
      EntityHandlerProvider? entityHandlerProvider,
      EntitiesFetcher<T>? entitiesFetcher,
      bool checkGenericType = true})
      : this._(
            type,
            typeName,
            <Object?>[],
            null,
            null,
            entityHandler,
            entityProvider,
            entityHandlerProvider,
            entitiesFetcher,
            checkGenericType);

  /// Creates an [EntityReferenceList] with the entities [ids] (without a loaded [entities] list).
  /// See [ids] and [isIDsSet].
  EntityReferenceList.fromIDs(List<Object?>? ids,
      {Type? type,
      String? typeName,
      EntityHandler<T>? entityHandler,
      EntityProvider? entityProvider,
      EntityHandlerProvider? entityHandlerProvider,
      EntitiesFetcher<T>? entitiesFetcher,
      bool checkGenericType = true})
      : this._(type, typeName, ids, null, null, entityHandler, entityProvider,
            entityHandlerProvider, entitiesFetcher, checkGenericType);

  /// Creates an [EntityReferenceList] with the [entities] instances list.
  /// The [ids] is resolved through the [entities] instance list.
  /// See [entities] and [isEntitiesSet].
  EntityReferenceList.fromEntities(List<T?>? entities,
      {Type? type,
      String? typeName,
      EntityHandler<T>? entityHandler,
      EntityProvider? entityProvider,
      EntityHandlerProvider? entityHandlerProvider,
      EntitiesFetcher<T>? entitiesFetcher,
      bool checkGenericType = true})
      : this._(
            type,
            typeName,
            null,
            entities,
            null,
            entityHandler,
            entityProvider,
            entityHandlerProvider,
            entitiesFetcher,
            checkGenericType);

  /// Creates an [EntityReferenceList] with an [entities] instance list from [entitiesMaps].
  EntityReferenceList.fromEntitiesMaps(List<Map<String, dynamic>?> entitiesMaps,
      {Type? type,
      String? typeName,
      EntityHandler<T>? entityHandler,
      EntityProvider? entityProvider,
      EntityHandlerProvider? entityHandlerProvider,
      EntitiesFetcher<T>? entitiesFetcher,
      bool checkGenericType = true})
      : this._(
            type,
            typeName,
            null,
            null,
            entitiesMaps,
            entityHandler,
            entityProvider,
            entityHandlerProvider,
            entitiesFetcher,
            checkGenericType);

  /// Creates an [EntityReference] from a JSON [Map].
  /// If [json] has an entry `EntityReference` it will be treated as a [Map] from [toJson],
  /// otherwise will be treated as an entity JSON (a [Map] from [entitiesToJson])
  /// and instantiated through [fromEntityMap].
  factory EntityReferenceList.fromJson(Map<String, dynamic> json,
      {Type? type,
      String? typeName,
      EntityHandler<T>? entityHandler,
      EntityProvider? entityProvider,
      EntityHandlerProvider? entityHandlerProvider,
      EntitiesFetcher<T>? entitiesFetcher}) {
    var entityReferenceType = json['EntityReferenceList'];

    if (entityReferenceType != null) {
      if (entityReferenceType is! String) {
        throw ArgumentError("Invalid `EntityReference` JSON: $json");
      }

      typeName ??= entityReferenceType;
      var ids = json['ids'];
      var entities = json['entities'];

      if (entities != null && entities is List) {
        var entitiesMaps = entities is List<Map<String, dynamic>>
            ? entities
            : entities.map((e) {
                var m = e is Map
                    ? e
                    : TypeParser.parseMap(e) ?? <String, dynamic>{};
                return m is Map<String, dynamic>
                    ? m
                    : m.map((key, value) => MapEntry('$key', value));
              }).toList(growable: false);

        return EntityReferenceList<T>.fromEntitiesMaps(entitiesMaps,
                type: type,
                typeName: typeName,
                entityHandler: entityHandler,
                entityProvider: entityProvider,
                entityHandlerProvider: entityHandlerProvider,
                entitiesFetcher: entitiesFetcher,
                checkGenericType: false)
            ._autoCast();
      } else if (ids != null && ids is List<Object?>) {
        return EntityReferenceList<T>.fromIDs(ids,
                type: type,
                typeName: typeName,
                entityHandler: entityHandler,
                entityProvider: entityProvider,
                entityHandlerProvider: entityHandlerProvider,
                entitiesFetcher: entitiesFetcher,
                checkGenericType: false)
            ._autoCast();
      } else {
        return EntityReferenceList<T>.asEmpty(
                type: type,
                typeName: typeName,
                entityHandler: entityHandler,
                entityProvider: entityProvider,
                entityHandlerProvider: entityHandlerProvider,
                entitiesFetcher: entitiesFetcher,
                checkGenericType: false)
            ._autoCast();
      }
    } else {
      var entityReferenceType = json['EntityReference'];

      if (entityReferenceType != null) {
        var entityReference = EntityReference<T>.fromJson(json);

        var isNull = entityReference.isNull;
        var id = entityReference.id;
        var entity = entityReference.entity;

        return EntityReferenceList<T>._(
                entityReference.type,
                null,
                isNull || id == null ? null : [id],
                isNull || entity == null ? null : [entity],
                null,
                entityReference.entityHandler,
                entityReference.entityProvider,
                entityReference._entityHandlerProvider,
                null,
                false)
            ._autoCast();
      }

      return EntityReferenceList<T>.fromEntitiesMaps(
              <Map<String, dynamic>>[json],
              type: type,
              typeName: typeName,
              entityHandler: entityHandler,
              entityProvider: entityProvider,
              entityHandlerProvider: entityHandlerProvider,
              entitiesFetcher: entitiesFetcher,
              checkGenericType: false)
          ._autoCast();
    }
  }

  /// Creates an [EntityReferenceList] from [o] trying to resolve it in the best way.
  factory EntityReferenceList.from(Object? o,
      {Type? type,
      String? typeName,
      EntityHandler<T>? entityHandler,
      EntityProvider? entityProvider,
      EntityHandlerProvider? entityHandlerProvider,
      EntitiesFetcher<T>? entitiesFetcher}) {
    if (o == null) {
      return EntityReferenceList<T>.asNull(
              type: type,
              typeName: typeName,
              entityHandler: entityHandler,
              entityProvider: entityProvider,
              entitiesFetcher: entitiesFetcher,
              checkGenericType: false)
          ._autoCast();
    } else if (o is EntityReferenceList) {
      return o.cast<T>()._autoCast();
    } else if (o is List &&
        o.every((Object? e) => e == null || e.isEntityIDType)) {
      return EntityReferenceList<T>.fromIDs(o,
              type: type,
              typeName: typeName,
              entityHandler: entityHandler,
              entityProvider: entityProvider,
              entitiesFetcher: entitiesFetcher,
              checkGenericType: false)
          ._autoCast();
    } else if (o is Map<String, dynamic>) {
      return EntityReferenceList<T>.fromJson(o,
          type: type,
          typeName: typeName,
          entityHandler: entityHandler,
          entityProvider: entityProvider,
          entitiesFetcher: entitiesFetcher);
    } else if (o is List<T?>) {
      return EntityReferenceList<T>.fromEntities(o,
              type: type,
              typeName: typeName,
              entityHandler: entityHandler,
              entityProvider: entityProvider,
              entitiesFetcher: entitiesFetcher,
              checkGenericType: false)
          ._autoCast();
    } else if (o is T) {
      return EntityReferenceList<T>.fromEntities(<T>[o as T],
              type: type,
              typeName: typeName,
              entityHandler: entityHandler,
              entityProvider: entityProvider,
              entitiesFetcher: entitiesFetcher,
              checkGenericType: false)
          ._autoCast();
    }

    throw StateError(
        "`T`($T) and `o`($o) not compatible types. Can't resolve `EntityReferenceList`!");
  }

  EntitiesFetcher<T>? _entitiesFetcher;

  List<Object?>? _ids;

  EntityReferenceList._(
      Type? type,
      String? typeName,
      List<Object?>? ids,
      List<T?>? entities,
      List<Map<String, dynamic>?>? entitiesMaps,
      EntityHandler<T>? entityHandler,
      EntityProvider? entityProvider,
      EntityHandlerProvider? entityHandlerProvider,
      EntitiesFetcher<T>? entitiesFetcher,
      bool checkGenericType)
      : _ids = ids,
        _entities = entities,
        _entitiesFetcher = entitiesFetcher,
        super._(type, typeName, entityHandler, entityProvider,
            entityHandlerProvider) {
    if (entitiesMaps != null) {
      // _id == null && _entity == null
      var entityHandler = this.entityHandler;

      if (entityHandler != null) {
        _ids = entitiesMaps
            .map((map) =>
                map == null ? null : entityHandler.resolveIDFromMap(map))
            .toList();

        List<FutureOr<T?>> lAsync = entitiesMaps
            .map((map) => map == null ? null : entityHandler.createFromMap(map))
            .toList(growable: false);

        lAsync.resolveAllNullable().resolveMapped((os) {
          set(os);
        });
      } else {
        _ids = entitiesMaps.map((map) => map?['id']).toList();
        _resolveIDs();
      }
    } else {
      _resolveIDs();
    }

    var ids = _ids;
    if (ids != null && ids.any((id) => id != null && !id.isEntityIDType)) {
      throw ArgumentError(
          "Invalid IDs type: ${ids.runtimeType} ${ids.map((id) => '<$id>')}");
    }

    _resolveEntities();

    if (checkGenericType) {
      _checkGenericType();
    }
  }

  EntityReferenceList<T> _autoCast() {
    var o = _autoCastImpl();
    o._checkGenericType();
    return o;
  }

  EntityReferenceList<T> _autoCastImpl() {
    var genericType = T;
    if (!_isInvalidEntityType(genericType)) return this;

    var o = entityHandler?.typeInfo.callCasted<EntityReferenceList>(<E>() {
      if (_isInvalidEntityType(E)) return this;
      return cast<E>();
    });

    return o is EntityReferenceList<T> ? o : this;
  }

  @override
  EntityReferenceList<E> cast<E>() {
    var o = this;

    if (o is EntityReferenceList<E>) {
      return o as EntityReferenceList<E>;
    } else {
      var entityReferenceList = EntityReferenceList<E>._(
          o._type,
          o._typeName,
          o._ids,
          _castListNullable<E>(o._entities),
          null,
          o._entityHandler as EntityHandler<E>?,
          o._entityProvider,
          o._entityHandlerProvider,
          o._entitiesFetcher as EntitiesFetcher<E>?,
          false);

      entityReferenceList._entitiesTime = o._entitiesTime;

      return entityReferenceList;
    }
  }

  /// Returns a copy of `this` [EntityReference] instance.
  @override
  EntityReferenceList<T> copy({bool withEntity = true}) {
    var cp = EntityReferenceList<T>._(
        _type,
        _typeName,
        _ids,
        withEntity ? _entities : null,
        null,
        _entityHandler,
        _entityProvider,
        _entityHandlerProvider,
        _entitiesFetcher,
        false);

    if (withEntity) cp._entitiesTime = _entitiesTime;

    return cp;
  }

  static List<E?>? _castListNullable<E>(List? l) {
    if (l == null) return null;

    if (l is List<E?>) {
      return l;
    }

    if (l is List<E>) {
      return l;
    }

    if (l.every((e) => e is E)) {
      return l.map((e) => e as E).toList();
    }

    if (l.every((e) => e == null || e is E)) {
      return l.map((e) => e as E?).toList();
    }

    throw StateError("Can't cast to `List<$E>`: $l");
  }

  /// The [entities] [Type].
  @override
  Type get type => super.type;

  /// The [entities] [Type] name.
  @override
  String get typeName => super.typeName;

  List<Object?>? _getEntitiesIDs(List<T?>? os) {
    if (os == null) return null;

    var entityHandler = _resolveEntityHandler();

    var ids =
        os.map((o) => o == null ? null : entityHandler?.getID(o)).toList();

    return ids;
  }

  void _checkValidEntities(List<Object?> entities) {
    var invalidIdx =
        entities.indexWhere((e) => e != null && _isInvalidEntity(e));

    if (invalidIdx >= 0) {
      var entity = entities[invalidIdx];
      var type = this.type;
      throw StateError(
          "Invalid entity instance (${entity.runtimeType}) at index `$invalidIdx` for `EntityReference<$type>` (`T` ($T), `type` ($_type) or `typeName` ($_typeName)).");
    }
  }

  /// Returns the length of entities of this [EntityReferenceList].
  /// See [entities] and [ids].
  int? get length {
    var ids = _ids;
    var entities = _entities;

    if (ids == null && entities == null) {
      return null;
    }

    if (ids != null && entities != null) {
      assert(ids.length == entities.length);
      return ids.length;
    }

    if (ids != null) {
      return ids.length;
    }

    if (entities != null) {
      return entities.length;
    }

    return null;
  }

  /// Returns `true` if [length] is `0` and NOT `null`.
  bool get isEmpty {
    var l = length;
    return l != null && l == 0;
  }

  /// Returns `true` if [length] is `>= 1` and NOT `null`.
  bool get isNotEmpty {
    var l = length;
    return l != null && l > 0;
  }

  /// Returns `true` if [length] is `0` OR `null`.
  bool get isEmptyOrNull {
    var l = length;
    return l == null || l == 0;
  }

  /// Returns `true` if [length] is `>= 1` OR `null`.
  bool get isNotEmptyOrNull {
    var l = length;
    return l == null || l > 0;
  }

  /// The entities IDs.
  List<Object?>? get ids => _resolveIDs();

  /// Non-nullable versions of [ids].
  List<Object> get idsNotNull =>
      ids?.where((e) => e != null).whereType<Object>().toList() ?? <Object>[];

  List<Object?>? _resolveIDs() {
    var ids = _ids;
    if (ids != null) return ids;

    var entities = _entities;
    if (entities == null) return null;

    _ids = ids = _getEntitiesIDs(entities);

    return ids;
  }

  List<T?>? _entities;

  /// The already loaded entities.
  List<T?>? get entities => _resolveEntities();

  /// Non-nullable version of [entities].
  List<T> get entitiesNotNull =>
      entities?.where((e) => e != null).whereType<T>().toList() ?? <T>[];

  List<T?>? _resolveEntities() {
    var entities = _entities;

    if (entities == null) {
      var ids = this.ids;
      var entityProvider = this.entityProvider;

      if (ids != null && entityProvider != null) {
        entities = ids.map((id) {
          return entityProvider.getEntityByID<T>(id, type: type, sync: true)
              as T?;
        }).toList();

        if (entities.every((e) => e == null)) {
          entities = null;
        }

        _entities = entities;
      }
    }

    if (entities == null) return null;

    _entitiesTime ??= DateTime.now();

    if (_ids == null) {
      _resolveIDs();
    }

    _checkValidEntities(entities);

    return entities;
  }

  /// Returns [entities] OR [ids].
  /// See [isEntitiesSet] and [isIDsSet].
  List<Object?>? get entitiesOrIDs {
    if (isEntitiesSet) {
      var entities = this.entities!;

      if (isIDsSet) {
        var ids = this.ids!;

        if (entities.any((e) => e == null)) {
          var list = entities.mergeWithOther(ids);
          return list;
        } else {
          return entities;
        }
      } else {
        return entities;
      }
    } else if (isIDsSet) {
      return ids;
    } else {
      return null;
    }
  }

  DateTime? _entitiesTime;

  /// The [DateTime] of when the [entities] was [set].
  DateTime? get entitiesTime => _entitiesTime;

  /// Returns [entities] as a JSON [List] of entities [Map].
  List<Map<String, dynamic>?>? entitiesToJson() {
    var entities = this.entities;
    if (entities == null) return null;

    var entityHandler = this.entityHandler;

    if (entityHandler != null) {
      var jsonList = entities
          .map((e) => e == null
              ? null
              : (entityHandler.toJson(e) as Map<String, dynamic>?))
          .toList();
      return jsonList;
    }

    var jsonList = entities.map((e) => _entityToJsonDefault(e)).toList();

    return jsonList;
  }

  /// Encodes [entities] or [ids] as JSON. If [isNull] returns `null`.
  Object? entitiesOrIDsToJson() {
    if (isNull) return null;

    if (isEntitiesSet) {
      return entitiesToJson();
    } else if (isIDsSet) {
      return ids!;
    } else {
      return null;
    }
  }

  /// Encodes this [EntityReferenceList] instance to JSON.
  ///
  /// Fields:
  /// - `EntityReferenceList`: the reference type.
  /// - `ids`: the entities IDs (if [isIDsSet]).
  /// - `entities`: the entities as JSON (if [isEntitiesSet]). See [entitiesToJson].
  @override
  Map<String, dynamic>? toJson() {
    if (isNull) {
      return null;
    }

    if (isEntitiesSet) {
      var entities = this.entities!;
      var ids = this.ids;

      var hasAnyEntity = entities.any((e) => e != null);
      var hasAnyID = ids != null && ids.any((id) => id != null);

      return <String, dynamic>{
        'EntityReferenceList': typeName,
        if (hasAnyID) 'ids': ids,
        if (hasAnyEntity) 'entities': entitiesToJson(),
      };
    } else if (isIDsSet) {
      var ids = this.ids!;
      var hasAnyID = ids.any((id) => id != null);

      return <String, dynamic>{
        'EntityReferenceList': typeName,
        if (hasAnyID) 'ids': ids,
      };
    } else {
      return <String, dynamic>{
        'EntityReferenceList': typeName,
      };
    }
  }

  /// Sets the [entities] to [os] and returns the current [entities].
  List<T?>? set(List<T?>? os) {
    if (os != null && os.every((e) => e == null)) {
      os = null;
    }

    if (_listIdenticalEquality.equals(os, _entities)) return os;

    if (os == null) {
      _ids = null;
      _entities = null;
      _entitiesTime = null;
    } else {
      var ids = _getEntitiesIDs(os);
      _ids = ids;
      _entities = os;
      _entitiesTime = DateTime.now();
    }

    return _entities;
  }

  static final ListEquality _idsEquality = ListEquality();

  static final ListEquality _entitiesEquality = ListEquality();

  static final ListEquality _listIdenticalEquality =
      ListEquality(IdentityEquality());

  /// Sets the [entities] [ids] and returns the current [ids].
  /// If the IDs is changing the previous loaded [entities] instance are disposed.
  Object? setIDs(List<Object?>? ids) {
    if (ids == null) {
      _ids = null;
      _entities = null;
      _entitiesTime = null;
    } else if (ids != _ids && !_idsEquality.equals(ids, _ids)) {
      var prevIDs = _getEntitiesIDs(_entities);

      _ids = ids;

      if (!_idsEquality.equals(ids, prevIDs)) {
        _entities = null;
        _entitiesTime = null;
      }
    }

    return _ids;
  }

  /// Updated [ids] from [entities] isntances IDs.
  bool updateIDsFromEntities() {
    var entities = _entities;
    if (entities == null) return false;

    List<Object?>? ids2;

    var ids = _ids;
    if (ids != null) {
      var list = entities.mergeWithOther(ids);

      ids2 = ids2 = list.map((e) => e is T ? _getEntityID(e) : e).toList();
    } else {
      ids2 = _getEntitiesIDs(entities);
    }

    _ids = ids2;
    return true;
  }

  /// Returns `true` if the [entities] instances are loaded.
  bool get isEntitiesSet => _entities != null;

  /// Returns `true` if [ids] is set.
  bool get isIDsSet {
    _resolveIDs();
    return _ids != null;
  }

  /// Returns `true` if this reference is `null` (no [ids] or [entities] set).
  @override
  bool get isNull => _entities == null && _ids == null;

  /// Returns the current [entity] or fetches it.
  @override
  FutureOr<List<T?>?> get() {
    var l = entities;
    if (l != null) return l;

    return _fetchAndSet();
  }

  /// Same as [get] but won't return `null`.
  @override
  FutureOr<List<T?>> getNotNull() => get().resolveMapped((l) {
        if (l == null || l.every((e) => e == null)) {
          throw StateError(
              "Null entities. Can't `get` entities `$type` with IDs ${ids?.map((e) => '<$e>').toList() ?? '`null`'}> entityProvider: $entityProvider ; entitiesFetcher: $_entitiesFetcher");
        }
        return l;
      });

  /// Returns `true` if the [entities] is loaded;
  @override
  bool get isLoaded => isEntitiesSet;

  /// Returns the current internal value ([entities] OR [ids]).
  @override
  Object? get currentValue => isEntitiesSet ? entities : ids;

  /// Disposes the current loaded [entity] instance and returns it.
  /// Id [id] is defined it will keep it.
  List<T?>? disposeEntities() {
    var prev = entities;
    _entities = null;
    _entitiesTime = null;
    return prev;
  }

  /// Refreshes the [entities] fetching them.
  @override
  FutureOr<List<T?>?> refresh() => _fetchAndSet();

  FutureOr<List<T?>?> _fetchAndSet() => fetchImpl().resolveMapped(set);

  /// Fetches the [entity], but won't [set] it. Do not call this directly.
  FutureOr<List<T?>?> fetchImpl() {
    var entityProvider = this.entityProvider;
    var entitiesFetcher = _entitiesFetcher;
    var ids = this.ids;

    if (ids == null) return entities;

    if (entitiesFetcher != null) {
      return entitiesFetcher(ids, type);
    }

    if (entityProvider == null) return entities;

    var l = ids
        .map((id) => entityProvider.getEntityByID<T>(id, type: type))
        .toList()
        .resolveAll();

    return l;
  }

  FutureOr<T?> _fetchEntity(Object? id) {
    var entityProvider = this.entityProvider;
    var entitiesFetcher = _entitiesFetcher;

    if (id == null) return null;

    if (entitiesFetcher != null) {
      return entitiesFetcher([ids], type).resolveMapped((l) => l?.firstOrNull);
    }

    if (entityProvider == null) return null;

    var o = entityProvider.getEntityByID<T>(id, type: type);
    return o;
  }

  FutureOr<T?> getAt(int index) {
    if (isEmptyOrNull) return null;

    var entities = _entities;
    if (entities != null) {
      var o = index < entities.length ? entities[index] : null;
      if (o != null) return o;
    }

    var ids = _ids;
    if (ids != null) {
      var id = index < ids.length ? ids[index] : null;
      if (id != null) {
        return _fetchEntity(id).resolveMapped((o) {
          var entities = _entities;
          entities?[index] ??= o;
          return o;
        });
      }
    }

    return null;
  }

  void addAll(Iterable<T> os) {
    for (var o in os) {
      add(o);
    }
  }

  void add(T o) {
    if (isNull) {
      set([o]);
    }

    var ids = _ids;

    if (isEntitiesSet) {
      _entities!.add(o);
      if (ids != null) {
        var id = _getEntityID(o);
        ids.add(id);
      }
    } else if (isIDsSet) {
      var id = _getEntityID(o);
      ids!.add(id);

      var entities = _entities = List<T?>.filled(ids.length, null);
      entities[ids.lastIndex] = o;
    }
  }

  bool remove(T? o) {
    if (o == null) return false;

    if (isNull) {
      return false;
    }

    var ids = _ids;

    if (isEntitiesSet) {
      var entities = _entities!;
      var idx = entities.indexOf(o);

      if (idx >= 0) {
        entities.removeAt(idx);

        if (ids != null && idx < ids.length) {
          ids.removeAt(idx);
        }

        return true;
      }
    } else if (isIDsSet) {
      var id = _getEntityID(o);

      if (id != null) {
        return ids!.remove(id);
      }
    }

    return false;
  }

  bool removeByID(Object? id) {
    if (id == null) return false;

    if (isNull) {
      return false;
    }

    var ids = _ids;

    if (isEntitiesSet) {
      var entities = _entities!;

      if (ids != null) {
        var idx = ids.indexOf(id);

        if (idx >= 0) {
          ids.removeAt(idx);
          entities.removeAt(idx);
          return true;
        }
      }

      var idx = entities.indexWhere((e) => _getEntityID(e) == id);

      if (idx >= 0) {
        entities.removeAt(idx);
        return true;
      }
    } else if (isIDsSet) {
      return ids!.remove(id);
    }

    return false;
  }

  bool? equalsEntitiesIDs(Object? otherEntities) {
    if (otherEntities == null) {
      return isNull;
    }

    if (identical(this, otherEntities)) {
      return true;
    }

    if (otherEntities is EntityReference) {
      if (type != otherEntities.type) return false;

      if (otherEntities.isNull) {
        return isNull;
      }

      if (otherEntities.isEntitySet &&
          isEntitiesSet &&
          _listIdenticalEquality.equals(entities, [otherEntities.entity])) {
        return true;
      }

      if (otherEntities.isIdSet) {
        if (isIDsSet) {
          return _idsEquality.equals(ids, [otherEntities.id]);
        } else {
          return false;
        }
      } else {
        if (isIDsSet) {
          return false;
        } else {
          return null;
        }
      }
    } else if (otherEntities is EntityReferenceList) {
      if (type != otherEntities.type) return false;

      if (otherEntities.isNull) {
        return isNull;
      }

      if (otherEntities.isEntitiesSet &&
          isEntitiesSet &&
          _listIdenticalEquality.equals(entities, otherEntities.entities)) {
        return true;
      }

      if (otherEntities.isIDsSet) {
        if (isIDsSet) {
          return _idsEquality.equals(ids, otherEntities.ids);
        } else {
          return false;
        }
      } else {
        if (isIDsSet) {
          return false;
        } else {
          return null;
        }
      }
    } else if (otherEntities is T) {
      if (isEntitiesSet &&
          _listIdenticalEquality.equals(entities, [otherEntities])) return true;

      var entityHandler = this.entityHandler;

      if (entityHandler != null) {
        var otherIDs = [entityHandler.getID(otherEntities as T)];
        return _idsEquality.equals(ids, otherIDs);
      }

      return null;
    } else if (otherEntities is List<T?>) {
      if (isEntitiesSet &&
          _listIdenticalEquality.equals(entities, otherEntities)) return true;

      var entityHandler = this.entityHandler;

      if (entityHandler != null) {
        var otherIDs =
            otherEntities.map((e) => entityHandler.getID(e as T)).toList();
        return _idsEquality.equals(ids, otherIDs);
      }

      return null;
    } else if (otherEntities is List &&
        otherEntities.every((Object? e) => e == null || e.isEntityIDType)) {
      return _idsEquality.equals(ids, otherEntities);
    } else {
      return null;
    }
  }

  @override
  String toString({bool withT = true}) {
    var typeStr = _type?.toString() ?? _typeName ?? '?';
    var prefix = 'EntityReferenceList<$typeStr>';
    if (withT) prefix = '<T:$T> $prefix';

    if (isNull) {
      return '$prefix{null}';
    }

    var ids = _ids;
    var entities = _entities;

    if (ids != null) {
      if (entities != null) {
        return '$prefix{ids: $ids}${entities.map((e) => '<$e>').toList(growable: false)}';
      } else {
        return '$prefix{ids: $ids}';
      }
    } else {
      return '$prefix${entities?.map((e) => '<$e>').toList(growable: false)}';
    }
  }

  /// Returns `this` as an [EntityReference] instance.
  /// If this instance [length] is `> 1` it will thrown an [StateError].
  EntityReference<T> toEntityReference() {
    var ids = this.ids;
    var entities = this.entities;

    var length = this.length;

    if (length != null) {
      if (length > 1) {
        throw StateError(
            "Can't convert a list of length ($length) `> 1` to an `EntityReference<$T>.`");
      } else if (length == 0) {
        ids = null;
        entities == null;
      }
    }

    var id = ids?[0];
    var entity = entities?[0];
    EntityFetcher<T>? fetcher;

    final entitiesFetcher = _entitiesFetcher;
    if (entitiesFetcher != null) {
      fetcher = (id, type) =>
          entitiesFetcher([id], type).resolveMapped((l) => l?.firstOrNull);
    }

    return EntityReference<T>._(type, null, id, entity, null, entityHandler,
        entityProvider, _entityHandlerProvider, fetcher, false);
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;

    if (other is! EntityReferenceList || runtimeType != other.runtimeType) {
      return false;
    }

    if (isNull) {
      return other.isNull;
    }

    if (isEntitiesSet && other.isEntitiesSet) {
      if (isIDsSet && other.isIDsSet) {
        return isEqualsListDeep(ids, other.ids) &&
            isEqualsListDeep(entities, other.entities);
      } else {
        return isEqualsListDeep(entities, other.entities);
      }
    }

    if (isIDsSet && other.isIDsSet) {
      return isEqualsListDeep(ids, other.ids);
    }

    if (isEntitiesSet && other.isIDsSet) {
      return isEqualsListDeep(_getEntitiesIDs(entities), other.ids);
    }

    return false;
  }

  @override
  int get hashCode {
    if (isNull) return 0;

    if (isIDsSet) return _idsEquality.hash(_ids);

    if (isEntitiesSet) return _entitiesEquality.hash(_entities);

    return -1;
  }
}

extension _ListExtension<T> on List<T> {
  List<T> mergeWith(List<T> other) => List<T>.generate(length, (i) {
        T a = this[i];
        if (a != null) return a;

        T b = other[i];
        return b;
      });

  List<Object?> mergeWithOther<E>(List<E> other) {
    if (other is List<T>) {
      return mergeWith(other as List<T>);
    }

    return List.generate(length, (i) {
      Object? a = this[i];
      if (a != null) return a;

      Object? b = other[i];
      return b;
    });
  }
}
