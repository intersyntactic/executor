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

import 'doorstop.dart';
import 'outcome.dart';

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

  /// Why the executor killed the command, which then has no exit code of its
  /// own ([exitCode] is -1); null when it ended by itself. A command that died
  /// of a signal nobody here sent ended by itself, with its own exit code.
  /// The one exception is [KilledForOutput] for output past the limit once
  /// the command had exited: what it left was killed, and its code stands.
  final WhyKilled? whyKilled;

  /// How the command itself ended, as its parent saw it: an exit code, or
  /// the signal that ended it (which [exitCode] cannot tell from "no code").
  /// Null for a command that was not started.
  final Termination? termination;

  /// What the kill left, when the executor killed the group.
  final Cleanup cleanup;

  /// What the command left running once the run was over, seen while its
  /// ids were still held; null when it was not started or could not be seen.
  final Leftovers? leftovers;

  const ExecResult({
    required this.exitCode,
    required this.stdout,
    required this.stderr,
    this.refused = false,
    this.whyKilled,
    this.termination,
    this.cleanup = const NotKilled(),
    this.leftovers,
  });

  /// Killed for running past [Executor.timeout].
  bool get timedOut => whyKilled is KilledForTimeout;

  /// Set when the command was killed for printing nothing for this long
  /// (`run`'s `quiet`); null otherwise.
  Duration? get silentFor => switch (whyKilled) {
    KilledForSilence(:final quiet) => quiet,
    KilledForTimeout() ||
    KilledOnRequest() ||
    KilledForOutput() ||
    null => null,
  };

  /// Killed because whoever started it called [Running.kill].
  bool get killedOnRequest => whyKilled is KilledOnRequest;

  /// What the model is told.
  ///
  /// stderr is INCLUDED even on success, and the exit code is always stated.
  /// A command that printed a warning and succeeded, and one that printed the
  /// same text and failed, are different events; a transcript that shows only
  /// stdout makes them identical. This project has a name for that shape —
  /// exit 0 is not a measurement.
  String get forModel {
    if (refused) return 'refused: $stderr';
    final b = StringBuffer(switch (whyKilled) {
      KilledForSilence(:final quiet) =>
        'printed nothing for ${quiet.inSeconds}s and was killed; no exit code',
      KilledForTimeout() => 'timed out and was killed; no exit code',
      KilledOnRequest() => 'was stopped and killed; no exit code',
      KilledForOutput(:final channel, :final limit) =>
        'printed more than $limit bytes on ${channel.name}, so the rest was '
            'cut and it was killed; '
            '${exitCode == -1 ? 'no exit code' : 'exit $exitCode'}',
      null => switch (termination) {
        TerminationUnknown() =>
          'its doorstop was lost, so how it ended is not known; no exit code',
        Signalled(:final signal) => 'ended by signal $signal; no exit code',
        Exited() || null => 'exit $exitCode',
      },
    });
    if (stdout.trim().isNotEmpty) {
      b.write('\n--- stdout ---\n${stdout.trimRight()}');
    }
    if (stderr.trim().isNotEmpty) {
      b.write('\n--- stderr ---\n${stderr.trimRight()}');
    }
    if (stdout.trim().isEmpty && stderr.trim().isEmpty) b.write(' (no output)');
    return b.toString();
  }
}

/// Why an [Executor] killed a command it started, and with it everything in
/// the command's process group.
sealed class WhyKilled {
  const WhyKilled();
}

/// It ran past [Executor.timeout].
final class KilledForTimeout extends WhyKilled {
  const KilledForTimeout();
}

/// Having started printing, it printed nothing for [quiet] (`run`'s `quiet`).
final class KilledForSilence extends WhyKilled {
  const KilledForSilence(this.quiet);

  final Duration quiet;
}

/// Whoever started it called [Running.kill].
final class KilledOnRequest extends WhyKilled {
  const KilledOnRequest();
}

/// It printed more than [limit] bytes on [channel] (`start`'s
/// `maxOutputBytes`). What it printed is kept up to [limit] bytes on each
/// channel, cut where a character ends, and nothing after the first channel
/// went over. When it had already exited and what it left running went
/// over, that was killed, and its exit code stands.
final class KilledForOutput extends WhyKilled {
  const KilledForOutput(this.channel, this.limit);

  final OutputChannel channel;
  final int limit;
}

/// One of the two channels a command prints on.
enum OutputChannel { stdout, stderr }

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
  const _NoProcessGroup(this.reason);

  final String reason;

  @override
  String get why =>
      'not run: the command could not be put in a process group of its own, '
      'so a timeout could not kill what it starts ($reason)';
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

/// [Running.kill] was called before the command was started, so it was not.
final class _KilledBeforeStart extends ExecNotStarted {
  const _KilledBeforeStart();

  @override
  String get why => 'killed before it started';
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
  // wire-ok: the executable's file name as the OS reports it
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

/// [pid] is the command's, and its process group's id (see [Executor.run]),
/// for showing a person; what it left running is [ExecResult.leftovers].
/// Nothing here signals by it, and a caller that does is outside what the
/// executor holds: once the run is over the id can be another process's.
typedef ProcessTap = void Function(int pid, List<String> argv, bool ended);

void _tellProcess(ProcessTap? tap, int pid, List<String> argv, bool ended) {
  if (tap == null) return;
  try {
    tap(pid, argv, ended);
  } on Object catch (_) {
    // A display callback failing must not fail the command.
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
  Running._(this.stdout, this.stderr, this.result, this._killAsked);

  final Completer<void> _killAsked;

  /// What the command prints on stdout, decoded as it arrives, so a
  /// character cut across two chunks comes through whole. Put together it is
  /// [ExecResult.stdout]. Done when the run stops capturing. For lines:
  /// `stdout.transform(const LineSplitter())`.
  final Stream<String> stdout;

  /// As [stdout], for stderr.
  final Stream<String> stderr;

  /// Whether it started, and if so what it did.
  final Future<ExecStart> result;

  /// Kills the command and everything in its process group, as a timeout
  /// does, and completes once [result] has.
  ///
  /// Before the command is started it is not started: [result] is an
  /// [ExecNotStarted]. While it runs it is killed, and its result says
  /// [KilledOnRequest]. Once it has ended by itself, while its pipes are
  /// still being drained, what it left running in its group is killed and
  /// its result keeps its own exit code; after [result] has completed,
  /// nothing is done. Calling it again does no more than the first call.
  Future<void> kill() {
    if (!_killAsked.isCompleted) _killAsked.complete();
    return result.then((_) {});
  }
}

/// Runs commands, having asked first.
class Executor {
  final Directory root;
  final ConsentGate consent;
  final Duration timeout;

  /// Told when a child starts and when it has exited, with its pid -- for a
  /// host that watches for one that runs suspiciously long (the server's
  /// stall watch). Exit is reported when the command is seen to end, killed
  /// included; a command still running when its run returns (stuck in the
  /// kernel after a kill) is not reported as exited. One that throws is
  /// ignored, and the run goes on.
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

  /// How long a run waits for its doorstop to answer (started, a kill's
  /// result, what is left), and for a command it killed to exit: one blocked
  /// in the kernel does not die even of SIGKILL until the call returns. The
  /// doorstop's own kill gives up answering after a second, inside this.
  static const killWait = Duration(seconds: 5);

  /// Where commands run from, and what that promises ([ProcessContainment]):
  /// [installDoorstop] unless a test gives its own.
  final Future<ProcessContainment> Function() containment;

  Executor({
    required this.root,
    required this.consent,
    this.timeout = const Duration(minutes: 2),
    this.onStarted,
    this.onExited,
    this.beforeSilentKill,
    this.startTimer = realTimer,
    this.childPath = ownChildPath,
    this.containment = installDoorstop,
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
  ///
  /// [maxOutputBytes], when given, is how much the command may print on
  /// stdout, and as much again on stderr. The first time it prints past that
  /// on either, it is killed with its group ([KilledForOutput]), and what it
  /// printed is kept, and streamed, up to that many bytes on each, cut where
  /// a character ends. It must not be negative.
  Running start(
    List<String> argv, {
    String? input,
    String? workingSubdir,
    Duration? quiet,
    int? maxOutputBytes,
    required ExecTaps taps,
  }) {
    if (maxOutputBytes != null) {
      RangeError.checkNotNegative(maxOutputBytes, 'maxOutputBytes');
    }
    final out = StreamController<List<int>>();
    final err = StreamController<List<int>>();
    final killAsked = Completer<void>();
    final result =
        _start(
          argv,
          workingSubdir: workingSubdir,
          quiet: quiet,
          taps: taps,
          input: input,
          printed: (out: out, err: err),
          killAsked: killAsked,
          maxOutputBytes: maxOutputBytes,
        ).whenComplete(() {
          unawaited(out.close());
          unawaited(err.close());
        });
    const decoder = Utf8Decoder(allowMalformed: true);
    return Running._(
      out.stream.transform(decoder),
      err.stream.transform(decoder),
      result,
      killAsked,
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
      _NoProcessGroup() ||
      _NoSuchFolder() ||
      _KilledBeforeStart() ||
      _CouldNotStart() => (-1, false),
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
    // [Running.kill]'s; null for [run], whose caller has no way to kill.
    Completer<void>? killAsked,
    int? maxOutputBytes,
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
    final String doorstop;
    switch (await containment()) {
      case Doorstop(:final path):
        doorstop = path;
      case NoProcessGroup(:final reason):
        return _NoProcessGroup(reason);
    }
    if (!isInsideTree(root, cwd.absolute.path)) {
      return _OutsideTree(workingSubdir ?? '');
    }
    // Asked before the gate, so nobody is asked to approve a program that
    // is not there. Not the last word: one removed after this is still
    // reported as missing, by the doorstop's failed exec. The folder first,
    // because a relative program is looked for from it.
    if (!cwd.existsSync()) return _NoSuchFolder(cwd.path);
    final path = childPath();
    if (!_onPath(argv.first, path, from: cwd.path)) {
      return _NoSuchProgram(argv.first);
    }

    final request = ExecRequest(argv: argv, cwd: cwd);
    // The gate is asked before [start] returns, so no kill can come before
    // it; one can come while it is waited for, since a person can take a
    // while to answer.
    final allowed = await consent(request);
    if (!allowed) return const _NotApproved();
    if (killAsked?.isCompleted ?? false) return const _KilledBeforeStart();

    // A timeout must kill everything the command started, and a kill must
    // reach only that. So the command starts under the doorstop, its parent:
    // the command leads a new session and process group, and the doorstop
    // holds it unreaped once it exits, so neither id can be another
    // process's until the run lets go. Only the doorstop signals; this asks
    // it to, over a unix socket. dart:io can neither start a process in a
    // new group without detaching it (dart-lang/sdk#22470) nor keep its own
    // children unreaped.
    final Process proc;
    final DoorstopLink link;
    final int pid;
    switch (await _startUnder(doorstop, argv, cwd, path)) {
      case _NotLaunched(:final why):
        return why;
      case _Launched(proc: final p, link: final l, pid: final c):
        proc = p;
        link = l;
        pid = c;
    }
    _observe(() => onStarted?.call(pid, request));
    final processTap = taps.onProcess;
    unawaited(_feedStdin(proc, input));
    _tellProcess(processTap, pid, argv, false);

    final out = _Capture(maxOutputBytes, printed?.out);
    final err = _Capture(maxOutputBytes, printed?.err);
    // The first channel to go past [maxOutputBytes]. From then on nothing
    // more is captured, on either channel, and the run is killed.
    KilledForOutput? overflowed;
    final overflow = Completer<KilledForOutput>();
    // One timer, started by the first chunk of output and restarted by each
    // one after: it fires only after [quiet] with nothing printed mid-run.
    final silence = Completer<Duration>();
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
        if (!silence.isCompleted) silence.complete(quiet);
      });
    }

    Future<void> capture(
      Stream<List<int>> pipe,
      _Capture into,
      OutputChannel channel,
    ) async {
      await pipe.forEach((chunk) {
        if (!capturing || overflowed != null) return;
        heard();
        if (into.add(chunk) case final limit?) {
          final cut = KilledForOutput(channel, limit);
          overflowed = cut;
          overflow.complete(cut);
        }
      });
      if (capturing && overflowed == null) into.close();
    }

    final drained = Future.wait([
      capture(proc.stdout, out, OutputChannel.stdout),
      capture(proc.stderr, err, OutputChannel.stderr),
    ]);
    // Both pipes closed: nothing the command started still holds them. This
    // can come long after the result was returned (a leaked grandchild).
    unawaited(
      drained
          .then<void>((_) {}, onError: (Object _) {})
          .then((_) => _tellProcess(processTap, pid, argv, true)),
    );
    // Done when the command is, NOT when the pipes close -- a backgrounded
    // grandchild can hold them open long after the command itself has exited.
    // Exit is told when the doorstop says the command ended, and only then:
    // a run can return before that (a command stuck in the kernel after a
    // kill), and must not tell observers that a live process exited.
    Termination? termination;
    unawaited(
      link.ended.future.then((how) {
        termination = how;
        _observe(() => onExited?.call(pid));
      }),
    );

    // A kill reaches the whole group, and only it: the doorstop holds the
    // command unreaped, so the group's id stays the command's, and the
    // doorstop alone signals it. A member forking as the signal goes out has
    // a child born into the group a moment later; the doorstop signals again
    // until two looks in a row see nobody, or a second has passed.
    Cleanup cleanup = const NotKilled();
    Future<void> killGroup() async {
      cleanup =
          await _upTo(ExecTimer.answer, killWait, link.kill()) ??
          const CleanupUnknown();
      // One blocked in the kernel does not die even of SIGKILL until the
      // call returns: waited for, but not for ever.
      termination ??=
          await _upTo(ExecTimer.kill, killWait, link.ended.future) ??
          const TerminationUnknown();
    }

    WhyKilled? whyKilled;
    int? code;
    final overdue = Completer<void>();
    final deadline = startTimer(ExecTimer.timeout, timeout, () {
      if (!overdue.isCompleted) overdue.complete();
    });
    switch (await Future.any<_Ending>([
      link.ended.future.then(_EndedByItself.new),
      link.lost.future.then((_) => const _DoorstopLost()),
      silence.future.then(_WentSilent.new),
      overdue.future.then((_) => const _Overdue()),
      if (killAsked != null) killAsked.future.then((_) => const _KillAsked()),
      overflow.future.then(_Overflowed.new),
    ])) {
      case _EndedByItself(:final how):
        code = how.asExitCode;
      case _DoorstopLost():
        // Nothing can be signalled now: the ids are no longer held. How it
        // ended, and what it left, are not known.
        termination = const TerminationUnknown();
        cleanup = const CleanupUnknown();
      case _WentSilent(:final quiet):
        whyKilled = KilledForSilence(quiet);
      case _Overdue():
        whyKilled = const KilledForTimeout();
      case _KillAsked():
        whyKilled = const KilledOnRequest();
      case _Overflowed(:final cut):
        whyKilled = cut;
    }
    deadline.cancel();
    decided = true;
    hush?.cancel();
    if (whyKilled is KilledForSilence && beforeSilentKill != null) {
      await _within(
        ExecTimer.look,
        lookWait,
        // Future.sync: one that throws before returning a future is caught too.
        Future<void>.sync(() => beforeSilentKill!(pid))
            .catchError((Object _) {}),
      );
      // It may have finished while it was being looked at: then it was not
      // stuck, and it has a real exit code to report.
      if (termination case final how?) {
        whyKilled = null;
        code = how.asExitCode;
      }
    }
    Future<void>? killing;
    if (whyKilled != null) {
      await (killing = killGroup());
    } else if (!link.lost.isCompleted) {
      // It ended by itself, and a grandchild may still hold its pipes: a
      // kill asked for while they drain, or output past the limit, reaches
      // what it left in its group.
      void killLeftovers(Object? _) {
        if (capturing) killing ??= killGroup();
      }

      unawaited(killAsked?.future.then(killLeftovers));
      unawaited(overflow.future.then(killLeftovers));
    }
    // A grandchild can inherit the pipes and hold them open after its parent
    // dies, so the drain is bounded too. Whatever was captured is reported.
    await _within(ExecTimer.drain, drainWait, drained);
    capturing = false;
    await killing;
    // Output cut once the command had exited is said too, beside its own
    // exit code.
    whyKilled ??= overflowed;
    // What it left, asked while the ids are still held; then the doorstop is
    // let go. After a kill that left something, it goes on killing the group
    // by itself until none is seen, so this run need not wait for that.
    final leftovers = await _upTo(ExecTimer.answer, killWait, link.leftovers());
    switch (cleanup) {
      case Incomplete() || CleanupUnknown():
        link.abandon();
      case NotKilled() || NoneSeen():
        link.release();
    }

    return ExecStarted(
      ExecResult(
        exitCode: code ?? -1,
        stdout: out.text,
        stderr: err.text,
        whyKilled: whyKilled,
        termination: termination ?? const TerminationUnknown(),
        cleanup: cleanup,
        leftovers: leftovers,
      ),
    );
  }

  /// Starts [argv] under the [doorstop], in [cwd] with [path] as its PATH,
  /// and waits until the doorstop has said whether the exec succeeded.
  Future<_Launch> _startUnder(
    String doorstop,
    List<String> argv,
    Directory cwd,
    String path,
  ) async {
    // A folder of this process's own (0700), so nobody else can connect.
    final Directory folder;
    try {
      folder = await Directory.systemTemp.createTemp('is_executor_');
    } on FileSystemException catch (e) {
      return _NotLaunched(
        _CouldNotStart('no folder for the doorstop socket: ${e.message}'),
      );
    }
    final socketPath = '${folder.path}/s';
    final ServerSocket server;
    try {
      server = await ServerSocket.bind(
        InternetAddress(socketPath, type: InternetAddressType.unix),
        0,
      );
    } on SocketException catch (e) {
      await _remove(folder);
      return _NotLaunched(_CouldNotStart('no socket for the doorstop: $e'));
    }
    final Process proc;
    try {
      proc = await Process.start(
        doorstop,
        [socketPath, ...argv],
        workingDirectory: cwd.path,
        // PWD too: a shell sets it from the directory it starts in, and a
        // command exec'd directly would otherwise inherit this process's.
        environment: {'PATH': path, 'PWD': _pwd(cwd)},
        runInShell: false, // argv is argv, and there is no other way in
      );
    } on ProcessException catch (e) {
      await server.close();
      await _remove(folder);
      // ENOENT here means EITHER the doorstop or the working directory is
      // missing (one removed since it was looked for); the OS does not say
      // which. Say which one it was.
      return _NotLaunched(
        cwd.existsSync()
            ? _CouldNotStart('${e.message}: ${argv.first}')
            : _NoSuchFolder(cwd.path),
      );
    }
    // Connected, or the doorstop exited first (it could not connect), or
    // neither within the wait. The doorstop is never signalled: whatever it
    // is doing, it exits by itself once it has no socket.
    final socket = await _upTo(
      ExecTimer.answer,
      killWait,
      Future.any<Socket?>([server.first, proc.exitCode.then((_) => null)]),
    );
    await server.close();
    await _remove(folder);
    if (socket == null) {
      final said = await _upTo(
        ExecTimer.answer,
        killWait,
        proc.stderr.transform(utf8.decoder).join(),
      );
      _letGoOf(proc, stderrTaken: true);
      return _NotLaunched(
        _CouldNotStart('the doorstop did not start: ${said ?? ''}'.trim()),
      );
    }
    final link = DoorstopLink(socket);
    final started = await _upTo(
      ExecTimer.answer,
      killWait,
      link.started.future,
    );
    final exec = started == null
        ? null
        : await _upTo(ExecTimer.answer, killWait, link.exec.future);
    if (started == null || exec == null) {
      link.abandon();
      _letGoOf(proc);
      return const _NotLaunched(
        _CouldNotStart('the doorstop did not say whether the command started'),
      );
    }
    switch (exec) {
      case DoorstopExecFailed(:final errno):
        link.release();
        _letGoOf(proc);
        return _NotLaunched(
          errno == _enoent
              ? _NoSuchProgram(argv.first)
              : _CouldNotStart('${_errnoText(errno)}: ${argv.first}'),
        );
      case DoorstopExecRan():
        return _Launched(proc: proc, link: link, pid: started.pid);
    }
  }

  /// Lets go of a doorstop whose command will not run here: its stdin closed
  /// (else this process holds the pipe's write end until the [Process] is
  /// collected) and what it prints drained; its stderr only when nothing has
  /// read it yet ([stderrTaken]), since a stream is listened to once.
  static void _letGoOf(Process proc, {bool stderrTaken = false}) {
    unawaited(proc.stdin.close().then<void>((_) {}, onError: (Object _) {}));
    unawaited(proc.stdout.drain<void>().catchError((Object _) {}));
    if (!stderrTaken) {
      unawaited(proc.stderr.drain<void>().catchError((Object _) {}));
    }
  }

  /// Waits for [work], for no longer than [bound]: its value, or null.
  Future<T?> _upTo<T>(ExecTimer role, Duration bound, Future<T> work) {
    final over = Completer<T?>();
    final timer = startTimer(role, bound, () {
      if (!over.isCompleted) over.complete(null);
    });
    return Future.any<T?>([work, over.future]).whenComplete(timer.cancel);
  }

  static Future<void> _remove(Directory folder) =>
      folder.delete(recursive: true).then((_) {}, onError: (Object _) {});

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

/// Calls an observer the caller gave ([Executor.onStarted],
/// [Executor.onExited]). One that throws must not unwind the run that owns
/// the command: the command would be left with no timeout and no cleanup.
void _observe(void Function() call) {
  try {
    call();
  } on Object catch (_) {
    // An observer failing is the observer's; the run goes on.
  }
}

/// How [Executor._startUnder] went.
sealed class _Launch {
  const _Launch();
}

final class _Launched extends _Launch {
  const _Launched({required this.proc, required this.link, required this.pid});

  /// The doorstop: its stdin, stdout and stderr are the command's.
  final Process proc;
  final DoorstopLink link;

  /// The command's.
  final int pid;
}

final class _NotLaunched extends _Launch {
  const _NotLaunched(this.why);

  final ExecNotStarted why;
}

/// ENOENT: the same number on Linux and macOS.
const _enoent = 2;

/// What an errno from a failed exec means. These numbers are the same on
/// Linux and macOS.
String _errnoText(int errno) => switch (errno) {
  1 => 'not permitted',
  8 => 'not a program this system can run',
  13 => 'permission denied',
  20 => 'a part of the path is not a folder',
  _ => 'could not be run (errno $errno)',
};

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

  /// [Executor.killWait] has passed: the doorstop's answer is not waited
  /// for (that it started, what a kill left, what is still running).
  answer,

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

final class _EndedByItself extends _Ending {
  const _EndedByItself(this.how);
  final Termination how;
}

final class _DoorstopLost extends _Ending {
  const _DoorstopLost();
}

final class _WentSilent extends _Ending {
  const _WentSilent(this.quiet);
  final Duration quiet;
}

final class _Overdue extends _Ending {
  const _Overdue();
}

final class _KillAsked extends _Ending {
  const _KillAsked();
}

final class _Overflowed extends _Ending {
  const _Overflowed(this.cut);
  final KilledForOutput cut;
}

/// What one of a command's output channels has printed, kept, and passed on
/// as it arrives, up to [limit] bytes when there is one.
final class _Capture {
  _Capture(this.limit, this.passOn);

  final int? limit;
  final StreamController<List<int>>? passOn;
  final _kept = BytesBuilder(copy: false);

  // With a limit, a chunk's last bytes that may be a character cut in two
  // wait for the next chunk, so the cut at the limit falls where a character
  // ends. At most three bytes, and only until the next chunk or the end.
  List<int> _held = const [];

  /// Keeps [chunk], and is null; or, when it goes past the limit, keeps
  /// what fits, cut where a character ends, and is the limit.
  int? add(List<int> chunk) {
    final limit = this.limit;
    if (limit == null) {
      _keep(chunk);
      return null;
    }
    final bytes = [..._held, ...chunk];
    final room = limit - _kept.length;
    if (bytes.length <= room) {
      final whole = _wholeCharacters(bytes);
      _keep(bytes.sublist(0, whole));
      _held = bytes.sublist(whole);
      return null;
    }
    var end = room;
    while (end > 0 && _continues(bytes[end])) {
      end--;
    }
    _keep(bytes.sublist(0, end));
    _held = const [];
    return limit;
  }

  /// The channel has closed: what was held waiting for the rest of a
  /// character is all there is.
  void close() {
    _keep(_held);
    _held = const [];
  }

  /// Decoded leniently: output that is not UTF-8 (`cat` or `git` on a
  /// binary) is still output, not an error.
  String get text => utf8.decode(_kept.takeBytes(), allowMalformed: true);

  void _keep(List<int> bytes) {
    if (bytes.isEmpty) return;
    _kept.add(bytes);
    passOn?.add(bytes);
  }

  static bool _continues(int byte) => byte & 0xC0 == 0x80;

  /// How much of [bytes] ends where a character does: all of it, unless it
  /// ends in the first bytes of a character whose rest has not come yet.
  static int _wholeCharacters(List<int> bytes) {
    var start = bytes.length - 1;
    while (start >= 0 &&
        start >= bytes.length - 3 &&
        _continues(bytes[start])) {
      start--;
    }
    if (start < 0) return bytes.length;
    final lead = bytes[start];
    final length = lead >= 0xF0
        ? 4
        : lead >= 0xE0
        ? 3
        : lead >= 0xC0
        ? 2
        : 1;
    return start + length > bytes.length ? start : bytes.length;
  }
}

/// [dir] as a shell's PWD would name it: absolute, with `.` and `..` folded
/// away, and symlinks kept as they are.
String _pwd(Directory dir) {
  final p = dir.absolute.uri.normalizePath().toFilePath();
  return p.length > 1 && p.endsWith('/') ? p.substring(0, p.length - 1) : p;
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
