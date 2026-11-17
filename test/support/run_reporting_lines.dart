/// A run whose output a test hears line by line as it is printed, as a person
/// watching it would.
library;

import 'dart:convert';

import 'package:is_executor/is_executor.dart';
import 'package:test/test.dart';

/// [Executor.start], telling [onLine] each line of stdout and of stderr as it
/// arrives. Fails the test if the command was not started.
Future<ExecResult> runReportingLines(
  Executor executor,
  List<String> argv, {
  required void Function(String line) onLine,
  Duration? quiet,
  ExecTaps taps = ExecTaps.none,
}) async {
  final running = executor.start(argv, quiet: quiet, taps: taps);
  running.stdout.transform(const LineSplitter()).listen(onLine);
  running.stderr.transform(const LineSplitter()).listen(onLine);
  return startedResult(await running.result);
}

/// What a started command did; fails the test if it was not started.
ExecResult startedResult(ExecStart start) => switch (start) {
  ExecStarted(:final result) => result,
  ExecNotStarted(:final why) => fail('not started: $why'),
};
