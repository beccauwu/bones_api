import 'dart:async';

import 'bones_api_entity.dart';

/// A entity repository API.
abstract class APIRepository<O> {
  /// Resolves a [EntityRepository].
  static EntityRepository<O>? resolveEntityRepository<O>(
      {EntityRepository<O>? entityRepository,
      EntityRepositoryProvider? provider,
      Type? type}) {
    return entityRepository ??
        provider?.getEntityRepository<O>(type: type) ??
        EntityRepositoryProvider.globalProvider
            .getEntityRepository<O>(type: type);
  }

  final EntityRepository<O> entityRepository;

  APIRepository(
      {EntityRepository<O>? entityRepository,
      EntityRepositoryProvider? provider,
      Type? type})
      : entityRepository = resolveEntityRepository(
            entityRepository: entityRepository,
            provider: provider,
            type: type)! {
    this.entityRepository.ensureInitialized();
  }

  void configure();

  bool _configured = false;

  void ensureConfigured() {
    if (_configured) return;
    _configured = true;
    configure();
  }

  FutureOr<O?> selectByID(dynamic id) => entityRepository.selectByID(id);

  FutureOr<int> length() => entityRepository.length();

  FutureOr<Iterable<O>> selectByQuery(String query,
          {Object? parameters,
          List? positionalParameters,
          Map<String, Object?>? namedParameters}) =>
      entityRepository.selectByQuery(query,
          parameters: parameters,
          positionalParameters: positionalParameters,
          namedParameters: namedParameters);
}
