// A host for tests that kill the host: starts its arguments as a command
// under an Executor, prints `pid <n>` once it runs, passes on what the
// command prints, and waits for it.
import 'dart:async';
import 'dart:io';

import 'package:is_executor/is_executor.dart';

Future<void> main(List<String> argv) async {
  final running =
      Executor(
        root: Directory.current,
        consent: (_) async => true,
        timeout: const Duration(minutes: 5),
      ).start(
        argv,
        taps: ExecTaps(
          onProcess: (pid, _, ended) {
            if (!ended) stdout.writeln('pid $pid');
          },
        ),
      );
  unawaited(running.stdout.forEach(stdout.write));
  unawaited(running.stderr.drain<void>());
  await running.result;
}
