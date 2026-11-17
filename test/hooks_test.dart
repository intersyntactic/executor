/// Executor tells its host when a child starts and exits -- including one it
/// kills on timeout -- so a host can watch for one that runs too long.
@TestOn('!windows')
library;

import 'dart:io';

import 'package:is_executor/is_executor.dart';
import 'package:test/test.dart';

import 'support/fake_timers.dart';

void main() {
  late Directory tmp;
  setUp(() => tmp = Directory.systemTemp.createTempSync('hooks_').absolute);
  tearDown(() => tmp.deleteSync(recursive: true));

  test('start and exit are reported with the same pid', () async {
    final started = <(int, List<String>)>[];
    final exited = <int>[];
    final r = await Executor(
      root: tmp,
      consent: (_) async => true,
      onStarted: (pid, req) => started.add((pid, req.argv)),
      onExited: exited.add,
    ).run(['echo', 'hi'], taps: ExecTaps.none);
    expect(r.exitCode, 0);
    await Future<void>.delayed(Duration.zero);
    expect(started, hasLength(1));
    expect(started.single.$2, ['echo', 'hi']);
    expect(exited, [started.single.$1]);
  });

  test('a child killed on timeout is reported as exited too', () async {
    final timers = FakeTimers();
    timers.started.listen((t) {
      if (t.role == ExecTimer.timeout) t.fire();
    });
    final exited = <int>[];
    final r = await Executor(
      root: tmp,
      consent: (_) async => true,
      startTimer: timers.call,
      onExited: exited.add,
    ).run(['sleep', '30'], taps: ExecTaps.none);
    expect(r.timedOut, isTrue);
    await Future<void>.delayed(Duration.zero);
    expect(exited, hasLength(1));
  });

  test('a refused command starts nothing, so reports nothing', () async {
    final log = <int>[];
    final r = await Executor(
      root: tmp,
      consent: Executor.refuseAll,
      onStarted: (pid, _) => log.add(pid),
      onExited: log.add,
    ).run(['echo', 'hi'], taps: ExecTaps.none);
    expect(r.refused, isTrue);
    expect(log, isEmpty);
  });
}
