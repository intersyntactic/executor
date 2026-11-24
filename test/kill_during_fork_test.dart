/// A kill that lands while a process in the group is forking still reaches
/// the child: the signal goes to the members that exist at that instant, and
/// the child is born into the group a moment later.
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
  setUp(
    () => tree = Directory.systemTemp.createTempSync('kill_fork_').absolute,
  );
  tearDown(() => tree.deleteSync(recursive: true));

  const timeout = Duration(minutes: 1);

  // Runs [script] under `sh -c` and kills it the moment it prints, as it
  // forks: by passing the timeout, or by [Running.kill] when [onRequest].
  // Every process it starts inherits its stdout, so the run returning at all
  // means none of them outlived the kill (the drain wait is never passed).
  // Returns its group, which should then be empty.
  Future<int> killedAsItForks(String script, {required bool onRequest}) async {
    final timers = FakeTimers();
    int? leader;
    // A survivor is still in the group: this ends one the kill missed.
    addTearDown(() {
      if (leader != null) Process.killPid(-leader!, ProcessSignal.sigkill);
    });
    final running =
        Executor(
          root: tree,
          consent: (_) async => true,
          timeout: timeout,
          startTimer: timers.call,
        ).start([
          '/bin/sh',
          '-c',
          script,
        ], taps: ExecTaps(onProcess: (pid, _, _) => leader ??= pid));
    unawaited(running.stderr.drain<void>());
    await running.stdout.transform(const LineSplitter()).first;
    if (onRequest) {
      unawaited(running.kill());
    } else {
      (await timers.next(ExecTimer.timeout)).fire();
    }
    final r = startedResult(
      await running.result.timeout(
        const Duration(seconds: 10),
        onTimeout: () => fail('a child born as the group was killed lives on'),
      ),
    );
    expect(
      r.whyKilled,
      onRequest ? isA<KilledOnRequest>() : isA<KilledForTimeout>(),
    );
    return leader!;
  }

  // Each kill lands in the fork only sometimes; side by side, the forking
  // shells are often between scheduling slices, which is where it lands.
  Future<void> manyAtOnce(String script, {required bool onRequest}) async {
    for (var round = 0; round < 6; round++) {
      final groups = await Future.wait([
        for (var i = 0; i < 8; i++)
          killedAsItForks(script, onRequest: onRequest),
      ]);
      expect(liveIn(groups.toSet()), isEmpty, reason: 'their groups are empty');
    }
  }

  for (final (how, onRequest) in const [
    ('a timeout', false),
    ('a kill on request', true),
  ]) {
    test('$how as the command forks kills the child too', () async {
      await manyAtOnce('echo ready; sleep 30', onRequest: onRequest);
    });

    test('$how as a grandchild forks kills its child too', () async {
      await manyAtOnce('(echo ready; sleep 30) & wait', onRequest: onRequest);
    });
  }
}
