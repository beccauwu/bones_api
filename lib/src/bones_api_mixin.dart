import 'dart:async';
import 'dart:collection';

import 'package:async_extension/async_extension.dart';

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

  bool removeFromPool(O o) => _pool.remove(o);

  int removeElementsFromPool(int amount) {
    var rm = 0;

    while (amount > 0 && _pool.isNotEmpty) {
      _pool.removeFirst();
      --amount;
      rm++;
    }

    return rm;
  }

  FutureOr<List<O>> validPoolElements() =>
      filterPoolElements(isPoolElementValid);

  FutureOr<List<O>> invalidPoolElements() => filterPoolElements(
      (o) => isPoolElementValid(o).resolveMapped((valid) => !valid));

  FutureOr<List<O>> filterPoolElements(
      FutureOr<bool> Function(O o) filter) async {
    var elements = <O>[];

    for (var o in _pool) {
      await filter(o).resolveMapped((valid) {
        if (valid) {
          elements.add(o);
        }
      });
    }

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

  FutureOr<O?> createPoolElement();

  Completer<bool>? _waitingPoolElement;

  FutureOr<O> catchFromPool({Duration? timeout}) {
    if (_pool.isEmpty) {
      return _catchFromEmptyPool(timeout);
    } else {
      return _catchFromPopulatedPool();
    }
  }

  FutureOr<O> _catchFromEmptyPool(Duration? timeout) {
    return createPoolElement().resolveMapped((o) {
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
    _waitingPoolElement = null;
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

  FutureOr<bool> checkPool() => true;

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

  FutureOr<O> recyclePoolElement(O o) => o;

  FutureOr<bool> releaseIntoPool(O o) {
    var ret = recyclePoolElement(o);

    return ret.resolveMapped((recycled) {
      if (recycled != null) {
        checkPool();
        _pool.addLast(recycled);

        var waitingPoolElement = _waitingPoolElement;
        if (waitingPoolElement != null && !waitingPoolElement.isCompleted) {
          waitingPoolElement.complete(true);
        }

        return true;
      } else {
        return false;
      }
    });
  }
}
