/// What the doorstop adds: a command's end told as it was (an exit code or
/// a signal), a kill's outcome said, the command killed when its host dies,
/// and an install that refuses rather than runs something it cannot.
@TestOn('!windows')
library;

import 'dart:async';
import 'dart:convert';
import 'dart:ffi' show Abi;
import 'dart:io';

import 'package:is_executor/is_executor.dart';
import 'package:is_executor/src/doorstop.dart'
    show DoorstopSays, installDoorstopIn;
import 'package:test/test.dart';

import 'support/run_reporting_lines.dart';

bool _alive(int pid) => Process.runSync('kill', ['-0', '$pid']).exitCode == 0;

Future<void> _untilDead(int pid) async {
  final deadline = DateTime.now().add(const Duration(seconds: 10));
  while (_alive(pid) && DateTime.now().isBefore(deadline)) {
    await Future<void>.delayed(const Duration(milliseconds: 50));
  }
}

void main() {
  late Directory tree;
  setUp(() => tree = Directory.systemTemp.createTempSync('doorstop_').absolute);
  tearDown(() => tree.deleteSync(recursive: true));

  Executor executor() => Executor(root: tree, consent: (_) async => true);

  test('an exit code is an Exited termination', () async {
    final r = startedResult(
      await executor().start([
        '/bin/sh',
        '-c',
        'exit 3',
      ], taps: ExecTaps.none).result,
    );
    expect(r.exitCode, 3);
    expect(r.termination, isA<Exited>().having((e) => e.code, 'code', 3));
  });

  test('death by SIGHUP is a signal, not "no exit code"', () async {
    final r = startedResult(
      await executor().start([
        '/bin/sh',
        '-c',
        r'kill -HUP $$',
      ], taps: ExecTaps.none).result,
    );
    // Dart's own report would be -1, the same as "no exit code".
    expect(r.exitCode, -1);
    expect(
      r.termination,
      isA<Signalled>().having((s) => s.signal, 'signal', 1),
    );
    expect(r.forModel, startsWith('ended by signal 1'));
  });

  test('a kill says what it left: nothing, as far as could be seen', () async {
    final running = executor().start([
      '/bin/sh',
      '-c',
      'sleep 300 & sleep 300 & echo up; wait',
    ], taps: ExecTaps.none);
    await running.stdout.transform(const LineSplitter()).first;
    unawaited(running.stderr.drain<void>());
    unawaited(running.kill());
    final r = startedResult(await running.result);
    expect(r.whyKilled, isA<KilledOnRequest>());
    expect(r.cleanup, isA<NoneSeen>());
    expect(r.leftovers?.inGroup, 0);
  });

  group('the host dying kills the command', () {
    // Starts [command] under a host in a process group of its own (perl's
    // setpgrp: test-only), and returns the host, the command's pid, and a
    // way to wait for a line the host printed.
    Future<(Process, int, Future<String> Function(String))> hostOf(
      List<String> command,
    ) async {
      final host = await Process.start('perl', [
        '-e',
        r'setpgrp(0, 0); exec @ARGV',
        Platform.resolvedExecutable,
        'test/support/host.dart',
        ...command,
      ]);
      unawaited(host.stderr.drain<void>());
      final seen = <String>[];
      final more = StreamController<void>.broadcast();
      host.stdout
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .listen((l) {
            seen.add(l);
            more.add(null);
          });
      Future<String> line(String prefix) async {
        final deadline = DateTime.now().add(const Duration(seconds: 60));
        while (true) {
          for (final l in seen) {
            if (l.startsWith(prefix)) return l.substring(prefix.length);
          }
          final left = deadline.difference(DateTime.now());
          if (left.isNegative) fail('the host never printed "$prefix"');
          await more.stream.first.timeout(left, onTimeout: () {});
        }
      }

      final pid = int.parse(await line('pid '));
      addTearDown(() => Process.killPid(pid, ProcessSignal.sigkill));
      return (host, pid, line);
    }

    test('killed outright (SIGKILL)', () async {
      final (host, pid, _) = await hostOf(['sleep', '300']);
      expect(_alive(pid), isTrue);
      host.kill(ProcessSignal.sigkill);
      await host.exitCode;
      await _untilDead(pid);
      expect(_alive(pid), isFalse);
    });

    test("Ctrl-C to the host's whole group", () async {
      // The signal reaches the doorstop's group too, were it in the host's:
      // it is not, so it lives to see the host go and kills the command.
      final (host, pid, _) = await hostOf(['sleep', '300']);
      Process.killPid(-host.pid, ProcessSignal.sigint);
      await host.exitCode;
      await _untilDead(pid);
      expect(_alive(pid), isFalse);
    });

    test('and on Linux, a daemon it started that left its group', () async {
      // A command that starts a daemon (it leaves the group and session,
      // and keeps running) and then runs on itself.
      final (host, _, line) = await hostOf([
        'perl',
        '-MPOSIX',
        '-e',
        r'$| = 1; if (my $p = fork) { print "daemon $p\n"; sleep 300; exit } '
            r'POSIX::setsid(); open STDOUT, ">/dev/null"; '
            r'exec "sleep", "300"',
      ]);
      final daemon = int.parse(await line('daemon '));
      addTearDown(() => Process.killPid(daemon, ProcessSignal.sigkill));
      expect(_alive(daemon), isTrue);
      host.kill(ProcessSignal.sigkill);
      await host.exitCode;
      await _untilDead(daemon);
      expect(_alive(daemon), isFalse);
    }, testOn: 'linux');
  });

  group('installing', () {
    test('a platform with no build is refused, not run', () async {
      final c = await installDoorstopIn(null, Abi.linuxRiscv64);
      expect(c, isA<NoProcessGroup>());
    });

    test('a cache that cannot be written is refused', () async {
      final notAFolder = File('${tree.path}/file')..writeAsStringSync('x');
      final c = await installDoorstopIn(
        Directory('${notAFolder.path}/cache'),
        Abi.current(),
      );
      expect(c, isA<NoProcessGroup>());
    });

    test('an install runs, and a second reuses the file', () async {
      final cache = Directory('${tree.path}/cache');
      final first = await installDoorstopIn(cache, Abi.current());
      final second = await installDoorstopIn(cache, Abi.current());
      expect(first, isA<Doorstop>());
      expect((second as Doorstop).path, (first as Doorstop).path);
      expect(cache.listSync(), hasLength(1));
    });
  });

  group('what the doorstop says', () {
    test('each line it writes is read', () {
      expect(DoorstopSays.parse('started 12 subreaper 1'), isNotNull);
      expect(DoorstopSays.parse('running'), isNotNull);
      expect(DoorstopSays.parse('execfailed 2'), isNotNull);
      expect(DoorstopSays.parse('exited 0'), isNotNull);
      expect(DoorstopSays.parse('signalled 9'), isNotNull);
      expect(DoorstopSays.parse('none-seen'), isNotNull);
      expect(DoorstopSays.parse('incomplete 3'), isNotNull);
      expect(DoorstopSays.parse('unknown'), isNotNull);
      expect(DoorstopSays.parse('leftovers group 1 adopted -1'), isNotNull);
      expect(DoorstopSays.parse('leftovers unknown'), isNotNull);
    });

    test('anything else is not', () {
      for (final line in [
        '',
        'started x subreaper 1',
        'started 12 subreaper 2',
        'exited',
        'exited 1 2',
        'leftovers group 1',
        'Started 12 subreaper 1',
      ]) {
        expect(DoorstopSays.parse(line), isNull, reason: line);
      }
    });
  });
}
