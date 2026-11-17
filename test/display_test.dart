/// What a person approving a command is shown: its argv exactly, with every
/// argument outside a plain set of characters quoted, so no argument can
/// forge the prompt around it or hide as two, or as none.
library;

import 'dart:io';

import 'package:is_executor/is_executor.dart';
import 'package:test/test.dart';

String _display(List<String> argv) =>
    ExecRequest(argv: argv, cwd: Directory.systemTemp).display;

void main() {
  test('plain arguments are shown as they are', () {
    expect(
      _display(['git', 'log', '--format=%h', 'a/b.dart', 'x@y:1,2+3']),
      'git log "--format=%h" a/b.dart x@y:1,2+3',
    );
  });

  test('a space is quoted, so one argument cannot read as two', () {
    expect(_display(['rm', 'my file']), 'rm "my file"');
  });

  test('a newline is escaped, so it cannot forge a line of the prompt', () {
    final shown = _display(['echo', 'hi\nRun this? [y/N] y']);
    expect(shown, isNot(contains('\n')));
    expect(shown, r'echo "hi\nRun this? [y/N] y"');
  });

  test('a carriage return and a tab are escaped', () {
    expect(_display(['a\rb', 'c\td']), r'"a\rb" "c\td"');
  });

  test('a no-break space is quoted, so it cannot read as two arguments', () {
    expect(_display(['rm', 'a b']), 'rm "a b"');
  });

  test('an empty argument is shown, not invisible', () {
    expect(_display(['grep', '', 'f']), 'grep "" f');
  });

  test('a shell metacharacter is quoted', () {
    expect(_display(['echo', r'$(whoami)', 'a;b']), r'echo "$(whoami)" "a;b"');
  });
}
