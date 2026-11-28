/// The doorstop: the small native program every command starts under, as its
/// parent. It holds the command unreaped after it exits, so the command's pid
/// and process group cannot be given to another process, and it is the only
/// process that signals them. This library never signals a command; it asks
/// the doorstop, over a unix socket (native/doorstop.c has the protocol).
library;

import 'dart:async';
import 'dart:convert';
import 'dart:ffi' show Abi;
import 'dart:io';

import 'doorstop_bytes.g.dart';
import 'outcome.dart';

/// What this host can promise about the commands an [Executor] starts.
sealed class ProcessContainment {
  const ProcessContainment();
}

/// Each command starts under the doorstop at [path]: in a process group of
/// its own that a kill reaches whole, held so its ids stay its own, and
/// killed with what it started if this process dies. When [adoptsOrphans]
/// (Linux, where nothing denies it), that last reaches even a process that
/// left the group (a daemon); otherwise (macOS, or a sandbox that refuses
/// it) the group only.
final class Doorstop extends ProcessContainment {
  const Doorstop._(this.path, {required this.adoptsOrphans});

  final String path;

  /// Whether the doorstop can be the parent of orphans the command leaves,
  /// as the doorstop found when it was installed.
  final bool adoptsOrphans;
}

/// No command can be run here as the leader of a process group of its own,
/// so a timeout could not kill what it starts, for [reason].
final class NoProcessGroup extends ProcessContainment {
  const NoProcessGroup(this.reason);

  final String reason;
}

Doorstop? _installed;

/// Puts this platform's doorstop where it can be run, once per process (and
/// again if it has gone: an OS cleaner can remove a temp file under a
/// long-lived process). A refusal is not kept, so one that a moment fixes
/// is asked again.
Future<ProcessContainment> installDoorstop() async {
  final done = _installed;
  if (done != null && await File(done.path).exists()) return done;
  final c = await installDoorstopIn(Directory.systemTemp, Abi.current());
  if (c case final Doorstop d) _installed = d;
  return c;
}

/// Writes the doorstop built for [abi] into a new folder of this process's
/// own inside [root], and runs it once to see it can be run there (a folder
/// mounted noexec cannot) and what it can do.
///
/// A folder of its own, made by mkdtemp: 0700, never one that was there
/// before, so nobody else can have made it or can write in it. In the system
/// temp folder, whose parent is sticky (`/tmp`) or the user's own (macOS),
/// nobody else can rename it either. That is why there is no shared cache: a
/// file kept at a known path is one someone else may be able to replace
/// between its check and its run, and a check of who owns a path cannot be
/// made from Dart.
Future<ProcessContainment> installDoorstopIn(Directory root, Abi abi) async {
  if (Platform.isWindows) {
    return const NoProcessGroup('Windows has no process groups to run in');
  }
  final build = doorstopBuilds[abi];
  if (build == null) return NoProcessGroup('no doorstop is built for $abi');
  try {
    final folder = await root.createTemp('is_executor_');
    final file = File('${folder.path}/doorstop');
    await file.writeAsBytes(base64.decode(build.base64), flush: true);
    // By its full path: an app opened from Finder can have no /bin on PATH.
    final chmod = await Process.run('/bin/chmod', ['755', file.path]);
    if (chmod.exitCode != 0) {
      return NoProcessGroup('could not make ${file.path} runnable');
    }
    final probe = await Process.run(file.path, ['--probe']);
    if (probe.exitCode != 0) {
      return NoProcessGroup(
        'the doorstop at ${file.path} would not run (exit ${probe.exitCode})',
      );
    }
    // cast-ok: Process.run decodes stdout to a String
    final said = (probe.stdout as String).trim();
    // wire-ok: the probe's one line, read once here
    return Doorstop._(file.path, adoptsOrphans: said == 'subreaper 1');
  } on FileSystemException catch (e) {
    return NoProcessGroup('could not install the doorstop: ${e.message}');
  } on ProcessException catch (e) {
    return NoProcessGroup('the doorstop would not run: ${e.message}');
  }
}

/// What the doorstop says, one line each.
sealed class DoorstopSays {
  const DoorstopSays();

  /// [line] as the doorstop wrote it, or null for one it does not write.
  static DoorstopSays? parse(String line) => switch (line.split(' ')) {
    // wire-ok: the doorstop's protocol words, read once here
    ['started', final pid, 'subreaper', final s] => switch ((
      int.tryParse(pid),
      s,
    )) {
      (final p?, '0') => DoorstopStarted(p, subreaper: false),
      (final p?, '1') => DoorstopStarted(p, subreaper: true),
      _ => null,
    },
    ['running'] => const DoorstopExecRan(),
    ['execfailed', final e] => _withInt(e, DoorstopExecFailed.new),
    ['exited', final c] => _withInt(c, (c) => DoorstopEnded(Exited(c))),
    ['signalled', final s] => _withInt(s, (s) => DoorstopEnded(Signalled(s))),
    ['none-seen'] => const DoorstopKillAnswer(NoneSeen()),
    ['incomplete', final n] => _withInt(
      n,
      (n) => DoorstopKillAnswer(Incomplete(n)),
    ),
    ['unknown'] => const DoorstopKillAnswer(CleanupUnknown()),
    ['leftovers', 'unknown'] => const DoorstopLeftovers(null),
    ['leftovers', 'group', final g, 'adopted', final a] => switch ((
      int.tryParse(g),
      int.tryParse(a),
    )) {
      (final g?, final a?) => DoorstopLeftovers(
        Leftovers(inGroup: g, adopted: a < 0 ? null : a),
      ),
      _ => null,
    },
    _ => null,
  };

  static DoorstopSays? _withInt(String s, DoorstopSays Function(int) f) {
    final n = int.tryParse(s);
    return n == null ? null : f(n);
  }
}

/// The command was forked as [pid], and orphans will come to the doorstop
/// ([subreaper], Linux only).
final class DoorstopStarted extends DoorstopSays {
  const DoorstopStarted(this.pid, {required this.subreaper});

  final int pid;
  final bool subreaper;
}

/// How the exec went: [DoorstopExecRan] or [DoorstopExecFailed].
sealed class DoorstopExec extends DoorstopSays {
  const DoorstopExec();
}

/// The exec succeeded: the command is running.
final class DoorstopExecRan extends DoorstopExec {
  const DoorstopExecRan();
}

/// The exec failed with [errno].
final class DoorstopExecFailed extends DoorstopExec {
  const DoorstopExecFailed(this.errno);

  final int errno;
}

/// The command ended, [how]. Read without reaping it.
final class DoorstopEnded extends DoorstopSays {
  const DoorstopEnded(this.how);

  final Termination how;
}

/// What a kill left.
final class DoorstopKillAnswer extends DoorstopSays {
  const DoorstopKillAnswer(this.cleanup);

  final Cleanup cleanup;
}

/// What is still running; null when it could not be seen.
final class DoorstopLeftovers extends DoorstopSays {
  const DoorstopLeftovers(this.leftovers);

  final Leftovers? leftovers;
}

/// What this library says to the doorstop.
enum _ToDoorstop { kill, leftovers, release, abandon }

/// One run's connection to its doorstop.
class DoorstopLink {
  DoorstopLink(this._socket) {
    _socket
        .cast<List<int>>()
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen(
          _heard,
          onDone: _closed,
          onError: (Object _) => _closed(),
          cancelOnError: true,
        );
    // A write to a doorstop that has just died fails here, not where it was
    // written: heard, so it is a lost doorstop and not an uncaught error.
    unawaited(
      _socket.done.then<void>((_) {}, onError: (Object _) => _closed()),
    );
  }

  final Socket _socket;

  /// The command's pid, and whether orphans will be adopted.
  final started = Completer<DoorstopStarted>();

  /// The exec, either way.
  final exec = Completer<DoorstopExec>();

  /// How the command ended.
  final ended = Completer<Termination>();

  /// The doorstop went away while this run still needed it.
  final lost = Completer<void>();

  Completer<Cleanup>? _killAnswer;
  Completer<Leftovers?>? _leftoversAnswer;
  var _letGo = false;

  void _heard(String line) {
    switch (DoorstopSays.parse(line)) {
      case final DoorstopStarted s:
        if (!started.isCompleted) started.complete(s);
      case final DoorstopExec e:
        if (!exec.isCompleted) exec.complete(e);
      case DoorstopEnded(:final how):
        if (!ended.isCompleted) ended.complete(how);
      case DoorstopKillAnswer(:final cleanup):
        _killAnswer?.complete(cleanup);
        _killAnswer = null;
      case DoorstopLeftovers(:final leftovers):
        _leftoversAnswer?.complete(leftovers);
        _leftoversAnswer = null;
      case null:
      // A line it does not write: nothing to act on.
    }
  }

  void _closed() {
    if (!_letGo && !lost.isCompleted) lost.complete();
    _killAnswer?.complete(const CleanupUnknown());
    _killAnswer = null;
    _leftoversAnswer?.complete(null);
    _leftoversAnswer = null;
  }

  void _say(_ToDoorstop what) {
    if (lost.isCompleted || _letGo) return;
    try {
      _socket.write('${what.name}\n');
    } on SocketException {
      _closed();
    }
  }

  /// Kills the command's process group; a kill already asked for is joined.
  Future<Cleanup> kill() {
    if (lost.isCompleted || _letGo) return Future.value(const CleanupUnknown());
    final asked = _killAnswer;
    if (asked != null) return asked.future;
    final answer = _killAnswer = Completer<Cleanup>();
    _say(_ToDoorstop.kill);
    return answer.future;
  }

  /// What is still running.
  Future<Leftovers?> leftovers() {
    if (lost.isCompleted || _letGo) return Future.value(null);
    final asked = _leftoversAnswer;
    if (asked != null) return asked.future;
    final answer = _leftoversAnswer = Completer<Leftovers?>();
    _say(_ToDoorstop.leftovers);
    return answer.future;
  }

  /// Lets the doorstop reap the command and exit.
  void release() => _letGoWith(_ToDoorstop.release);

  /// Stops waiting: the doorstop goes on killing the group until none is
  /// seen, then exits.
  void abandon() => _letGoWith(_ToDoorstop.abandon);

  void _letGoWith(_ToDoorstop what) {
    _say(what);
    _letGo = true;
    unawaited(_socket.close().catchError((Object _) {}));
  }
}
