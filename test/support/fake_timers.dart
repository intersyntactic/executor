/// Timers that run only when a test fires them, for an [Executor]'s
/// `startTimer`: a test says when a deadline has passed, and never races a
/// real clock to see what happens then.
library;

import 'dart:async';

import 'package:is_executor/is_executor.dart';

final class FakeTimers {
  /// [real] are left to the clock. By default that is the pause between
  /// signals to a group not yet empty: it is a deadline nobody waits on, only
  /// time for a fork in flight to finish, which is what a kill test checks.
  FakeTimers({this.real = const {ExecTimer.resignal}});

  final Set<ExecTimer> real;
  final _all = <FakeTimer>[];
  final _claimed = <FakeTimer>{};
  final _started = StreamController<FakeTimer>.broadcast();

  /// Each fake timer as it is started.
  Stream<FakeTimer> get started => _started.stream;

  /// Every fake timer started so far, in order.
  List<FakeTimer> get all => List.unmodifiable(_all);

  /// Passed as `startTimer`.
  Timer call(ExecTimer role, Duration duration, void Function() callback) {
    if (real.contains(role)) return Timer(duration, callback);
    final timer = FakeTimer._(role, duration, callback);
    _all.add(timer);
    _started.add(timer);
    return timer;
  }

  /// The first timer for [role] that no earlier call has returned: one
  /// already started, or else the next one to start.
  Future<FakeTimer> next(ExecTimer role) async {
    bool fresh(FakeTimer t) => t.role == role && !_claimed.contains(t);
    final timer =
        _all.where(fresh).firstOrNull ?? await started.firstWhere(fresh);
    _claimed.add(timer);
    return timer;
  }
}

final class FakeTimer implements Timer {
  FakeTimer._(this.role, this.duration, this._callback);

  final ExecTimer role;
  final Duration duration;
  final void Function() _callback;
  var _active = true;
  var _fired = false;

  /// Runs the callback, as the real timer would when [duration] had passed,
  /// and says whether it ran: a timer that was cancelled or has fired does
  /// nothing.
  bool fire() {
    if (!_active) return false;
    _active = false;
    _fired = true;
    _callback();
    return true;
  }

  @override
  void cancel() => _active = false;

  @override
  bool get isActive => _active;

  @override
  int get tick => _fired ? 1 : 0;
}
