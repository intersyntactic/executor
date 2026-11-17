/// Where a command runs. An absolute directory inside the tree is used as
/// given, not glued onto the root; one outside the tree is refused; and a
/// missing one is named as the problem, not the program.
@TestOn('!windows')
library;

import 'dart:io';

import 'package:is_executor/is_executor.dart';
import 'package:test/test.dart';

void main() {
  late Directory root;
  late Executor ex;

  setUp(() {
    root = Directory.systemTemp.createTempSync('cwd_root').absolute;
    Directory('${root.path}/sub').createSync();
    ex = Executor(root: root, consent: (_) async => true);
  });
  tearDown(() => root.deleteSync(recursive: true));

  test('an absolute directory inside the tree is used as given', () async {
    final r = await ex.run(
      ['pwd'],
      workingSubdir: '${root.path}/sub',
      taps: ExecTaps.none,
    );
    expect(r.exitCode, 0, reason: r.stderr);
    expect(
      File(r.stdout.trim()).resolveSymbolicLinksSync(),
      Directory('${root.path}/sub').resolveSymbolicLinksSync(),
    );
  });

  test('a relative directory is read from the root', () async {
    final r = await ex.run(['pwd'], workingSubdir: 'sub', taps: ExecTaps.none);
    expect(r.exitCode, 0, reason: r.stderr);
    expect(
      File(r.stdout.trim()).resolveSymbolicLinksSync(),
      Directory('${root.path}/sub').resolveSymbolicLinksSync(),
    );
  });

  test('the root given absolutely works too', () async {
    final r = await ex.run(
      ['pwd'],
      workingSubdir: root.path,
      taps: ExecTaps.none,
    );
    expect(r.exitCode, 0, reason: r.stderr);
  });

  test('an absolute directory outside the tree is refused', () async {
    final r = await ex.run(
      ['pwd'],
      workingSubdir: Directory.systemTemp.path,
      taps: ExecTaps.none,
    );
    expect(r.refused, isTrue);
    expect(r.stderr, contains('outside the working tree'));
  });

  test('a `..` out of the tree is refused', () async {
    final r = await ex.run(
      ['pwd'],
      workingSubdir: 'sub/../..',
      taps: ExecTaps.none,
    );
    expect(r.refused, isTrue);
  });

  test(
    'a missing directory is named as the problem, not the program',
    () async {
      final r = await ex.run(
        ['pwd'],
        workingSubdir: 'nope',
        taps: ExecTaps.none,
      );
      expect(r.exitCode, -1);
      expect(r.refused, isFalse);
      expect(r.stderr, contains('working directory'));
      expect(r.stderr, isNot(contains(': pwd')));
    },
  );
}
