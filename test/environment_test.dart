/// What environment a child gets: this process's whole environment, with
/// PATH led by the running Dart binary's directory and PWD the working
/// directory.
@TestOn('!windows')
library;

import 'dart:io';

import 'package:is_executor/is_executor.dart';
import 'package:test/test.dart';

void main() {
  final root = Directory.systemTemp;
  Future<Map<String, String>> envOf(Executor ex) async {
    final r = await ex.run(['/usr/bin/env'], taps: ExecTaps.none);
    expect(r.exitCode, 0);
    return {
      for (final l in r.stdout.split('\n'))
        if (l.indexOf('=') case final i when i > 0)
          l.substring(0, i): l.substring(i + 1),
    };
  }

  test('a child inherits the whole environment', () async {
    final seen = await envOf(Executor(root: root, consent: (_) async => true));
    // Set by the shell or by the executor itself, so not inherited as is.
    const setForTheChild = {'PATH', '_', 'SHLVL', 'PWD'};
    final inherited = Platform.environment.keys.where(
      (k) => !setForTheChild.contains(k),
    );
    expect(inherited, isNotEmpty);
    for (final k in inherited) {
      expect(seen[k], Platform.environment[k], reason: k);
    }
  });

  test("PWD is the working directory, not this process's", () async {
    final dir = Directory.systemTemp.createTempSync('executor_pwd_');
    addTearDown(() => dir.deleteSync(recursive: true));
    final seen = await envOf(Executor(root: dir, consent: (_) async => true));
    expect(seen['PWD'], dir.path);
  });

  test('PWD is absolute when the root is relative', () async {
    final seen = await envOf(
      Executor(root: Directory('.'), consent: (_) async => true),
    );
    expect(seen['PWD'], Directory.current.absolute.path);
  });

  test('PATH is the one childPath gives, read at each start', () async {
    var path = '/usr/bin:/bin';
    final ex = Executor(
      root: root,
      consent: (_) async => true,
      childPath: () => path,
    );
    expect((await envOf(ex))['PATH'], '/usr/bin:/bin');
    path = '/bin:/usr/bin';
    expect((await envOf(ex))['PATH'], '/bin:/usr/bin');
  });

  test("PATH is led by the running Dart binary's directory", () async {
    final exe = File(Platform.resolvedExecutable);
    // wire-ok: the executable's file name as the OS reports it
    if (exe.uri.pathSegments.last != 'dart') {
      markTestSkipped('not running under a binary named dart: ${exe.path}');
      return;
    }
    final seen = await envOf(Executor(root: root, consent: (_) async => true));
    expect(seen['PATH']!.split(':').first, exe.parent.path);
  });
}
