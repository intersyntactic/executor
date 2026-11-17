/// [Executor.start]: what a command prints, as it prints it, and a command
/// that was never started told apart from one that ran and failed.
@TestOn('!windows')
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:is_executor/is_executor.dart';
import 'package:test/test.dart';

import 'support/run_reporting_lines.dart';

void main() {
  late Directory tree;
  setUp(
    () => tree = Directory.systemTemp.createTempSync('exec_start_').absolute,
  );
  tearDown(() => tree.deleteSync(recursive: true));

  Executor exec({ConsentGate? consent}) =>
      Executor(root: tree, consent: consent ?? (_) async => true);

  test(
    'the streams put together are the result, a character cut across '
    'two chunks comes through whole, and the last line needs no newline',
    () async {
      // The emoji is split across two writes, with a pause between them.
      final running = exec().start([
        '/bin/sh',
        '-c',
        r"printf 'a\n\n\360\237'; sleep 0.3; printf '\230\200 b\r';"
            r" printf 'oops' >&2; printf 'Password: '",
      ], taps: ExecTaps.none);
      final outLines = running.stdout.transform(const LineSplitter()).toList();
      final errLines = running.stderr.transform(const LineSplitter()).toList();
      final r = startedResult(await running.result);
      expect(r.stdout, 'a\n\n😀 b\rPassword: ');
      expect(r.stderr, 'oops');
      expect(await outLines, ['a', '', '😀 b', 'Password: ']);
      expect(await errLines, ['oops']);
    },
  );

  test('a run nobody listens to still finishes', () async {
    final running = exec().start(['echo', 'hi'], taps: ExecTaps.none);
    expect(startedResult(await running.result).stdout, 'hi\n');
  });

  test('input is sent to the command, then stdin is closed', () async {
    final running = exec().start(
      ['/bin/sh', '-c', 'cat; echo end'],
      input: 'line 1\nline 2\n',
      taps: ExecTaps.none,
    );
    final r = startedResult(await running.result);
    expect(r.stdout, 'line 1\nline 2\nend\n');
  });

  test('runWithInput sends input as start does', () async {
    final r = await exec().runWithInput(
      ['cat'],
      input: 'héllo',
      taps: ExecTaps.none,
    );
    expect(r.exitCode, 0);
    expect(r.stdout, 'héllo');
  });

  group('a command not started', () {
    // [argv] as [start] reports it, with its streams, which must close at
    // once and empty.
    Future<ExecNotStarted> notStarted(
      List<String> argv, {
      ConsentGate? consent,
      String? workingSubdir,
    }) async {
      final running = exec(consent: consent)
          .start(argv, workingSubdir: workingSubdir, taps: ExecTaps.none);
      expect(await running.stdout.toList(), isEmpty);
      expect(await running.stderr.toList(), isEmpty);
      return switch (await running.result) {
        ExecStarted() => fail('it started'),
        final ExecNotStarted n => n,
      };
    }

    test('an empty argv', () async {
      expect((await notStarted([])).why, 'no command given');
      expect((await notStarted(['  '])).why, 'no command given');
    });

    test('a refusal, and the gate saw exactly what would run', () async {
      final asked = <ExecRequest>[];
      final n = await notStarted(
        ['echo', 'hi'],
        consent: (req) async {
          asked.add(req);
          return false;
        },
      );
      expect(n.why, 'this command was not approved');
      expect(asked.single.argv, ['echo', 'hi']);
      expect(asked.single.cwd.path, tree.path);
    });

    test('the default gate refuses everything', () async {
      final n = await notStarted(['echo', 'hi'], consent: Executor.refuseAll);
      expect(n.why, 'this command was not approved');
    });

    test('a missing program, before the gate is asked', () async {
      var asked = false;
      final n = await notStarted([
        'definitely-not-a-real-program-xyz',
      ], consent: (_) async => asked = true);
      expect(n.why, contains('no program named'));
      expect(asked, isFalse, reason: 'nobody is asked about what cannot run');
    });

    test('a missing relative program is looked for from the folder', () async {
      final n = await notStarted(['./nope']);
      expect(n.why, contains('no file ./nope from the working directory'));
    });

    test('a folder outside the tree', () async {
      final n = await notStarted(['pwd'], workingSubdir: '..');
      expect(n.why, contains('outside the working tree'));
    });

    test('run reports each as an exit code and refused', () async {
      Future<(int, bool)> asRun(
        List<String> argv, {
        ConsentGate? consent,
      }) async {
        final r = await exec(consent: consent).run(argv, taps: ExecTaps.none);
        return (r.exitCode, r.refused);
      }

      expect(await asRun([]), (-1, true));
      expect(await asRun(['echo'], consent: Executor.refuseAll), (-1, true));
      expect(await asRun(['definitely-not-a-real-program-xyz']), (127, false));
    });
  });

  test('a refused result tells the model why', () async {
    final r = await exec(consent: Executor.refuseAll)
        .run(['echo', 'hi'], taps: ExecTaps.none);
    expect(r.forModel, 'refused: this command was not approved');
  });

  test(
    'forModel shows stderr even on success, and says when there was none',
    () async {
      final r = await exec().run([
        '/bin/sh',
        '-c',
        'echo warn >&2',
      ], taps: ExecTaps.none);
      expect(r.forModel, 'exit 0\n--- stderr ---\nwarn');
      final quiet = await exec().run(['true'], taps: ExecTaps.none);
      expect(quiet.forModel, 'exit 0 (no output)');
    },
  );

  test('two runs at once keep their output apart', () async {
    final results = await Future.wait([
      for (var i = 0; i < 4; i++)
        exec().run([
          '/bin/sh',
          '-c',
          'echo $i; sleep 0.1; echo $i',
        ], taps: ExecTaps.none),
    ]);
    for (var i = 0; i < 4; i++) {
      expect(results[i].stdout, '$i\n$i\n');
    }
  });
}
