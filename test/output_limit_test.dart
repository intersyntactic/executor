/// `start`'s `maxOutputBytes`: a command that prints past it on either
/// channel is killed with its group, and what it printed is kept up to the
/// limit on each, cut where a character ends.
@TestOn('!windows')
library;

import 'dart:async';
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
    tree = Directory.systemTemp.createTempSync('exec_limit_').absolute;
    timers = FakeTimers();
  });
  tearDown(() => tree.deleteSync(recursive: true));

  // The timeout and drain timers are fake and never fired, so a run that
  // returns at all had nothing left holding its pipes.
  Executor exec({void Function(int pid, ExecRequest request)? onStarted}) =>
      Executor(
        root: tree,
        consent: (_) async => true,
        timeout: const Duration(minutes: 1),
        startTimer: timers.call,
        onStarted: onStarted,
      );

  Future<T> soon<T>(Future<T> f, String reason) =>
      f.timeout(const Duration(seconds: 10), onTimeout: () => fail(reason));

  // Runs [script] under `sh -c` with [limit], and returns what the streams
  // carried, the result, and the command's group.
  Future<({String out, String err, ExecResult result, int group})> limited(
    String script,
    int limit,
  ) async {
    int? group;
    final running =
        exec(
          onStarted: (pid, _) {
            group = pid;
            addTearDown(() => Process.killPid(-pid, ProcessSignal.sigkill));
          },
        ).start(
          ['/bin/sh', '-c', script],
          maxOutputBytes: limit,
          taps: ExecTaps.none,
        );
    final out = running.stdout.join();
    final err = running.stderr.join();
    final result = startedResult(
      await soon(running.result, 'something it started outlived the kill'),
    );
    return (out: await out, err: await err, result: result, group: group!);
  }

  test('within the limit, nothing changes', () async {
    final r = await limited('printf abcde; printf fgh >&2', 5);
    expect(r.result.whyKilled, isNull);
    expect(r.result.exitCode, 0);
    expect((r.out, r.err), ('abcde', 'fgh'));
  });

  test('past it on stdout, the run and what it started are killed, and the '
      'output is kept to the limit', () async {
    final r = await limited('sleep 30 & printf abcdefgh; wait', 5);
    expect(
      r.result.whyKilled,
      isA<KilledForOutput>()
          .having((k) => k.channel, 'channel', OutputChannel.stdout)
          .having((k) => k.limit, 'limit', 5),
    );
    expect(r.result.exitCode, -1);
    expect(r.result.stdout, 'abcde');
    expect(r.out, 'abcde', reason: 'the stream carries what was kept');
    expect(
      r.result.forModel,
      startsWith(
        'printed more than 5 bytes on stdout, so the rest was cut and it was '
        'killed; no exit code',
      ),
    );
    expect(liveIn({r.group}), isEmpty);
  });

  test(
    'past it on stderr says stderr, and stdout keeps its own room',
    () async {
      final r = await limited('printf abc; printf 0123456789 >&2; sleep 30', 4);
      expect(
        r.result.whyKilled,
        isA<KilledForOutput>().having(
          (k) => k.channel,
          'channel',
          OutputChannel.stderr,
        ),
      );
      expect((r.result.stdout, r.result.stderr), ('abc', '0123'));
    },
  );

  test('the cut falls where a character ends', () async {
    // "aé" is 3 bytes; a limit of 2 would cut é in half, so only "a" is kept.
    final r = await limited(r"printf 'a\303\251b'; sleep 30", 2);
    expect(r.result.stdout, 'a');
    expect(r.out, 'a');
  });

  test('a character cut across two writes, within the limit, comes through '
      'whole', () async {
    final r = await limited(
      r"printf 'a\360\237'; sleep 0.2; printf '\230\200'",
      5,
    );
    expect(r.result.whyKilled, isNull);
    expect(r.result.stdout, 'a😀');
    expect(r.out, 'a😀');
  });

  test(
    'a character cut across two writes, at the limit, is dropped whole',
    () async {
      // "a😀" is 5 bytes; a limit of 4 keeps "a" only.
      final r = await limited(
        r"printf 'a\360\237'; sleep 0.2; printf '\230\200'; sleep 30",
        4,
      );
      expect(r.result.whyKilled, isA<KilledForOutput>());
      expect(r.result.stdout, 'a');
      expect(r.out, 'a');
    },
  );

  test('output that is not UTF-8 is still counted and kept', () async {
    final r = await limited(r"printf '\377\376abc'", 10);
    expect(r.result.whyKilled, isNull);
    expect(r.result.stdout, '��abc');
  });

  test('past it once the command has exited, what it left is killed and its '
      'exit code stands', () async {
    final r = await limited(
      '(sleep 0.3; printf abcdefgh; sleep 30) & exit 4',
      5,
    );
    expect(r.result.whyKilled, isA<KilledForOutput>());
    expect(r.result.exitCode, 4);
    expect(r.result.stdout, 'abcde');
    expect(r.result.forModel, contains('; exit 4'));
    expect(liveIn({r.group}), isEmpty);
  });

  test('a limit of 0 kills on the first byte', () async {
    final r = await limited('printf x; sleep 30', 0);
    expect(r.result.whyKilled, isA<KilledForOutput>());
    expect(r.result.stdout, '');
  });

  test('a negative limit is refused before anything runs', () {
    expect(
      () => exec().start(['true'], maxOutputBytes: -1, taps: ExecTaps.none),
      throwsRangeError,
    );
  });
}
