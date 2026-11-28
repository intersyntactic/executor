// Prints what this host can promise for the commands an Executor starts:
// `doorstop <path>`, or `none: <reason>`. Exits 0 for a doorstop and 1 for
// none, so CI can require either.
import 'dart:io';

import 'package:is_executor/is_executor.dart';

Future<void> main() async {
  switch (await installDoorstop()) {
    case Doorstop(:final path):
      stdout.writeln('doorstop $path');
    case NoProcessGroup(:final reason):
      stdout.writeln('none: $reason');
      exitCode = 1;
  }
}
