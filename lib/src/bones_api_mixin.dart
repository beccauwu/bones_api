import 'dart:async';
import 'dart:collection';

import 'package:async_extension/async_extension.dart';
import 'package:collection/collection.dart';

mixin Initializable {
  bool _initialized = false;

  void ensureInitialized() {
    if (_initialized) {
      return;
    }

    _initialized = true;

    initialize();
  }

  void initialize() {}
}

mixin Closable {
  bool _closed = false;

  bool get isClosed => _closed;

  void close() {
    if (_closed) return;
    _closed = true;
  }

  void checkNotClosed() {
    if (isClosed) {
      throw StateError("Closed: $this");
    }
  }
}

class PoolTimeoutError extends Error {
  final String message;

  PoolTimeoutError(this.message);

  @override
  String toString() {
    return 'PoolTimeoutError: $message';
  }
}

mixin Pool<O> {
  final ListQueue<O> _pool = ListQueue(8);

  Iterable<O> get poolElements => List<O>.unmodifiable(_pool);

  bool removeFromPool(O o) {
    return _pool.remove(o);
  }

  int removeElementsFromPool(int amount) {
    var rm = 0;

    while (amount > 0 && _pool.isNotEmpty) {
      var o = _pool.removeFirst();
      closePoolElement(o);
      --amount;
      rm++;
    }

    return rm;
  }

  FutureOr<List<O>> validPoolElements() =>
      filterPoolElements(isPoolElementValid);

  FutureOr<List<O>> invalidPoolElements() => filterPoolElements(
      (o) => isPoolElementValid(o).resolveMapped((valid) => !valid));

  FutureOr<List<O>> filterPoolElements(FutureOr<bool> Function(O o) filter) {
    var elements = _pool.map((o) {
      return filter(o).resolveMapped((valid) => valid ? o : null);
    }).resolveAllNotNull();

    return elements;
  }

  FutureOr<bool> removeInvalidElementsFromPool() {
    FutureOr<List<O>> ret = invalidPoolElements();

    return ret.resolveMapped((l) {
      for (var o in l) {
        removeFromPool(o);
      }
      return true;
    });
  }

  FutureOr<bool> isPoolElementValid(O o);

  FutureOr<bool> clearPool() {
    _pool.clear();
    return true;
  }

  int get poolSize => _pool.length;

  bool get isPoolEmpty => poolSize == 0;

  bool get isPoolNotEmpty => !isPoolEmpty;

  int get poolCreatedElementsCount => _createElementCount;

  int get poolDisposedElementsCount =>
      _closedElementsCount + _unrecycledElementCount;

  int get poolAliveElementsSize =>
      poolCreatedElementsCount - poolDisposedElementsCount;

  int _createElementCount = 0;

  FutureOr<O?> createPoolElement() {
    ++_createElementCount;
    return null;
  }

  Completer<bool>? _waitingPoolElement;

  FutureOr<O> catchFromPool({Duration? timeout}) {
    if (_pool.isEmpty) {
      return _catchFromEmptyPool(timeout);
    } else {
      return _catchFromPopulatedPool();
    }
  }

  int get poolSizeDesiredLimit;

  static final Duration _defaultPoolYieldTimeout = Duration(milliseconds: 100);

  Duration get poolYieldTimeout => _defaultPoolYieldTimeout;

  final QueueList<Completer<bool>> _yields = QueueList(8);

  FutureOr<O> _catchFromEmptyPool(Duration? timeout) {
    var alive = poolAliveElementsSize;

    FutureOr<O?> created;

    if (alive > poolSizeDesiredLimit) {
      var yield = Completer<bool>();
      _yields.addLast(yield);

      created = yield.future.timeout(poolYieldTimeout, onTimeout: () {
        _yields.remove(yield);
        return false;
      }).then((ok) {
        if (_pool.isNotEmpty) {
          return _catchFromPopulatedPool();
        } else {
          return createPoolElement();
        }
      });
    } else {
      created = createPoolElement();
    }

    return created.resolveMapped((o) {
      if (o != null) return o;

      var waitingPoolElement = _waitingPoolElement ??= Completer<bool>();

      var ret = waitingPoolElement.future.then((_) {
        if (_pool.isNotEmpty) {
          return _catchFromPopulatedPool();
        } else {
          return _waitElementInPool();
        }
      });

      if (timeout != null) {
        return ret.timeout(timeout, onTimeout: () {
          throw PoolTimeoutError("Catch from Pool timeout[$timeout]: $this");
        });
      } else {
        return ret;
      }
    });
  }

  FutureOr<O> _catchFromPopulatedPool() {
    var o = _pool.removeLast();

    var waitingPoolElement = _waitingPoolElement;
    if (waitingPoolElement != null) {
      if (!waitingPoolElement.isCompleted) {
        waitingPoolElement.complete(false);
      }
      _waitingPoolElement = null;
    }

    return preparePoolElement(o);
  }

  FutureOr<O> _waitElementInPool() async {
    while (true) {
      var waitingPoolElement = _waitingPoolElement ??= Completer<bool>();

      await waitingPoolElement.future;

      if (_pool.isNotEmpty) {
        return _catchFromPopulatedPool();
      }
    }
  }

  FutureOr<O> preparePoolElement(O o) => o;

  DateTime _lastCheckPoolTime = DateTime.now();

  int get lastCheckPoolElapsedTimeMs =>
      DateTime.now().millisecondsSinceEpoch -
      _lastCheckPoolTime.millisecondsSinceEpoch;

  FutureOr<bool> callCheckPool() {
    return checkPool().resolveMapped((ok) {
      _lastCheckPoolTime = DateTime.now();
      return ok;
    });
  }

  FutureOr<bool> checkPool() => removeInvalidElementsFromPool();

  FutureOr<bool> checkPoolSize(
      int minSize, int maxSize, int checkInvalidsIntervalMs) {
    var poolSize = this.poolSize;

    if (poolSize <= minSize) return true;

    if (poolSize > maxSize) {
      return removeInvalidElementsFromPool().resolveMapped((_) {
        var excess = this.poolSize - maxSize;
        removeElementsFromPool(excess);
        return true;
      });
    }

    if (lastCheckPoolElapsedTimeMs > checkInvalidsIntervalMs) {
      return removeInvalidElementsFromPool();
    } else {
      return true;
    }
  }

  FutureOr<O?> recyclePoolElement(O o) {
    var retValid = isPoolElementValid(o);
    return retValid.resolveMapped((valid) => valid ? o : null);
  }

  int _unrecycledElementCount = 0;

  FutureOr<bool> releaseIntoPool(O o) {
    var ret = recyclePoolElement(o);

    return ret.resolveMapped((recycled) {
      if (recycled != null) {
        checkPool();
        _pool.addLast(recycled);

        if (_yields.isNotEmpty) {
          var yield = _yields.removeFirst();
          if (!yield.isCompleted) {
            yield.complete(true);
          }
        }

        var waitingPoolElement = _waitingPoolElement;
        if (waitingPoolElement != null && !waitingPoolElement.isCompleted) {
          waitingPoolElement.complete(true);
        }

        return true;
      } else {
        ++_unrecycledElementCount;
        return false;
      }
    });
  }

  int _closedElementsCount = 0;

  FutureOr<bool> closePoolElement(O o) {
    ++_closedElementsCount;
    return true;
  }

  FutureOr<bool> disposePoolElement(O o) {
    _pool.remove(o);
    return closePoolElement(o);
  }

  FutureOr<R> executeWithPool<R>(FutureOr<R> Function(O o) f,
      {Duration? timeout, bool Function(O o)? validator}) {
    return catchFromPool(timeout: timeout).then((o) {
      try {
        var ret = f(o);
        return ret.resolveMapped((val) {
          if (validator == null || validator(o)) {
            releaseIntoPool(o);
          } else {
            disposePoolElement(o);
          }
          return val;
        });
      } catch (_) {
        disposePoolElement(o);
        rethrow;
      }
    });
  }
}

mixin FieldsFromMap {
  Map<String, int> buildFieldsNamesIndexes(List<String> fieldsNames) {
    return Map<String, int>.fromEntries(
        List.generate(fieldsNames.length, (i) => MapEntry(fieldsNames[i], i)));
  }

  List<String> buildFieldsNamesLC(List<String> fieldsNames) =>
      List<String>.unmodifiable(fieldsNames.map((f) => fieldToLCKey(f)));

  List<String> buildFieldsNamesSimple(List<String> fieldsNames) {
    return List<String>.unmodifiable(
        fieldsNames.map((f) => fieldToSimpleKey(f)));
  }

  /// Returns a [Map] with the fields values populated from the provided [map].
  ///
  /// The field name resolution is case insensitive. See [getFieldValueFromMap].
  Map<String, Object?> getFieldsValuesFromMap(
    List<String> fieldsNames,
    Map<String, Object?> map, {
    Map<String, int>? fieldsNamesIndexes,
    List<String>? fieldsNamesLC,
    List<String>? fieldsNamesSimple,
    bool includeAbsentFields = false,
  }) {
    var mapLC = <String, Object?>{};
    var mapSimple = <String, Object?>{};

    var entries = fieldsNames.map((f) {
      String? fLC, fSimple;
      if (fieldsNamesIndexes != null) {
        var idx = fieldsNamesIndexes[f]!;
        fLC = fieldsNamesLC?[idx];
        fSimple = fieldsNamesSimple?[idx];
      }

      var entry =
          _getFieldValueFromMapImpl(f, fLC, fSimple, map, mapLC, mapSimple);

      if (entry == null && includeAbsentFields) {
        entry = MapEntry(f, null);
      }

      return entry;
    }).whereNotNull();

    var fields = Map<String, Object?>.fromEntries(entries);

    return fields;
  }

  /// Returns a [field] value from [map].
  /// - [field] is case insensitive.
  Object? getFieldValueFromMap(String field, Map<String, Object?> map) {
    var entry = _getFieldValueFromMapImpl(field, null, null, map, null, null);
    return entry?.value;
  }

  MapEntry<String, Object?>? _getFieldValueFromMapImpl(
      String field,
      String? fieldLC,
      String? fieldSimple,
      Map<String, Object?> map,
      Map<String, Object?>? mapLC,
      Map<String, Object?>? mapSimple) {
    if (map.isEmpty) return null;

    var val = map[field];
    if (val != null) return MapEntry(field, val);

    fieldLC ??= fieldToLCKey(field);

    val = map[fieldLC];
    if (val != null) return MapEntry(field, val);

    fieldSimple ??= fieldToSimpleKey(field);

    val = map[fieldSimple];
    if (val != null) return MapEntry(field, val);

    if (mapLC != null) {
      if (mapLC.isEmpty) {
        for (var e in map.entries) {
          var kLC = fieldToLCKey(e.key);
          mapLC[kLC] = e.value;
        }
      }

      val = mapLC[fieldLC];
      if (val != null) {
        return MapEntry(field, val);
      }
    } else {
      for (var k in map.keys) {
        var kLC = fieldToLCKey(k);
        if (kLC == fieldLC) {
          val = map[k];
          return MapEntry(field, val);
        }
      }
    }

    if (mapSimple != null) {
      if (mapSimple.isEmpty) {
        for (var e in map.entries) {
          var kSimple = fieldToSimpleKey(e.key);
          mapSimple[kSimple] = e.value;
        }
      }

      val = mapSimple[fieldSimple];
      if (val != null) {
        return MapEntry(field, val);
      }
    } else {
      for (var k in map.keys) {
        var kSimple = fieldToSimpleKey(k);
        if (kSimple == fieldSimple) {
          val = map[k];
          return MapEntry(field, val);
        }
      }
    }

    return null;
  }

  String fieldToLCKey(String key) => key.toLowerCase();

  static final RegExp _regexpLettersAndDigits = RegExp(r'[^a-zA-Z0-9]');

  String fieldToSimpleKey(String key) =>
      key.toLowerCase().replaceAll(_regexpLettersAndDigits, '');
}
