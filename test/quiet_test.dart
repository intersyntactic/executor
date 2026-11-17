/// A command that goes silent for longer than `quiet` once it has started
/// printing is killed like a timeout, while one that keeps printing runs on.
@TestOn('!windows')
library;

import 'dart:async';
import 'dart:io';

import 'package:is_executor/is_executor.dart';
import 'package:test/test.dart';

import 'support/fake_timers.dart';
import 'support/process_groups.dart';

void main() {
  late Directory tree;
  late FakeTimers timers;
  setUp(() {
    tree = Directory.systemTemp.createTempSync('exec_quiet_').absolute;
    timers = FakeTimers();
  });
  tearDown(() => tree.deleteSync(recursive: true));

  // Never passed: what ends these commands is silence, or the test.
  const timeout = Duration(minutes: 1);
  const quiet = Duration(milliseconds: 600);

  Executor exec() => Executor(
    root: tree,
    consent: (_) async => true,
    timeout: timeout,
    startTimer: timers.call,
  );

  // A fifo in the tree. A command that reads it (`read x < gate`) waits there
  // until [open] writes a line.
  String gate(String name) {
    final fifo = '${tree.path}/$name';
    Process.runSync('mkfifo', [fifo]);
    return fifo;
  }

  // The line is written by a shell of its own, whose open waits for the
  // reader: one written with nobody reading is dropped when the writer
  // closes. If the command dies first, the shell waits on, and is killed at
  // the end of the test instead of holding this process open.
  Future<void> open(String gate) async {
    final writer = await Process.start('/bin/sh', [
      '-c',
      r'echo go > "$1"',
      'sh',
      gate,
    ]);
    addTearDown(writer.kill);
    await writer.exitCode;
  }

  // The first [runs] runs go silent after their output: each quiet timer is
  // fired as it starts. One that later output has already cancelled does not
  // count, since output can arrive in more than one chunk.
  void silenceFirst(int runs) {
    var left = runs;
    timers.started.listen((t) {
      if (t.role == ExecTimer.quiet && left > 0 && t.fire()) left--;
    });
  }

  // Bounded so that a failure says why, not a hang.
  Future<T> soon<T>(Future<T> f, String reason) =>
      f.timeout(const Duration(seconds: 10), onTimeout: () => fail(reason));

  test('a command that prints and then goes silent is killed after quiet, '
      'with its tree', () async {
    int? leader;
    // A survivor is still in the group: this ends one the kill missed.
    addTearDown(() {
      if (leader != null) Process.killPid(-leader!, ProcessSignal.sigkill);
    });
    final run = exec().run(
      ['/bin/sh', '-c', '(echo loading; sleep 30) & wait'],
      quiet: quiet,
      taps: ExecTaps(onProcess: (pid, _, _) => leader ??= pid),
    );
    (await timers.next(ExecTimer.quiet)).fire();
    // Everything the command starts inherits its stdout, and the drain
    // wait is never passed: a run that returns had nothing left holding
    // its pipes.
    final r = await soon(run, 'the silent tree still holds its pipes');
    expect(r.silentFor, quiet);
    expect(
      r.timedOut,
      isFalse,
      reason: 'killed at the silence, not the timeout',
    );
    expect(r.stdout, contains('loading'));
    expect(r.forModel, startsWith('printed nothing for 0s and was killed'));
    expect(
      liveIn({leader!}),
      isEmpty,
      reason: 'the silent tree was abandoned, not killed',
    );
  });

  test('a command that keeps printing runs past quiet', () async {
    // Two gates: reopening one fifo could meet the first writer before it
    // closed, and read the end of its line instead of waiting.
    final first = gate('first');
    final second = gate('second');
    final run = exec().run(
      ['/bin/sh', '-c', 'echo 1; read x < $first; echo 2; read x < $second'],
      quiet: quiet,
      taps: ExecTaps.none,
    );
    final afterFirst = await timers.next(ExecTimer.quiet);
    await open(first);
    await timers.next(ExecTimer.quiet);
    // Silence counts from the latest output: the wait the first line started
    // is over without making the command silent.
    afterFirst.fire();
    unawaited(open(second));
    final r = await soon(run, 'the command was neither killed nor let go');
    expect(r.silentFor, isNull);
    expect(r.exitCode, 0);
    expect(r.stdout.trim().split('\n'), ['1', '2']);
  });

  test('silence before the first output is a slow start, not a hang', () async {
    final g = gate('gate');
    final run = exec().run(
      ['/bin/sh', '-c', 'read x < $g; echo started; echo done'],
      quiet: quiet,
      taps: ExecTaps.none,
    );
    await timers.next(ExecTimer.timeout);
    // The command waits on the fifo, having printed nothing.
    expect(
      timers.all.where((t) => t.role == ExecTimer.quiet),
      isEmpty,
      reason: 'nothing had printed yet, so nothing can go silent',
    );
    await open(g);
    final r = await run;
    expect(r.exitCode, 0);
    expect(r.stdout, contains('done'));
  });

  test('without quiet, silence is only bounded by the timeout', () async {
    final g = gate('gate');
    final run = exec().run([
      '/bin/sh',
      '-c',
      'echo waiting; read x < $g; echo done',
    ], taps: ExecTaps.none);
    await timers.next(ExecTimer.timeout);
    await open(g);
    final r = await run;
    expect(r.silentFor, isNull);
    expect(r.stdout, contains('done'));
    expect(
      timers.all.map((t) => t.role),
      isNot(contains(ExecTimer.quiet)),
      reason: 'the only timer that can end it is the timeout',
    );
  });

  test('beforeSilentKill sees the silent command still alive, '
      'and only a silent one', () async {
    final seen = <(int, bool)>[];
    silenceFirst(1);
    final ex = Executor(
      root: tree,
      consent: (_) async => true,
      startTimer: timers.call,
      beforeSilentKill: (pid) async {
        final alive = (await Process.run('kill', ['-0', '$pid'])).exitCode == 0;
        seen.add((pid, alive));
      },
    );
    final r = await ex.run(
      ['/bin/sh', '-c', 'echo loading; sleep 30'],
      quiet: quiet,
      taps: ExecTaps.none,
    );
    expect(r.silentFor, quiet);
    expect(seen, hasLength(1));
    expect(
      seen.single.$2,
      isTrue,
      reason: 'recorded before the kill, not after',
    );
    await ex.run(
      ['/bin/sh', '-c', 'echo done'],
      quiet: quiet,
      taps: ExecTaps.none,
    );
    expect(seen, hasLength(1), reason: 'a command that exits is not captured');
  });
}
