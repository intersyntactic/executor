/// What became of a command once it ran, and of what it started.
library;

/// How the command itself ended, as its parent saw it.
sealed class Termination {
  const Termination();

  /// As Dart reports a process's exit code: the code, or minus the signal
  /// that killed it, or -1 when it is not known.
  int get asExitCode;
}

/// It exited with [code].
final class Exited extends Termination {
  const Exited(this.code);

  final int code;

  @override
  int get asExitCode => code;
}

/// It was ended by [signal] (by number: 1 is SIGHUP, 9 SIGKILL).
final class Signalled extends Termination {
  const Signalled(this.signal);

  final int signal;

  @override
  int get asExitCode => -signal;
}

/// How it ended is not known: its doorstop was lost (killed or stopped from
/// outside), or it did not die within [Executor.killWait] of being killed.
final class TerminationUnknown extends Termination {
  const TerminationUnknown();

  @override
  int get asExitCode => -1;
}

/// What a kill of the command's process group left, as far as could be
/// seen. A look at running processes observes; it does not prove: another
/// user's process can be hidden from it.
sealed class Cleanup {
  const Cleanup();
}

/// Nothing was killed: the command ended by itself and nobody asked.
final class NotKilled extends Cleanup {
  const NotKilled();
}

/// After the kill, two looks in a row saw nothing left in the group.
final class NoneSeen extends Cleanup {
  const NoneSeen();
}

/// [stillRunning] processes in the group outlived the kill (one blocked in
/// the kernel, or one that changed user). Its doorstop goes on killing them
/// after the run has returned, until none is seen.
final class Incomplete extends Cleanup {
  const Incomplete(this.stillRunning);

  final int stillRunning;
}

/// What the kill left could not be seen, or its doorstop did not answer.
final class CleanupUnknown extends Cleanup {
  const CleanupUnknown();
}

/// What the command left running once its run was over, seen while its ids
/// were still held.
final class Leftovers {
  const Leftovers({required this.inGroup, required this.adopted});

  /// Processes still in the command's process group.
  final int inGroup;

  /// Processes the command started that left its group and were then
  /// orphaned (a daemon, say), and so came to its doorstop on Linux. Null
  /// where they cannot be seen: macOS has no way to adopt them.
  final int? adopted;

  /// Whether anything was seen left running.
  bool get any => inGroup > 0 || (adopted ?? 0) > 0;
}
