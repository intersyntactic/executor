/// [Running.kill]: whoever started a command can kill it and everything it
/// started, at any moment, and the result says it was killed on request.
@TestOn('!windows')
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:is_executor/is_executor.dart';
import 'package:test/test.dart';

import 'support/fake_timers.dart';
import 'support/process_groups.dart';
import 'support/run_reporting_lines.dart';

void main() {
  late Directory tree;
  late FakeTimers timers;
  setUp(() {
    tree = Directory.systemTemp.createTempSync('exec_kill_').absolute;
    timers = FakeTimers();
  });
  tearDown(() => tree.deleteSync(recursive: true));

  // Never passed: the timeout and drain timers are fake and never fired, so a
  // run that returns at all had nothing left holding its pipes.
  Executor exec({
    ConsentGate? consent,
    void Function(int pid, ExecRequest request)? onStarted,
    void Function(int pid)? onExited,
  }) => Executor(
    root: tree,
    consent: consent ?? (_) async => true,
    timeout: const Duration(minutes: 1),
    startTimer: timers.call,
    onStarted: onStarted,
    onExited: onExited,
  );

  // Bounded so that a survivor fails the test with a reason, not a hang.
  Future<T> soon<T>(Future<T> f, String reason) =>
      f.timeout(const Duration(seconds: 10), onTimeout: () => fail(reason));

  // Remembers [leader]'s group, and ends any member a kill missed.
  void cleanUpGroup(int leader) =>
      addTearDown(() => Process.killPid(-leader, ProcessSignal.sigkill));

  test('a kill while it runs kills it and what it started, and the result '
      'says so', () async {
    final groups = <int>{};
    final running = exec().start(
      ['/bin/sh', '-c', 'sleep 30 & echo ready; wait'],
      taps: ExecTaps(
        onProcess: (pid, _, _) {
          groups.add(pid);
          cleanUpGroup(pid);
        },
      ),
    );
    await running.stdout.transform(const LineSplitter()).first;
    await soon(running.kill(), 'the backgrounded sleep outlived the kill');
    final r = startedResult(await running.result);
    expect(r.whyKilled, isA<KilledOnRequest>());
    expect(r.killedOnRequest, isTrue);
    expect(r.timedOut, isFalse);
    expect(r.silentFor, isNull);
    expect(r.exitCode, -1);
    expect(r.forModel, startsWith('was stopped and killed; no exit code'));
    expect(liveIn(groups), isEmpty, reason: 'its group is empty');
  });

  test('a kill before it starts means it never starts', () async {
    var started = false;
    final running = exec(onStarted: (_, _) => started = true)
        .start(['echo', 'hi'], taps: ExecTaps.none);
    await running.kill();
    expect(
      await running.result,
      isA<ExecNotStarted>().having(
        (s) => s.why,
        'why',
        'killed before it started',
      ),
    );
    expect(started, isFalse);
    expect(await running.stdout.isEmpty, isTrue);
  });

  test('a kill while it waits for approval means it never starts', () async {
    final approval = Completer<bool>();
    final asked = Completer<void>();
    var started = false;
    final running = exec(
      consent: (_) {
        asked.complete();
        return approval.future;
      },
      onStarted: (_, _) => started = true,
    ).start(['echo', 'hi'], taps: ExecTaps.none);
    await asked.future;
    final killed = running.kill();
    approval.complete(true);
    await killed;
    expect(await running.result, isA<ExecNotStarted>());
    expect(started, isFalse);
  });

  // The moment it is started, the shim may not have made its group yet, so
  // the group's id reaches nothing: the process itself has to be killed too.
  test('a kill the moment it is started still kills it', () async {
    for (var round = 0; round < 20; round++) {
      late Running running;
      int? leader;
      running = exec(
        onStarted: (pid, _) {
          leader = pid;
          cleanUpGroup(pid);
          unawaited(running.kill());
        },
      ).start(['/bin/sh', '-c', 'sleep 30 & wait'], taps: ExecTaps.none);
      final r = startedResult(
        await soon(running.result, 'the run outlived a kill at its start'),
      );
      expect(r.whyKilled, isA<KilledOnRequest>());
      expect(liveIn({leader!}), isEmpty);
    }
  });

  test('a kill once it has ended changes nothing', () async {
    final running = exec().start(['echo', 'hi'], taps: ExecTaps.none);
    final r = startedResult(await running.result);
    await running.kill();
    expect(identical(startedResult(await running.result), r), isTrue);
    expect(r.exitCode, 0);
    expect(r.whyKilled, isNull);
  });

  test('a second kill does no more than the first', () async {
    final running = exec().start([
      '/bin/sh',
      '-c',
      'echo ready; sleep 30',
    ], taps: ExecTaps(onProcess: (pid, _, _) => cleanUpGroup(pid)));
    await running.stdout.transform(const LineSplitter()).first;
    await soon(Future.wait([running.kill(), running.kill()]), 'not killed');
    await running.kill();
    expect(
      startedResult(await running.result).whyKilled,
      isA<KilledOnRequest>(),
    );
  });

  // The command exits, but a grandchild it backgrounded holds its stdout, so
  // the run waits on the drain. A kill then reaches the grandchild, and the
  // command's own exit code stands: it was not killed.
  test('a kill after it exits, while what it left holds its pipes, kills '
      'that and keeps its exit code', () async {
    late Running running;
    int? leader;
    running = exec(
      onStarted: (pid, _) {
        leader = pid;
        cleanUpGroup(pid);
      },
      onExited: (_) => unawaited(running.kill()),
    ).start(['/bin/sh', '-c', 'sleep 30 & exit 3'], taps: ExecTaps.none);
    final r = startedResult(
      await soon(running.result, 'the grandchild outlived the kill'),
    );
    expect(r.exitCode, 3);
    expect(r.whyKilled, isNull);
    expect(liveIn({leader!}), isEmpty);
  });
}
