import 'package:ngdart/src/utilities.dart';

/// A function that can be used to return a unique key for [item] at [index].
///
/// By default, [item] itself is used as the key to track to instantiate a new
/// template per item in `*ngFor`. If the data ever changes, AngularDart will
/// consider any object with a different identity (`identical`) to be different
/// - and destroy and re-create a new node.
///
/// To optimize performance when you have a way to determine uniqueness other
/// than identity, such as an `id` field on an object returned from the server,
/// you may specify a [TrackByFn]`:
/// ```
/// class MyComp {
///   Object trackByEmployeeId(int index, dynamic item) {
///     return item is Employee ? item.id : item;
///   }
/// }
///
/// class Employee {
///   int id;
/// }
/// ```
///
/// **NOTE**: It is not safe to simply _assume_ that the second parameter is
/// of your custom type (neither [TrackByFn] nor `NgFor` allow that) at this
/// time: https://github.com/angulardart/angular/issues/1020. You must use an `as`
/// cast or `is` check. See the example above.
typedef TrackByFn = Object? Function(int index, dynamic item);

Object? _trackByIdentity(int index, dynamic item) => item;

class DefaultIterableDiffer {
  final TrackByFn _trackByFn;
  int? _length;
  Iterable<Object?>? _collection;
  // Keeps track of the used records at any point in time (during & across
  // `_check()` calls)
  _DuplicateMap? _linkedRecords;
  // Keeps track of the removed records at any point in time during `_check()`
  // calls.
  _DuplicateMap? _unlinkedRecords;
  CollectionChangeRecord? _previousItHead;
  CollectionChangeRecord? _itHead;
  CollectionChangeRecord? _itTail;
  CollectionChangeRecord? _additionsHead;
  CollectionChangeRecord? _additionsTail;
  CollectionChangeRecord? _movesHead;
  CollectionChangeRecord? _movesTail;
  CollectionChangeRecord? _removalsHead;
  CollectionChangeRecord? _removalsTail;
  // Keeps track of records where custom track by is the same, but item identity
  // has changed
  CollectionChangeRecord? _identityChangesHead;
  CollectionChangeRecord? _identityChangesTail;

  DefaultIterableDiffer([TrackByFn? trackByFn])
      : _trackByFn = trackByFn ?? _trackByIdentity;

  DefaultIterableDiffer clone(TrackByFn? trackByFn) {
    var differ = DefaultIterableDiffer(trackByFn);
    return differ
      .._length = _length
      .._collection = _collection
      .._linkedRecords = _linkedRecords
      .._unlinkedRecords = _unlinkedRecords
      .._previousItHead = _previousItHead
      .._itHead = _itHead
      .._itTail = _itTail
      .._additionsHead = _additionsHead
      .._additionsTail = _additionsTail
      .._movesHead = _movesHead
      .._movesTail = _movesTail
      .._removalsHead = _removalsHead
      .._removalsTail = _removalsTail
      .._identityChangesHead = _identityChangesHead
      .._identityChangesTail = _identityChangesTail;
  }

  Iterable<Object?>? get collection => _collection;

  int? get length => _length;

  void forEachOperation(void Function(CollectionChangeRecord, int?, int?) fn) {
    var nextIt = _itHead;
    var nextRemove = _removalsHead;
    var addRemoveOffset = 0;
    int sizeDeficit;
    List<int?>? moveOffsets;

    while (nextIt != null || nextRemove != null) {
      // Figure out which is the next record to process
      // Order: remove, add, move
      dynamic record = nextRemove == null ||
              nextIt != null &&
                  nextIt.currentIndex! <
                      _getPreviousIndex(
                          nextRemove, addRemoveOffset, moveOffsets)!
          ? nextIt
          : nextRemove;

      var adjPreviousIndex =
          _getPreviousIndex(unsafeCast(record), addRemoveOffset, moveOffsets);

      // TODO(b/171306883): Type "record" and remove the unsafeCast(s).
      var currentIndex = unsafeCast<int?>(record.currentIndex);

      // consume the item, adjust the addRemoveOffset and update
      // moveDistance if necessary
      if (identical(record, nextRemove)) {
        addRemoveOffset--;
        nextRemove = nextRemove!._nextRemoved;
      } else {
        nextIt = nextIt!._next;

        if (record.previousIndex == null) {
          addRemoveOffset++;
        } else {
          // INVARIANT:  currentIndex < previousIndex
          moveOffsets ??= <int?>[];

          var localMovePreviousIndex = adjPreviousIndex! - addRemoveOffset;
          var localCurrentIndex = currentIndex! - addRemoveOffset;

          if (localMovePreviousIndex != localCurrentIndex) {
            for (var i = 0; i < localMovePreviousIndex; i++) {
              int offset;

              if (i < moveOffsets.length) {
                offset = moveOffsets[i]!;
              } else {
                if (moveOffsets.length > i) {
                  offset = moveOffsets[i] = 0;
                } else {
                  sizeDeficit = i - moveOffsets.length + 1;
                  for (var j = 0; j < sizeDeficit; j++) {
                    moveOffsets.add(null);
                  }
                  offset = moveOffsets[i] = 0;
                }
              }

              var index = offset + i;

              if (localCurrentIndex <= index &&
                  index < localMovePreviousIndex) {
                moveOffsets[i] = offset + 1;
              }
            }

            var previousIndex = unsafeCast<int>(record.previousIndex);
            sizeDeficit = previousIndex - moveOffsets.length + 1;
            for (var j = 0; j < sizeDeficit; j++) {
              moveOffsets.add(null);
            }
            moveOffsets[previousIndex] =
                localCurrentIndex - localMovePreviousIndex;
          }
        }
      }

      if (adjPreviousIndex != currentIndex) {
        fn(unsafeCast(record), adjPreviousIndex, currentIndex);
      }
    }
  }

  void forEachAddedItem(void Function(CollectionChangeRecord) fn) {
    for (var record = _additionsHead;
        record != null;
        record = record._nextAdded) {
      fn(record);
    }
  }

  void forEachRemovedItem(void Function(CollectionChangeRecord) fn) {
    for (var record = _removalsHead;
        record != null;
        record = record._nextRemoved) {
      fn(record);
    }
  }

  void forEachIdentityChange(void Function(CollectionChangeRecord) fn) {
    for (var record = _identityChangesHead;
        record != null;
        record = record._nextIdentityChange) {
      fn(record);
    }
  }

  DefaultIterableDiffer? diff(Iterable<Object?>? collection) {
    return check(collection ?? const []) ? this : null;
  }

  void onDestroy() {}
  // todo(vicb): optim for UnmodifiableListView (frozen arrays)
  bool check(Iterable<Object?> collection) {
    _reset();
    var record = _itHead;
    var mayBeDirty = false;
    int index;
    if (collection is List<Object?>) {
      var list = collection;
      var length = collection.length;
      _length = length;
      for (index = 0; index < length; index++) {
        var item = list[index];
        var itemTrackBy = _trackByFn(index, item);
        if (record == null || !identical(record.trackById, itemTrackBy)) {
          record = _mismatch(record, item, itemTrackBy, index);
          mayBeDirty = true;
        } else {
          if (mayBeDirty) {
            // TODO(misko): can we limit this to duplicates only?
            record = _verifyReinsertion(record, item, itemTrackBy, index);
          }
          if (!identical(record.item, item)) {
            _addIdentityChange(record, item);
          }
        }
        record = record._next;
      }
    } else {
      index = 0;
      collection.forEach((item) {
        var itemTrackBy = _trackByFn(index, item);
        if (record == null || !identical(record!.trackById, itemTrackBy)) {
          record = _mismatch(record, item, itemTrackBy, index);
          mayBeDirty = true;
        } else {
          if (mayBeDirty) {
            // TODO(misko): can we limit this to duplicates only?
            record = _verifyReinsertion(record!, item, itemTrackBy, index);
          }
          if (!identical(record!.item, item)) {
            _addIdentityChange(record!, item);
          }
        }
        record = record!._next;
        index++;
      });
      _length = index;
    }
    _truncate(record);
    _collection = collection;
    return isDirty;
  }

  // CollectionChanges is considered dirty if it has any additions, moves,
  // removals, or identity changes.
  bool get isDirty {
    return !identical(_additionsHead, null) ||
        !identical(_movesHead, null) ||
        !identical(_removalsHead, null) ||
        !identical(_identityChangesHead, null);
  }

  /// Reset the state of the change objects to show no changes. This means set
  /// previousKey to currentKey, and clear all of the queues (additions, moves,
  /// removals). Set the previousIndexes of moved and added items to their
  /// currentIndexes. Reset the list of additions, moves and removals
  ///
  /// @internal
  void _reset() {
    if (isDirty) {
      CollectionChangeRecord? record;
      CollectionChangeRecord? nextRecord;
      for (record = _previousItHead = _itHead;
          record != null;
          record = record._next) {
        record._nextPrevious = record._next;
      }
      for (record = _additionsHead;
          record != null;
          record = record._nextAdded) {
        record.previousIndex = record.currentIndex;
      }
      _additionsHead = _additionsTail = null;
      for (record = _movesHead; record != null; record = nextRecord) {
        record.previousIndex = record.currentIndex;
        nextRecord = record._nextMoved;
      }
      _movesHead = _movesTail = null;
      _removalsHead = _removalsTail = null;
      _identityChangesHead = _identityChangesTail = null;
    }
  }

  /// This is the core function which handles differences between collections.
  ///
  /// - `record` is the record which we saw at this position last time. If null
  ///   then it is a new item.
  /// - `item` is the current item in the collection
  /// - `index` is the position of the item in the collection
  ///
  /// @internal
  CollectionChangeRecord _mismatch(CollectionChangeRecord? record, dynamic item,
      dynamic itemTrackBy, int index) {
    // The previous record after which we will append the current one.
    CollectionChangeRecord? previousRecord;
    if (record == null) {
      previousRecord = _itTail;
    } else {
      previousRecord = record._prev;
      // Remove the record from the collection since we know it does not match
      // the item.
      _remove(record);
    }
    // Attempt to see if we have seen the item before.
    record = _linkedRecords?.get(itemTrackBy, index);
    if (record != null) {
      // We have seen this before, we need to move it forward in the collection.
      // But first we need to check if identity changed, so we can update in
      // view if necessary.
      if (!identical(record.item, item)) _addIdentityChange(record, item);
      _moveAfter(record, previousRecord, index);
    } else {
      // Never seen it, check evicted list.
      record = _unlinkedRecords?.get(itemTrackBy);
      if (record != null) {
        // It is an item which we have evicted earlier: reinsert it back into
        // the list. But first we need to check if identity changed, so we can
        // update in view if necessary
        if (!identical(record.item, item)) {
          _addIdentityChange(record, item);
        }
        _reinsertAfter(record, previousRecord, index);
      } else {
        // It is a new item: add it.
        record = _addAfter(
            CollectionChangeRecord(item, itemTrackBy), previousRecord, index);
      }
    }
    return record;
  }

  /// This check is only needed if an array contains duplicates. (Short circuit
  /// of nothing dirty)
  ///
  /// Use case: `[a, a]` => `[b, a, a]`
  ///
  /// If we did not have this check then the insertion of `b` would:
  ///   1) evict first `a`
  ///   2) insert `b` at `0` index.
  ///   3) leave `a` at index `1` as is. <-- this is wrong!
  ///   3) reinsert `a` at index 2. <-- this is wrong!
  ///
  /// The correct behavior is:
  ///   1) evict first `a`
  ///   2) insert `b` at `0` index.
  ///   3) reinsert `a` at index 1.
  ///   3) move `a` at from `1` to `2`.
  ///
  ///
  /// Double check that we have not evicted a duplicate item. We need to check
  /// if the item type may have already been removed:
  ///
  /// The insertion of b will evict the first 'a'. If we don't reinsert it now
  /// it will be reinserted at the end. Which will show up as the two 'a's
  /// switching position. This is incorrect, since a better way to think of it
  /// is as insert of 'b' rather then switch 'a' with 'b' and then add 'a'
  /// at the end.
  ///
  /// @internal
  CollectionChangeRecord _verifyReinsertion(CollectionChangeRecord record,
      dynamic item, dynamic itemTrackBy, int index) {
    var reinsertRecord = _unlinkedRecords?.get(itemTrackBy);
    if (reinsertRecord != null) {
      record = _reinsertAfter(reinsertRecord, record._prev, index);
    } else if (record.currentIndex != index) {
      record.currentIndex = index;
      _addToMoves(record, index);
    }
    return record;
  }

  /// Get rid of any excess [CollectionChangeRecord]s from the previous
  /// collection.
  ///
  /// - `record` The first excess [CollectionChangeRecord].
  ///
  /// @internal
  void _truncate(CollectionChangeRecord? record) {
    // Anything after that needs to be removed;
    while (record != null) {
      var nextRecord = record._next;
      _addToRemovals(_unlink(record));
      record = nextRecord;
    }
    _unlinkedRecords?.clear();
    _additionsTail?._nextAdded = null;
    _movesTail?._nextMoved = null;
    _itTail?._next = null;
    _removalsTail?._nextRemoved = null;
    _identityChangesTail?._nextIdentityChange = null;
  }

  CollectionChangeRecord _reinsertAfter(CollectionChangeRecord record,
      CollectionChangeRecord? prevRecord, int index) {
    if (!identical(_unlinkedRecords, null)) {
      _unlinkedRecords!.remove(record);
    }
    var prev = record._prevRemoved;
    var next = record._nextRemoved;
    if (prev == null) {
      _removalsHead = next;
    } else {
      prev._nextRemoved = next;
    }
    if (next == null) {
      _removalsTail = prev;
    } else {
      next._prevRemoved = prev;
    }
    _insertAfter(record, prevRecord, index);
    _addToMoves(record, index);
    return record;
  }

  CollectionChangeRecord _moveAfter(CollectionChangeRecord record,
      CollectionChangeRecord? prevRecord, int index) {
    _unlink(record);
    _insertAfter(record, prevRecord, index);
    _addToMoves(record, index);
    return record;
  }

  CollectionChangeRecord _addAfter(CollectionChangeRecord record,
      CollectionChangeRecord? prevRecord, int index) {
    _insertAfter(record, prevRecord, index);
    if (identical(_additionsTail, null)) {
      // todo(vicb)

      // assert(this._additionsHead === null);
      _additionsTail = _additionsHead = record;
    } else {
      // todo(vicb)

      // assert(_additionsTail._nextAdded === null);

      // assert(record._nextAdded === null);
      _additionsTail = _additionsTail!._nextAdded = record;
    }
    return record;
  }

  CollectionChangeRecord _insertAfter(CollectionChangeRecord record,
      CollectionChangeRecord? prevRecord, int index) {
    // todo(vicb)

    // assert(record != prevRecord);

    // assert(record._next === null);

    // assert(record._prev === null);
    var next = (prevRecord == null) ? _itHead : prevRecord._next;
    // todo(vicb)

    // assert(next != record);

    // assert(prevRecord != record);
    record._next = next;
    record._prev = prevRecord;
    if (next == null) {
      _itTail = record;
    } else {
      next._prev = record;
    }
    if (prevRecord == null) {
      _itHead = record;
    } else {
      prevRecord._next = record;
    }
    (_linkedRecords ??= _DuplicateMap()).put(record);
    record.currentIndex = index;
    return record;
  }

  CollectionChangeRecord _remove(CollectionChangeRecord record) {
    return _addToRemovals(_unlink(record));
  }

  CollectionChangeRecord _unlink(CollectionChangeRecord record) {
    _linkedRecords?.remove(record);
    var prev = record._prev;
    var next = record._next;
    // todo(vicb)

    // assert((record._prev = null) === null);

    // assert((record._next = null) === null);
    if (prev == null) {
      _itHead = next;
    } else {
      prev._next = next;
    }
    if (next == null) {
      _itTail = prev;
    } else {
      next._prev = prev;
    }
    return record;
  }

  CollectionChangeRecord _addToMoves(
      CollectionChangeRecord record, int toIndex) {
    // todo(vicb)

    // assert(record._nextMoved === null);
    if (identical(record.previousIndex, toIndex)) {
      return record;
    }
    if (identical(_movesTail, null)) {
      // todo(vicb)

      // assert(_movesHead === null);
      _movesTail = _movesHead = record;
    } else {
      // todo(vicb)

      // assert(_movesTail._nextMoved === null);
      _movesTail = _movesTail!._nextMoved = record;
    }
    return record;
  }

  CollectionChangeRecord _addToRemovals(CollectionChangeRecord record) {
    (_unlinkedRecords ??= _DuplicateMap()).put(record);
    record.currentIndex = null;
    record._nextRemoved = null;
    if (identical(_removalsTail, null)) {
      // todo(vicb)

      // assert(_removalsHead === null);
      _removalsTail = _removalsHead = record;
      record._prevRemoved = null;
    } else {
      // todo(vicb)

      // assert(_removalsTail._nextRemoved === null);

      // assert(record._nextRemoved === null);
      record._prevRemoved = _removalsTail;
      _removalsTail = _removalsTail!._nextRemoved = record;
    }
    return record;
  }

  CollectionChangeRecord _addIdentityChange(
      CollectionChangeRecord record, dynamic item) {
    record.item = item;
    if (identical(_identityChangesTail, null)) {
      _identityChangesTail = _identityChangesHead = record;
    } else {
      _identityChangesTail = _identityChangesTail!._nextIdentityChange = record;
    }
    return record;
  }

  @override
  String toString() {
    if (isDevMode) {
      var list = <Object>[];
      for (var record = _itHead; record != null; record = record._next) {
        list.add(record);
      }
      var previous = <Object>[];
      for (var record = _previousItHead;
          record != null;
          record = record._nextPrevious) {
        previous.add(record);
      }
      var additions = <dynamic>[];
      forEachAddedItem((record) => additions.add(record));
      var moves = <dynamic>[];
      for (var record = _movesHead;
          record != null;
          record = record._nextMoved) {
        moves.add(record);
      }
      var removals = <Object>[];
      forEachRemovedItem((record) => removals.add(record));
      var identityChanges = <Object>[];
      forEachIdentityChange((record) => identityChanges.add(record));
      return 'collection: ' +
          list.join(', ') +
          '\n' +
          'previous: ' +
          previous.join(', ') +
          '\n' +
          'additions: ' +
          additions.join(', ') +
          '\n' +
          'moves: ' +
          moves.join(', ') +
          '\n' +
          'removals: ' +
          removals.join(', ') +
          '\n' +
          'identityChanges: ' +
          identityChanges.join(', ') +
          '\n';
    } else {
      return super.toString();
    }
  }
}

class CollectionChangeRecord {
  dynamic item;
  dynamic trackById;
  int? currentIndex;
  int? previousIndex;

  CollectionChangeRecord? _nextPrevious;

  CollectionChangeRecord? _prev;

  CollectionChangeRecord? _next;

  CollectionChangeRecord? _prevDup;

  CollectionChangeRecord? _nextDup;

  CollectionChangeRecord? _prevRemoved;

  CollectionChangeRecord? _nextRemoved;

  CollectionChangeRecord? _nextAdded;

  CollectionChangeRecord? _nextMoved;

  CollectionChangeRecord? _nextIdentityChange;
  CollectionChangeRecord(this.item, this.trackById);

  @override
  String toString() {
    return identical(previousIndex, currentIndex)
        ? item.toString()
        : '$item[$previousIndex->$currentIndex]';
  }
}

// A linked list of CollectionChangeRecords with the same
// CollectionChangeRecord.item
class _DuplicateItemRecordList {
  CollectionChangeRecord? _head;

  CollectionChangeRecord? _tail;

  /// Append the record to the list of duplicates.
  ///
  /// Note: by design all records in the list of duplicates hold the same value
  /// in record.item.
  void add(CollectionChangeRecord record) {
    if (identical(_head, null)) {
      _head = _tail = record;
      record._nextDup = null;
      record._prevDup = null;
    } else {
      _tail!._nextDup = record;
      record._prevDup = _tail;
      record._nextDup = null;
      _tail = record;
    }
  }

  // Returns a CollectionChangeRecord having CollectionChangeRecord.trackById
  // == trackById and CollectionChangeRecord.currentIndex >= afterIndex
  CollectionChangeRecord? get(dynamic trackById, int? afterIndex) {
    CollectionChangeRecord? record;
    for (record = _head; record != null; record = record._nextDup) {
      if ((afterIndex == null || afterIndex < record.currentIndex!) &&
          identical(record.trackById, trackById)) {
        return record;
      }
    }
    return null;
  }

  /// Remove one [CollectionChangeRecord] from the list of duplicates.
  ///
  /// Returns whether the list of duplicates is empty.
  bool remove(CollectionChangeRecord record) {
    var prev = record._prevDup;
    var next = record._nextDup;
    if (prev == null) {
      _head = next;
    } else {
      prev._nextDup = next;
    }
    if (next == null) {
      _tail = prev;
    } else {
      next._prevDup = prev;
    }
    return identical(_head, null);
  }
}

class _DuplicateMap {
  final Map<dynamic, _DuplicateItemRecordList> _map;
  _DuplicateMap() : _map = Map.identity();

  void put(CollectionChangeRecord record) {
    // todo(vicb) handle corner cases
    var key = record.trackById;
    var duplicates = _map[key];
    if (duplicates == null) {
      duplicates = _DuplicateItemRecordList();
      _map[key] = duplicates;
    }
    duplicates.add(record);
  }

  /// Retrieve the `value` using key. Because the CollectionChangeRecord value
  /// may be one which we have already iterated over, we use the afterIndex to
  /// pretend it is not there.
  ///
  /// Use case: `[a, b, c, a, a]` if we are at index `3` which is the second `a`
  /// then asking if we have any more `a`s needs to return the last `a` not the
  /// first or second.
  CollectionChangeRecord? get(dynamic trackById, [int? afterIndex]) {
    var recordList = _map[trackById];
    return recordList?.get(trackById, afterIndex);
  }

  /// Removes a [CollectionChangeRecord] from the list of duplicates.
  ///
  /// The list of duplicates also is removed from the map if it gets empty.
  CollectionChangeRecord remove(CollectionChangeRecord record) {
    var key = record.trackById;
    // todo(vicb)
    // assert(this.map.containsKey(key));
    var recordList = _map[key]!;
    // Remove the list of duplicates when it gets empty
    if (recordList.remove(record)) {
      _map.remove(key);
    }
    return record;
  }

  bool get isEmpty {
    return identical(_map.length, 0);
  }

  void clear() {
    _map.clear();
  }

  @override
  String toString() {
    return '_DuplicateMap($_map)';
  }
}

int? _getPreviousIndex(
    CollectionChangeRecord item, int addRemoveOffset, List<int?>? moveOffsets) {
  var previousIndex = item.previousIndex;

  if (previousIndex == null) return null;

  var moveOffset = 0;
  if (moveOffsets != null && previousIndex < moveOffsets.length) {
    moveOffset = moveOffsets[previousIndex]!;
  }

  return previousIndex + addRemoveOffset + moveOffset;
}
