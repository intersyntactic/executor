/// Running things, which an agent that builds software has to do.
///
/// The obvious gate is a list of verb substrings (`rm `, `git push`, `> `,
/// `curl `) refused unless a flag allows them. #94 says exactly why that
/// shape is worse than nothing:
/// "real irreversibility is contextual: `bash cat` can leak secrets, `python`
/// can mutate the filesystem, `git diff` can expose private data, `curl` can
/// exfiltrate, and a read-only command can become writeful through shell
/// expansion or aliases. Same user id is not same safety envelope." A
/// substring list is defeated by `eval`, an alias, a heredoc, `$(...)`, and by
/// any verb nobody thought of.
///
/// So this file contains NO verb list, and nothing here decides whether a
/// command is safe. It cannot: safety is contextual and the context lives with
/// the person driving. What it does is make the decision EXPLICIT and put it
/// somewhere a human or a policy can reach — [ConsentGate]. The gate defaults
/// to refusing everything.
///
/// ARGV, NOT A COMMAND STRING. `Process.run('dart', ['test'])` spawns no shell:
/// no quoting, no globbing, no metacharacters, nothing to escape. The tool's
/// schema therefore takes a LIST, and the model cannot express a pipeline by
/// accident. A shell is a separate, named capability.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data' show BytesBuilder;

import 'package:is_path_confinement/is_path_confinement.dart';

/// The decision this library refuses to make for you.
///
/// Returns true to allow. Called once per invocation, with the fully resolved
/// argv and working directory — never with a string the caller still has to
/// parse, because parsing is where a gate stops matching what will run.
///
/// The caller supplies this. A CLI can prompt; a test can allow-list; a
/// service can consult a policy. The point is that the decision has an owner
/// and a place, which a verb list does not.
typedef ConsentGate = Future<bool> Function(ExecRequest request);

/// Exactly what would run.
class ExecRequest {
  final List<String> argv;
  final Directory cwd;

  /// There is ONE description of a command here, and it is [argv]: what
  /// [Executor.run] executes is what `display` shows a person. A second
  /// description (a script beside the argv) could disagree with the first;
  /// with no second description there is nothing to disagree.
  const ExecRequest({required this.argv, required this.cwd});

  /// For a human being asked to approve it, and for a gate deciding without
  /// one. Renders [argv], the program and arguments exactly as they are
  /// executed, never a parallel description of them. Input that
  /// [Executor.runWithInput] writes to the command's stdin is not shown.
  ///
  /// Quoting is an ALLOW-list of plain characters, not a search for a space:
  /// the sink is a terminal that also acts on \n, \r, \t and NBSP. Quoted only
  /// for a space, a token carrying a newline would render unquoted and could
  /// forge this prompt's own `[y/N]` line, an NBSP would read as two
  /// arguments, and an empty argument would be invisible. Anything outside
  /// the plain set is escaped.
  String get display => argv.map(_quote).join(' ');

  static final RegExp _plain = RegExp(r'^[A-Za-z0-9._/:=@,+-]+$');

  static String _quote(String a) => _plain.hasMatch(a) ? a : jsonEncode(a);

  @override
  String toString() => display;
}

/// What a command did.
class ExecResult {
  final int exitCode;
  final String stdout;
  final String stderr;

  /// The command was not started because it was refused, and [stderr] says
  /// why.
  final bool refused;
  final bool timedOut;

  /// Set when the command was killed for printing nothing for this long
  /// (`run`'s `quiet`); null otherwise.
  final Duration? silentFor;

  const ExecResult({
    required this.exitCode,
    required this.stdout,
    required this.stderr,
    this.refused = false,
    this.timedOut = false,
    this.silentFor,
  });

  /// What the model is told.
  ///
  /// stderr is INCLUDED even on success, and the exit code is always stated.
  /// A command that printed a warning and succeeded, and one that printed the
  /// same text and failed, are different events; a transcript that shows only
  /// stdout makes them identical. This project has a name for that shape —
  /// exit 0 is not a measurement.
  String get forModel {
    if (refused) return 'refused: $stderr';
    final b = StringBuffer(switch ((timedOut, silentFor)) {
      (_, final quiet?) =>
        'printed nothing for ${quiet.inSeconds}s and was killed; no exit code',
      (true, null) => 'timed out and was killed; no exit code',
      (false, null) => 'exit $exitCode',
    });
    if (stdout.trim().isNotEmpty)
      b.write('\n--- stdout ---\n${stdout.trimRight()}');
    if (stderr.trim().isNotEmpty)
      b.write('\n--- stderr ---\n${stderr.trimRight()}');
    if (stdout.trim().isEmpty && stderr.trim().isEmpty) b.write(' (no output)');
    return b.toString();
  }
}

/// What became of a command [Executor.start] was asked to run: it
/// [ExecStarted], or it was [ExecNotStarted] and why. The two are apart, so a
/// command that never started can never read as one that ran and failed.
sealed class ExecStart {
  const ExecStart();
}

/// The command started, and [result] is what it did. Its
/// [ExecResult.refused] is false: a command refused was not started.
final class ExecStarted extends ExecStart {
  const ExecStarted(this.result);

  final ExecResult result;
}

/// The command was not started, because [why], which is said for whoever
/// asked to run it to act on.
///
/// Its cases are this library's own, for [Executor.run] to give each its own
/// exit code and [ExecResult.refused]; a caller of [Executor.start] has only
/// [why] to act on.
sealed class ExecNotStarted extends ExecStart {
  const ExecNotStarted();

  String get why;
}

/// No program was named: the argv was empty, or its first element blank.
final class _NoCommand extends ExecNotStarted {
  const _NoCommand();

  @override
  String get why => 'no command given';
}

/// This host can start no command as the leader of a process group of its
/// own, so a timeout could not kill what the command starts.
final class _NoProcessGroup extends ExecNotStarted {
  const _NoProcessGroup();

  @override
  String get why =>
      'not run: this host has neither setsid nor perl, so the command could '
      'not be put in a process group of its own, and a timeout could not kill '
      'what it starts';
}

/// The working directory, [folder] as it was given, resolves outside the
/// tree: by an absolute path, a `..`, or a symbolic link.
final class _OutsideTree extends ExecNotStarted {
  const _OutsideTree(this.folder);

  final String folder;

  @override
  String get why => '$folder resolves outside the working tree';
}

/// The working directory, at [path], does not exist.
final class _NoSuchFolder extends ExecNotStarted {
  const _NoSuchFolder(this.path);

  final String path;

  @override
  String get why => 'the working directory $path does not exist';
}

/// No file is there for [program]: none on the PATH the command gets when it
/// is a bare name, and none from its working directory when it has a `/`.
final class _NoSuchProgram extends ExecNotStarted {
  const _NoSuchProgram(this.program);

  final String program;

  @override
  String get why => program.contains('/')
      ? 'there is no file $program from the working directory'
      : 'no program named $program is on the PATH';
}

/// The [ConsentGate] said no.
final class _NotApproved extends ExecNotStarted {
  const _NotApproved();

  @override
  String get why => 'this command was not approved';
}

/// The operating system would not start it, for [message].
final class _CouldNotStart extends ExecNotStarted {
  const _CouldNotStart(this.message);

  final String message;

  @override
  String get why => message;
}

/// The PATH a child gets. Everything else in its environment is this
/// process's (RULINGS.md, "No sandbox").
///
/// PATH is led by the directory of the Dart binary running this process,
/// when it is one, so a child runs the same SDK as this process rather than
/// Flutter's `dart` wrapper script, which writes into Flutter's cache on
/// every call.
String _childPath() {
  final exe = File(Platform.resolvedExecutable);
  final viaDart = exe.uri.pathSegments.last == 'dart';
  return [
    if (viaDart) exe.parent.path,
    Platform.environment['PATH'] ?? '/usr/bin:/bin',
  ].join(':');
}

/// Who is listening to one run: its output lines and its processes. Every
/// run takes one ([Executor.run] requires it), so a caller cannot forget to
/// pass on the taps it was given; a caller with nobody listening says so
/// with [none].
///
/// A run's taps are its own, so two runs at once cannot be mixed up. They are
/// a parameter, not a zone value, so they show in the signature of everything
/// that passes them on.
class ExecTaps {
  const ExecTaps({this.onProcess});

  /// Nobody is listening.
  static const none = ExecTaps();

  /// Told when the run starts a process (`ended` false) and when that
  /// process has let go of its stdout and stderr (`ended` true). Pipes
  /// closing, not the command exiting: a backgrounded grandchild keeps them
  /// open after the command is done, and that process outliving its step is
  /// what a person wants to see. Pushed by the pipes themselves -- nothing
  /// asks "is it still there?" on a timer.
  final ProcessTap? onProcess;
}

/// [pid] leads the command's process group (see [Executor.run]): hand it to
/// [groupAlive] when the STEP is over to learn whether anything the command
/// started is still running -- including a leftover that redirected its
/// output and so let go of the pipes.
typedef ProcessTap = void Function(int pid, List<String> argv, bool ended);

void _tellProcess(ProcessTap? tap, int pid, List<String> argv, bool ended) {
  if (tap == null) return;
  try {
    tap(pid, argv, ended);
    // ignore: avoid_catches_without_on_clauses, the caller's code, not ours
  } catch (_) {
    // A display callback failing must not fail the command.
  }
}

/// Remembers the processes one call started, so that when the call is over
/// [leaked] can say which of them left something running. One per call.
class ProcessLedger {
  final _leaders = <int>{};

  /// An [ExecTaps.onProcess] that records each process and then tells
  /// [next], if any.
  ProcessTap track([ProcessTap? next]) => (pid, argv, ended) {
    _leaders.add(pid);
    next?.call(pid, argv, ended);
  };

  /// The pids whose process group still has members. Asked once, by the
  /// caller, when the call is over -- not on a timer.
  Future<List<int>> leaked() async => [
    for (final pid in _leaders)
      if (await groupAlive(pid)) pid,
  ];
}

/// Whether any process is still in the group [leader] started (the pid an
/// [Executor] command was given). Asked once, by the caller, at the moment it
/// cares (the end of a step) -- not on a timer. True when `pgrep` cannot be
/// run: a question that could not be asked is not an answer that nothing is
/// left, and a leftover reported by mistake is seen where a missed one is not.
Future<bool> groupAlive(int leader) async {
  try {
    return (await Process.run('pgrep', ['-g', '$leader'])).exitCode == 0;
  } on ProcessException {
    return true;
  }
}

/// A command [Executor.start] was asked to run, while it runs: what it
/// prints, as it prints it, and what became of it.
///
/// [stdout] and [stderr] are single-subscription streams: until one is
/// listened to, it holds what arrives. That is no more than the [result]
/// holds anyway, and is let go with this object, so a caller that wants only
/// the result may leave them; [Executor.run] makes none.
final class Running {
  Running._(this.stdout, this.stderr, this.result);

  /// What the command prints on stdout, decoded as it arrives, so a
  /// character cut across two chunks comes through whole. Put together it is
  /// [ExecResult.stdout]. Done when the run stops capturing. For lines:
  /// `stdout.transform(const LineSplitter())`.
  final Stream<String> stdout;

  /// As [stdout], for stderr.
  final Stream<String> stderr;

  /// Whether it started, and if so what it did.
  final Future<ExecStart> result;
}

/// Runs commands, having asked first.
class Executor {
  final Directory root;
  final ConsentGate consent;
  final Duration timeout;

  /// Told when a child starts and when it has exited, with its pid -- for a
  /// host that watches for one that runs suspiciously long (the server's
  /// stall watch). Exit is reported however the run ends, killed included.
  final void Function(int pid, ExecRequest request)? onStarted;
  final void Function(int pid)? onExited;

  /// Awaited (for up to 10s) just before a command that went silent past
  /// `run`'s `quiet` is killed: the one moment its stuck state can still be
  /// looked at.
  final Future<void> Function(int pid)? beforeSilentKill;

  /// Starts every timer a run sets, each named by what it is for. A real
  /// timer, unless a test gives its own, to fire when it chooses. A timer, not
  /// a delay, because the quiet one is cancelled and started again by each
  /// output.
  final StartTimer startTimer;

  /// The PATH each child gets, read at each start: [ownChildPath] unless the
  /// host knows a better one. An app opened from Finder has only macOS's bare
  /// default, and passes its login shell's.
  final String Function() childPath;

  /// [childPath]'s default: this process's PATH, led by the directory of the
  /// Dart binary running it ([_childPath]).
  static String ownChildPath() => _childPath();

  /// How long [beforeSilentKill] may look at a silent command before it is
  /// killed anyway.
  static const lookWait = Duration(seconds: 10);

  /// How long a run waits, once the command has ended, for its pipes to close.
  static const drainWait = Duration(seconds: 2);

  /// How long a run waits for a command it killed to exit: one blocked in
  /// the kernel does not die even of SIGKILL until the call returns.
  static const killWait = Duration(seconds: 5);

  /// How far apart a group not yet empty is signalled again, and how many
  /// times at most: long enough for a fork in flight to finish.
  static const resignalPause = Duration(milliseconds: 5);
  static const resignalTries = 200;

  Executor({
    required this.root,
    required this.consent,
    this.timeout = const Duration(minutes: 2),
    this.onStarted,
    this.onExited,
    this.beforeSilentKill,
    this.startTimer = realTimer,
    this.childPath = ownChildPath,
  });

  /// [startTimer]'s default: the role does not change how long a real timer
  /// takes.
  static Timer realTimer(ExecTimer _, Duration duration, void Function() f) =>
      Timer(duration, f);

  /// Refuses everything. The default, and the only safe default: a gate that
  /// defaults to allowing is not a gate.
  static Future<bool> refuseAll(ExecRequest _) async => false;

  /// [quiet], when given, is how long the command may go silent ONCE IT HAS
  /// STARTED PRINTING before it is killed like a timeout
  /// ([ExecResult.silentFor]): for a command that prints as it goes, silence
  /// that long mid-run means it is stuck. Silence before the first output is
  /// not counted -- a slow start (`flutter test` resolving packages, waiting on
  /// flutter's startup lock) is not a hang -- and [timeout] still bounds it.
  ///
  /// [taps] are where the run's processes are reported (see [ExecTaps]); its
  /// output, as it is printed, is [start]'s. A caller passes on the taps it
  /// was given. REQUIRED, so a
  /// caller cannot forget to pass them on: one that really has nobody to
  /// report to says so with [ExecTaps.none].
  ///
  /// The command's stdin is closed at once: it gets no input.
  ///
  /// A command that was not started comes back as an [ExecResult] too, with
  /// exit -1 (127 for a program that is not there), for the tools that read
  /// it that way; [start] keeps it apart.
  Future<ExecResult> run(
    List<String> argv, {
    String? workingSubdir,
    Duration? quiet,
    required ExecTaps taps,
  }) async => _asResult(
    await _start(
      argv,
      workingSubdir: workingSubdir,
      quiet: quiet,
      taps: taps,
      input: null,
      printed: null,
    ),
  );

  /// [run], with [input] sent to the command's stdin as UTF-8 and then
  /// closed. The input is written alongside output collection, under the
  /// same timeout as the command.
  ///
  /// For a typed tool that builds [input] itself from its own validated
  /// request. A tool that hands the model's arguments to a program is given
  /// a runner without this method, so text the model wrote never reaches a
  /// program's stdin.
  Future<ExecResult> runWithInput(
    List<String> argv, {
    required String input,
    String? workingSubdir,
    Duration? quiet,
    required ExecTaps taps,
  }) async => _asResult(
    await _start(
      argv,
      workingSubdir: workingSubdir,
      quiet: quiet,
      taps: taps,
      input: input,
      printed: null,
    ),
  );

  /// [run], with what the command prints as it prints it ([Running.stdout],
  /// [Running.stderr]), and a command that was never started told apart from
  /// one that was: [ExecNotStarted], with why, rather than an exit code no
  /// program gave. A command not started prints nothing, and its streams
  /// close at once.
  ///
  /// [input], when given, is sent to the command's stdin as UTF-8 and then
  /// closed, as [runWithInput] sends it; when null, stdin is closed at once.
  /// For the program driver, whose runs the airlock has decided, input
  /// included. A tool is given a runner without this method.
  Running start(
    List<String> argv, {
    String? input,
    String? workingSubdir,
    Duration? quiet,
    required ExecTaps taps,
  }) {
    final out = StreamController<List<int>>();
    final err = StreamController<List<int>>();
    final result =
        _start(
          argv,
          workingSubdir: workingSubdir,
          quiet: quiet,
          taps: taps,
          input: input,
          printed: (out: out, err: err),
        ).whenComplete(() {
          unawaited(out.close());
          unawaited(err.close());
        });
    const decoder = Utf8Decoder(allowMalformed: true);
    return Running._(
      out.stream.transform(decoder),
      err.stream.transform(decoder),
      result,
    );
  }

  /// [start] as [run] reports it: a command not started as exit -1, marked
  /// [ExecResult.refused] where the run was refused rather than impossible,
  /// and a program that is not there as exit 127, as a shell reports it.
  static ExecResult _asResult(ExecStart start) {
    final ExecNotStarted notRun;
    switch (start) {
      case ExecStarted(:final result):
        return result;
      case ExecNotStarted():
        notRun = start;
    }
    final (exitCode, refused) = switch (notRun) {
      _NoCommand() || _OutsideTree() || _NotApproved() => (-1, true),
      _NoSuchProgram() => (127, false),
      _NoProcessGroup() || _NoSuchFolder() || _CouldNotStart() => (-1, false),
    };
    return ExecResult(
      exitCode: exitCode,
      stdout: '',
      stderr: notRun.why,
      refused: refused,
    );
  }

  Future<ExecStart> _start(
    List<String> argv, {
    required String? workingSubdir,
    required Duration? quiet,
    required ExecTaps taps,
    required String? input,
    required ({
      StreamController<List<int>> out,
      StreamController<List<int>> err,
    })?
    printed,
  }) async {
    if (argv.isEmpty || argv.first.trim().isEmpty) return const _NoCommand();

    // An ABSOLUTE directory is taken as given, and still has to be inside the
    // tree (below). Gluing it onto the root would make a path that passes the
    // containment check and does not exist.
    final cwd = workingSubdir == null || workingSubdir.isEmpty
        ? root
        : workingSubdir.startsWith('/')
        ? Directory(workingSubdir)
        : Directory('${root.path}/$workingSubdir');
    final shim = _shim;
    if (shim == null) return const _NoProcessGroup();
    if (!isInsideTree(root, cwd.absolute.path)) {
      return _OutsideTree(workingSubdir ?? '');
    }
    // Asked before starting: through the shim, a program that is not there
    // starts and exits 127, like one that ran and failed. The folder first,
    // because a relative program is looked for from it.
    if (!cwd.existsSync()) return _NoSuchFolder(cwd.path);
    final path = childPath();
    if (!_onPath(argv.first, path, from: cwd.path)) {
      return _NoSuchProgram(argv.first);
    }

    final request = ExecRequest(argv: argv, cwd: cwd);
    final allowed = await consent(request);
    if (!allowed) return const _NotApproved();

    // A timeout must kill everything the command started, not just the
    // process we hold. So the command starts through [_shim], which makes
    // itself the leader of a new session and process group and then execs the
    // command in its place: the pid we hold is the group's id, what the
    // command starts joins the group unless it makes a session or group of its
    // own, and the exit code is the command's. dart:io cannot start a process
    // in a new group without detaching it (dart-lang/sdk#22470).
    final Process proc;
    try {
      proc = await Process.start(
        shim.executable,
        [...shim.arguments, ...argv],
        workingDirectory: cwd.path,
        // PWD too: a shell sets it from the directory it starts in, and a
        // command exec'd directly would otherwise inherit this process's.
        environment: {'PATH': path, 'PWD': _pwd(cwd)},
        runInShell: false, // argv is argv, and there is no other way in
      );
    } on ProcessException catch (e) {
      // ENOENT here means EITHER the shim or the working directory is
      // missing (one removed since it was looked for); the OS does not say
      // which. Say which one it was.
      return cwd.existsSync()
          ? _CouldNotStart('${e.message}: ${argv.first}')
          : _NoSuchFolder(cwd.path);
    }
    onStarted?.call(proc.pid, request);
    final processTap = taps.onProcess;
    unawaited(_feedStdin(proc, input));
    _tellProcess(processTap, proc.pid, argv, false);

    final out = BytesBuilder(copy: false);
    final err = BytesBuilder(copy: false);
    // One timer, started by the first chunk of output and restarted by each
    // one after: it fires only after [quiet] with nothing printed mid-run.
    final silence = Completer<void>();
    // Output is captured, and passed on, until the result is returned. A
    // leftover that keeps printing after that is not this command's output,
    // and keeping it would grow these buffers for as long as it runs.
    var capturing = true;
    // Set once the wait below is over: output after that cannot make the
    // command silent, and must not leave a timer running past the result.
    var decided = false;
    Timer? hush;
    void heard() {
      if (quiet == null || decided) return;
      hush?.cancel();
      hush = startTimer(ExecTimer.quiet, quiet, () {
        if (!silence.isCompleted) silence.complete();
      });
    }

    final drained = Future.wait([
      proc.stdout.forEach((c) {
        if (!capturing) return;
        heard();
        out.add(c);
        printed?.out.add(c);
      }),
      proc.stderr.forEach((b) {
        if (!capturing) return;
        heard();
        err.add(b);
        printed?.err.add(b);
      }),
    ]);
    // Both pipes closed: nothing the command started still holds them. This
    // can come long after the result was returned (a leaked grandchild).
    unawaited(
      drained
          .then<void>((_) {}, onError: (Object _) {})
          .then((_) => _tellProcess(processTap, proc.pid, argv, true)),
    );
    // Done when the command is, NOT when the pipes close -- a backgrounded
    // grandchild can hold them open long after the command itself has exited.
    var exited = false;
    unawaited(
      proc.exitCode.then((_) {
        exited = true;
        onExited?.call(proc.pid);
      }),
    );

    // A timeout kills the tree: holding the process (and its group) is what
    // makes "killed" true rather than merely "no longer waited for".
    var timedOut = false;
    var silent = false;
    int? code;
    final overdue = Completer<void>();
    final deadline = startTimer(ExecTimer.timeout, timeout, () {
      if (!overdue.isCompleted) overdue.complete();
    });
    switch (await Future.any<_Ending>([
      proc.exitCode.then(_Exited.new),
      silence.future.then((_) => const _WentSilent()),
      overdue.future.then((_) => const _Overdue()),
    ])) {
      case _Exited(:final exitCode):
        code = exitCode;
      case _WentSilent():
        silent = true;
      case _Overdue():
        timedOut = true;
    }
    deadline.cancel();
    decided = true;
    hush?.cancel();
    if (silent && beforeSilentKill != null) {
      await _within(
        ExecTimer.look,
        lookWait,
        beforeSilentKill!(proc.pid).catchError((Object _) {}),
      );
      // It may have finished while it was being looked at: then it was not
      // stuck, and it has a real exit code to report.
      if (exited) {
        silent = false;
        code = await proc.exitCode;
      }
    }
    if (timedOut || silent) {
      // While the group has members its id is not reused, so this reaches
      // only what the command started. Once the group is empty, the id could
      // name another group only if a new process took this pid and made
      // itself a leader in the moment since the command was reaped.
      Process.killPid(-proc.pid, ProcessSignal.sigkill);
      // The process itself too: the shim, if it had not made its group yet.
      proc.kill(ProcessSignal.sigkill);
      // A member that was forking when the signal went out has a child born
      // into the group a moment later, which the signal never reached. It is
      // still a member, so the group is signalled until it has none; the
      // limit keeps one that never empties from holding the result.
      await _within(ExecTimer.kill, killWait, proc.exitCode);
      for (var i = 0; i < resignalTries; i++) {
        if (!Process.killPid(-proc.pid, ProcessSignal.sigkill)) break;
        final paused = Completer<void>();
        startTimer(ExecTimer.resignal, resignalPause, paused.complete);
        await paused.future;
      }
    }
    // A grandchild can inherit the pipes and hold them open after its parent
    // dies, so the drain is bounded too. Whatever was captured is reported.
    await _within(ExecTimer.drain, drainWait, drained);
    capturing = false;

    // Decoded leniently: output that is not UTF-8 (`cat` or `git` on a binary)
    // is still output, not an error.
    String text(BytesBuilder b) =>
        utf8.decode(b.takeBytes(), allowMalformed: true);
    return ExecStarted(
      ExecResult(
        exitCode: timedOut || silent ? -1 : (code ?? -1),
        stdout: text(out),
        stderr: text(err),
        timedOut: timedOut,
        silentFor: silent ? quiet : null,
      ),
    );
  }

  /// Feed input alongside output collection: a command can print before it
  /// reads, and awaiting the write first could deadlock both pipes. An early
  /// exit can close stdin before the input is consumed; its exit status and
  /// stderr, not an unhandled broken-pipe future, report that failure.
  static Future<void> _feedStdin(Process process, String? text) async {
    try {
      if (text != null) process.stdin.add(utf8.encode(text));
      await process.stdin.close();
    } on IOException {
      // The process may have exited without reading its input.
    }
  }

  /// Waits for [work], for no longer than [bound].
  Future<void> _within(ExecTimer role, Duration bound, Future<Object?> work) {
    final over = Completer<void>();
    final timer = startTimer(role, bound, () {
      if (!over.isCompleted) over.complete();
    });
    return Future.any<void>([work, over.future]).whenComplete(timer.cancel);
  }
}

/// What a timer an [Executor] run starts is for.
enum ExecTimer {
  /// [Executor.timeout] has passed: the command is killed.
  timeout,

  /// `run`'s `quiet` has passed since the last output: the command is silent.
  quiet,

  /// [Executor.lookWait] has passed: the look at a silent command is over.
  look,

  /// [Executor.killWait] has passed: a killed command is not waited for.
  kill,

  /// [Executor.resignalPause] has passed: its group is signalled again.
  resignal,

  /// [Executor.drainWait] has passed: the pipes are no longer waited for.
  drain,
}

/// Starts a timer for [role] that calls [f] once [duration] has passed.
typedef StartTimer = Timer Function(
  ExecTimer role,
  Duration duration,
  void Function() f,
);

/// How the wait for a command ended.
sealed class _Ending {
  const _Ending();
}

final class _Exited extends _Ending {
  const _Exited(this.exitCode);
  final int exitCode;
}

final class _WentSilent extends _Ending {
  const _WentSilent();
}

final class _Overdue extends _Ending {
  const _Overdue();
}

/// [dir] as a shell's PWD would name it: absolute, with `.` and `..` folded
/// away, and symlinks kept as they are.
String _pwd(Directory dir) {
  final p = dir.absolute.uri.normalizePath().toFilePath();
  return p.length > 1 && p.endsWith('/') ? p.substring(0, p.length - 1) : p;
}

/// How a command starts as the leader of a new session and process group: a
/// program that makes itself one and then execs its arguments in place, so
/// the pid that was started is the group's id and the exit code is the
/// command's. `setsid` if there is one, else perl (macOS has no `setsid`),
/// looked for in /usr/bin and /bin and then in the absolute directories on
/// this process's PATH: every command starts through this one program, so a
/// system copy wins and a relative entry, which would name a different file
/// from each working directory, is never used. Null on Windows, or when
/// neither is found, and then [Executor.run] runs nothing.
/// `setsid` execs in place unless it already leads a group, which a child of
/// this process never does. The perl program reads the group back rather
/// than trusting the call's return value, and dies rather than run the
/// command outside a group of its own; when the exec fails, it exits 127 for
/// a missing program and 126 otherwise, as `setsid` and a shell do. `--` ends
/// each one's options, so the command is never read as one.
final _Shim? _shim = () {
  if (Platform.isWindows) return null;
  final dirs = [
    '/usr/bin',
    '/bin',
    ...?Platform.environment['PATH']
        ?.split(':')
        .where((d) => d.startsWith('/')),
  ];
  for (final (name, arguments) in const [
    ('setsid', ['--']),
    ('perl', ['-e', _perlShim, '--']),
  ]) {
    for (final d in dirs) {
      final f = File('$d/$name');
      if (f.existsSync()) return (executable: f.path, arguments: arguments);
    }
  }
  return null;
}();

typedef _Shim = ({String executable, List<String> arguments});

/// A process started as the leader of a group of its own ([startInOwnGroup]),
/// and how to signal everything it started.
final class GroupProcess {
  GroupProcess._(this.process, this._grouped);

  final Process process;

  /// False where the host has no way to start a group ([_shim] is null, as on
  /// Windows): [kill] then reaches only [process].
  final bool _grouped;

  /// Sends [signal] to the group: the process and whatever it started that
  /// has not made a group of its own. While the group has members its id is
  /// not reused, so this reaches only what the process started; once it is
  /// empty, the id could name another group only if a new process took this
  /// pid and made itself a leader in the moment since this one was reaped.
  /// True if the signal reached anything.
  bool kill([ProcessSignal signal = ProcessSignal.sigterm]) {
    if (!_grouped) return process.kill(signal);
    final group = Process.killPid(-process.pid, signal);
    // The process itself too: the shim, if it had not made its group yet.
    return process.kill(signal) || group;
  }
}

/// Starts [executable] through the same shim as [Executor.run], so it leads
/// a session and process group of its own and [GroupProcess.kill] reaches
/// what it starts. Where there is no shim (Windows) it starts directly.
///
/// Throws [ProcessException] when [executable] is not found, as
/// [Process.start] does: through the shim a missing program would otherwise
/// start, and exit 127.
Future<GroupProcess> startInOwnGroup(
  String executable,
  List<String> arguments, {
  String? workingDirectory,
  Map<String, String>? environment,
}) async {
  final shim = _shim;
  if (shim == null) {
    return GroupProcess._(
      await Process.start(
        executable,
        arguments,
        workingDirectory: workingDirectory,
        environment: environment,
      ),
      false,
    );
  }
  final path =
      (environment ?? Platform.environment)['PATH'] ??
      Platform.environment['PATH'] ??
      '';
  if (!_onPath(executable, path)) {
    throw ProcessException(
      executable,
      arguments,
      'No such file or directory',
      2,
    );
  }
  return GroupProcess._(
    await Process.start(
      shim.executable,
      [...shim.arguments, executable, ...arguments],
      workingDirectory: workingDirectory,
      environment: environment,
    ),
    true,
  );
}

/// Whether [executable] names a file: itself when it has a `/`, else in one
/// of [path]'s directories. A relative name or directory is read from
/// [from], the directory the command starts in, when it is given, as the exec
/// that starts it reads one; else from this process's.
bool _onPath(String executable, String path, {String? from}) {
  String at(String p) => from == null || p.startsWith('/') ? p : '$from/$p';
  if (executable.contains('/')) return File(at(executable)).existsSync();
  return path
      .split(':')
      .where((d) => d.isNotEmpty)
      .any((d) => File('${at(d)}/$executable').existsSync());
}

const _perlShim = r'''
use POSIX ();
POSIX::setsid();
die "setsid failed: $!\n" unless getpgrp(0) == $$;
exec { $ARGV[0] } @ARGV;
print STDERR "$ARGV[0]: $!\n";
exit($!{ENOENT} ? 127 : 126);
''';
