/// A command that runs past its timeout is killed, not just abandoned; and
/// output that is not UTF-8 is reported as output.
@TestOn('!windows')
library;

import 'dart:async';
import 'dart:ffi';
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
    tree = Directory.systemTemp.createTempSync('exec_timeout_').absolute;
    timers = FakeTimers();
  });
  tearDown(() => tree.deleteSync(recursive: true));

  // Fired by a test when it means the deadline to pass; otherwise never.
  const timeout = Duration(minutes: 1);

  Executor exec() => Executor(
    root: tree,
    consent: (_) async => true,
    timeout: timeout,
    startTimer: timers.call,
  );

  // Bounded so that a survivor fails the test with a reason, not a hang.
  Future<T> soon<T>(Future<T> f, String reason) =>
      f.timeout(const Duration(seconds: 10), onTimeout: () => fail(reason));

  // Runs [script] until it prints its first line, then passes the timeout;
  // returns the result and the command's process group. Everything the
  // command starts inherits its stdout, and the drain wait is never passed,
  // so a run that returns at all had nothing left holding its pipes.
  Future<(ExecResult, int)> timeOut(String script) async {
    final ready = Completer<void>();
    int? leader;
    // A survivor is still in the group: this ends one the kill missed.
    addTearDown(() {
      if (leader != null) Process.killPid(-leader!, ProcessSignal.sigkill);
    });
    final run = runReportingLines(
      exec(),
      ['/bin/sh', '-c', script],
      taps: ExecTaps(onProcess: (pid, _, _) => leader ??= pid),
      onLine: (_) {
        if (!ready.isCompleted) ready.complete();
      },
    );
    await ready.future;
    (await timers.next(ExecTimer.timeout)).fire();
    final r = await soon(
      run,
      'something the command started still holds its pipes',
    );
    return (r, leader!);
  }

  test('a timeout KILLS the process, not just the wait', () async {
    final (r, group) = await timeOut('echo ready; sleep 30');
    expect(r.timedOut, isTrue);
    expect(r.stdout, contains('ready'), reason: 'partial output is real');
    expect(r.forModel, contains('killed'));
    expect(liveIn({group}), isEmpty, reason: 'it outlived its timeout');
  });

  test(
    'a timeout kills what the command started, not just the command',
    () async {
      // The grandchild lets go of the pipes, so the run returns whether or
      // not it was killed: only its group can say.
      final (r, group) = await timeOut(
        '(echo ready; exec sleep 30 >/dev/null 2>&1) & wait',
      );
      expect(r.timedOut, isTrue);
      expect(
        liveIn({group}),
        isEmpty,
        reason: 'the backgrounded grandchild outlived the timeout',
      );
    },
  );

  test(
    'a timeout kills a grandchild whose parent has already exited',
    () async {
      // The middle subshell exits at once, so the sleeper is re-parented to
      // pid 1 -- out of reach of any walk of parent pids, still in the group.
      final (r, group) = await timeOut(
        '( (echo ready; sleep 30) & ) ; sleep 30',
      );
      expect(r.timedOut, isTrue);
      expect(
        liveIn({group}),
        isEmpty,
        reason: 'the orphaned grandchild outlived its group',
      );
    },
  );

  test('a grandchild holding the pipes does not cost the exit code', () async {
    int? leader;
    final said = Completer<void>();
    final run = runReportingLines(
      exec(),
      ['/bin/sh', '-c', '(sleep 30) & echo hi; exit 4'],
      taps: ExecTaps(onProcess: (pid, _, _) => leader = pid),
      onLine: (_) => said.complete(),
    );
    // The command has exited and its output is in; the sleeper still holds
    // the pipes. Passing the drain wait sooner would cut the output short.
    final drain = await timers.next(ExecTimer.drain);
    await said.future;
    drain.fire();
    final r = await run;
    addTearDown(() => Process.killPid(-leader!, ProcessSignal.sigkill));
    expect(
      r.timedOut,
      isFalse,
      reason: 'done is the command exiting, not the pipes closing',
    );
    expect(r.exitCode, 4);
    expect(r.stdout, contains('hi'));
  });

  test('the command leads a process group of its own', () async {
    int? started;
    final r = await exec().run(
      ['/bin/sh', '-c', r'ps -o pgid= -p $$'],
      taps: ExecTaps(
        onProcess: (pid, _, ended) {
          if (!ended) started = pid;
        },
      ),
    );
    expect(r.exitCode, 0);
    expect(
      int.parse(r.stdout.trim()),
      started,
      reason: 'its group id is the pid we hold',
    );
  });

  test('a command killed by a signal reads as minus that signal', () async {
    final r = await exec().run([
      '/bin/sh',
      '-c',
      r'kill -TERM $$',
    ], taps: ExecTaps.none);
    expect(r.timedOut, isFalse);
    expect(r.exitCode, -15, reason: 'not 128+15, which a shell would report');
  });

  test('stderr is exactly what the command wrote', () async {
    final r = await exec().run([
      '/bin/sh',
      '-c',
      r'printf oops >&2; exit 3',
    ], taps: ExecTaps.none);
    expect(r.exitCode, 3);
    expect(r.stderr, 'oops');
  });

  test('a missing program exits 127, as a shell says it', () async {
    final r = await exec().run([
      'definitely-not-a-real-program-xyz',
    ], taps: ExecTaps.none);
    expect(r.timedOut, isFalse);
    expect(r.exitCode, 127);
    expect(r.stderr, contains('definitely-not-a-real-program-xyz'));
    expect(r.forModel, contains('definitely-not-a-real-program-xyz'));
  });

  test('the command leads a session of its own', () async {
    // A session leader's session id is its pid. In the caller's session, a
    // command that read the caller's terminal would be stopped by SIGTTIN
    // instead of failing; this holds with or without a terminal here.
    final getsid = DynamicLibrary.process()
        .lookupFunction<Int32 Function(Int32), int Function(int)>('getsid');
    int? pid;
    final sampled = Completer<int>();
    final run = runReportingLines(
      exec(),
      ['/bin/sh', '-c', 'echo ready; sleep 30'],
      taps: ExecTaps(
        onProcess: (p, _, ended) {
          if (!ended) pid = p;
        },
      ),
      // The command printing means the shim has run: its setsid comes
      // before the exec. Until the timeout below, it is still running.
      onLine: (_) {
        if (!sampled.isCompleted) sampled.complete(getsid(pid!));
      },
    );
    final sid = await sampled.future;
    (await timers.next(ExecTimer.timeout)).fire();
    await run;
    expect(sid, pid);
  });

  test(
    'a command that finishes while it is looked at keeps its exit code',
    () async {
      // The command waits on the fifo; looking at it lets it go, and the look
      // ends once it has exited.
      const quiet = Duration(seconds: 1);
      final gate = '${tree.path}/gate';
      Process.runSync('mkfifo', [gate]);
      final exited = Completer<void>();
      final ex = Executor(
        root: tree,
        consent: (_) async => true,
        timeout: timeout,
        startTimer: timers.call,
        onExited: (_) => exited.complete(),
        beforeSilentKill: (_) async {
          // Write-only, so the open waits for the command to be reading.
          await File(gate).writeAsString('go\n', mode: FileMode.writeOnly);
          await exited.future;
        },
      );
      final run = ex.run(
        ['/bin/sh', '-c', 'echo a; read x < $gate; exit 3'],
        quiet: quiet,
        taps: ExecTaps.none,
      );
      (await timers.next(ExecTimer.quiet)).fire();
      final r = await run;
      expect(r.silentFor, isNull, reason: 'it was slow, not stuck');
      expect(r.exitCode, 3);
    },
  );

  test('output stops being captured when the result is returned', () async {
    // The leftover counts its lines into a fifo too, so the test can see it
    // print on after the result without waiting on a clock. It prints nothing
    // until something reads the fifo.
    final counted = '${tree.path}/counted';
    Process.runSync('mkfifo', [counted]);
    var lines = 0;
    int? leader;
    final said = Completer<void>();
    final run = runReportingLines(
      exec(),
      [
        '/bin/sh',
        '-c',
        '(exec 3>$counted; while :; do echo x; echo x >&3; done) & echo hi',
      ],
      taps: ExecTaps(onProcess: (pid, _, _) => leader = pid),
      onLine: (_) {
        lines++;
        if (!said.isCompleted) said.complete();
      },
    );
    // The leftover prints nothing until the fifo is read, so `hi` is all the
    // command's output: pass the drain wait once it is in.
    final drain = await timers.next(ExecTimer.drain);
    await said.future;
    drain.fire();
    final r = await run;
    addTearDown(() => Process.killPid(-leader!, ProcessSignal.sigkill));
    expect(r.stdout, startsWith('hi'));
    final atReturn = lines;
    // The fifo is read by a shell of its own, not this process: a read that
    // never ends is then one more process to kill, not a test that hangs.
    final reader = await Process.start('/bin/sh', [
      '-c',
      r'head -n 200 "$1" > /dev/null',
      'sh',
      counted,
    ]);
    addTearDown(reader.kill);
    await soon(reader.exitCode, 'the leftover never printed 200 lines');
    expect(lines, atReturn, reason: 'the leftover still prints, but not to us');
  });

  test('a command that exits without reading stdin is fine', () async {
    for (var i = 0; i < 20; i++) {
      final r = await exec().run([
        '/bin/sh',
        '-c',
        'exit 0',
      ], taps: ExecTaps.none);
      expect(r.exitCode, 0);
    }
  });

  test('non-UTF-8 output is output, not a timeout', () async {
    final r = await exec().run([
      '/bin/sh',
      '-c',
      r"printf '\377\376ok'",
    ], taps: ExecTaps.none);
    expect(r.timedOut, isFalse);
    expect(r.exitCode, 0);
    expect(r.stdout, contains('ok'));
  });

  test('a command that finishes in time reports its exit code', () async {
    final r = await exec().run([
      '/bin/sh',
      '-c',
      'echo hi; exit 7',
    ], taps: ExecTaps.none);
    expect(r.timedOut, isFalse);
    expect(r.exitCode, 7);
    expect(r.forModel, startsWith('exit 7'));
  });
}
