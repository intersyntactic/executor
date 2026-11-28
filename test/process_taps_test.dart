/// A run's processes reach its caller through the [ExecTaps] it was given:
/// one report when the process starts, one when it has let go of stdout and
/// stderr -- which is later than the command's exit if a grandchild still
/// holds the pipes. And when a call is over, its result says what the
/// command left running in its group, pipes or no pipes.
@TestOn('!windows')
library;

import 'dart:async';
import 'dart:io';

import 'package:is_executor/is_executor.dart';
import 'package:test/test.dart';

import 'support/fake_timers.dart';
import 'support/run_reporting_lines.dart';

void main() {
  late Directory tmp;
  late FakeTimers timers;
  setUp(() {
    tmp = Directory.systemTemp.createTempSync('proctap_').absolute;
    timers = FakeTimers();
  });
  tearDown(() => tmp.deleteSync(recursive: true));

  Executor executor() =>
      Executor(root: tmp, consent: (_) async => true, startTimer: timers.call);

  // Each wait for the pipes to close, passed once the command's output is in
  // ([said]): the run returns while a leftover still holds them. Passing it
  // sooner can stop the capture before the output is read off the pipe.
  void passDrains(Future<void> said) => timers.started.listen((t) {
    if (t.role == ExecTimer.drain) unawaited(said.then((_) => t.fire()));
  });

  test('a command reports start, then end, with the same pid', () async {
    final log = <(int, List<String>, bool)>[];
    final ended = Completer<void>();
    await executor().run(
      ['echo', 'hi'],
      taps: ExecTaps(
        onProcess: (pid, argv, e) {
          log.add((pid, argv, e));
          if (e) ended.complete();
        },
      ),
    );
    await ended.future;
    expect(log, hasLength(2));
    expect(log.first.$3, isFalse);
    expect(log.first.$2, ['echo', 'hi']);
    expect(log.last.$3, isTrue);
    expect(log.last.$1, log.first.$1);
  });

  test('a grandchild holding the pipes keeps the process "not ended" '
      'after the command has returned', () async {
    final log = <bool>[];
    final ended = Completer<void>();
    int? leader;
    final said = Completer<void>();
    passDrains(said.future);
    final r = await runReportingLines(
      executor(),
      // The background sleep inherits stdout/stderr and outlives the shell.
      ['sh', '-c', 'sleep 30 & echo launched'],
      taps: ExecTaps(
        onProcess: (pid, argv, e) {
          leader = pid;
          log.add(e);
          if (e) ended.complete();
        },
      ),
      onLine: (_) => said.complete(),
    );
    expect(r.exitCode, 0);
    // The result is back, the leftover is still there: not ended yet.
    expect(log, [false]);
    // Its group is the command's: killing it lets go of the pipes.
    Process.killPid(-leader!, ProcessSignal.sigkill);
    await ended.future;
    expect(log, [false, true]);
  });

  test('a refused command starts no process, so reports none', () async {
    final log = <bool>[];
    await Executor(root: tmp, consent: Executor.refuseAll).run([
      'echo',
      'hi',
    ], taps: ExecTaps(onProcess: (pid, argv, e) => log.add(e)));
    expect(log, isEmpty);
  });

  test('a tap that throws does not fail the command', () async {
    final r = await executor().run(
      ['echo', 'hi'],
      taps: ExecTaps(
        onProcess: (pid, argv, e) => throw StateError('display bug'),
      ),
    );
    expect(r.exitCode, 0);
  });

  group('ExecResult.leftovers, seen while the ids are held', () {
    // Runs [script] and returns what its result says it left running.
    // [said] completes at the first line of output.
    Future<Leftovers?> left(String script, {Completer<void>? said}) async {
      int? leader;
      final r = await runReportingLines(
        executor(),
        ['/bin/sh', '-c', script],
        taps: ExecTaps(onProcess: (pid, _, _) => leader ??= pid),
        onLine: (_) {
          if (said != null && !said.isCompleted) said.complete();
        },
      );
      // Do not leave a leftover behind. By group id, after the run has let
      // go of it: a test's cleanup, not something the library does.
      addTearDown(() => Process.killPid(-leader!, ProcessSignal.sigkill));
      return r.leftovers;
    }

    test('a background process that redirected its output is seen', () async {
      // It let go of the pipes (so the pipes alone say "ended"), yet it runs.
      final l = await left('sleep 30 >/dev/null 2>&1 & echo launched');
      expect(l?.inGroup, 1);
    });

    test('a background process still holding the pipes is seen', () async {
      final said = Completer<void>();
      passDrains(said.future);
      final l = await left('sleep 30 & echo launched', said: said);
      expect(l?.inGroup, 1);
    });

    test('a command that cleaned up after itself leaves nothing', () async {
      final l = await left('echo clean');
      expect(l?.any, isFalse);
    });

    test('a command killed on timeout leaves nothing to see', () async {
      timers.started.listen((t) {
        if (t.role == ExecTimer.timeout) t.fire();
      });
      final l = await left('sleep 30');
      expect(l?.inGroup, 0);
    });
  });
}
