/// A process started in a group of its own can be killed with everything it
/// started, and a program that is not there is refused as Process.start
/// refuses it.
@TestOn('!windows')
library;

import 'dart:convert';
import 'dart:io';

import 'package:is_executor/is_executor.dart';
import 'package:test/test.dart';

bool _alive(int pid) => Process.runSync('kill', ['-0', '$pid']).exitCode == 0;

void main() {
  test('kill reaches what the process started', () async {
    final g = await startInOwnGroup('/bin/sh', [
      '-c',
      r'sleep 300 & echo $!; wait',
    ]);
    final child = int.parse(
      await g.process.stdout
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .first,
    );
    addTearDown(() => Process.killPid(child, ProcessSignal.sigkill));
    expect(_alive(child), isTrue);

    g.kill(ProcessSignal.sigkill);
    await g.process.exitCode;
    final deadline = DateTime.now().add(const Duration(seconds: 5));
    while (_alive(child) && DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
    expect(_alive(child), isFalse);
  });

  test('a program that is not there throws, as Process.start does', () {
    expect(
      startInOwnGroup('definitely-not-a-real-program-xyz', []),
      throwsA(isA<ProcessException>()),
    );
  });
}
