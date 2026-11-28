/// Running programs: consent before each run, the working directory confined
/// to a tree, and every command in a process group of its own so a timeout
/// kills everything it started, under a doorstop that holds the command's
/// ids and alone signals them.
library;

export 'src/doorstop.dart'
    show Doorstop, NoProcessGroup, ProcessContainment, installDoorstop;
export 'src/execution.dart';
export 'src/outcome.dart';
