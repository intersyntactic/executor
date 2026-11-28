## 0.4.0

- Every command starts under the doorstop (`native/doorstop.c`), its
  parent, in place of the `setsid`/perl shim. The doorstop keeps the command
  unreaped after it exits, so its pid and process group cannot be given to
  another process while the run needs them, and it alone signals them: this
  library no longer signals anything. A kill, a timeout, silence or output
  past the limit asks it to kill the group; it signals again until two looks
  in a row see nothing, so a member forking as the signal goes out is caught.
- The host dying (a crash, `kill -9`, Ctrl-C to its group) now kills the
  command's group, where before it left the command running in a session of
  its own. On Linux it also kills a daemon the command started that left the
  group (the doorstop is its subreaper). On Linux, the doorstop killed from
  outside takes the command with it.
- `ExecResult.termination`, a sealed `Termination` (`Exited`, `Signalled`,
  `TerminationUnknown`): how the command ended. A death by SIGHUP was -1,
  the same as "no exit code"; it is now `Signalled(1)`, and `forModel` says
  so. `exitCode` is unchanged.
- `ExecResult.cleanup`, a sealed `Cleanup` (`NotKilled`, `NoneSeen`,
  `Incomplete`, `CleanupUnknown`): what a kill left, as far as could be
  seen. After `Incomplete`, the doorstop goes on killing by itself once the
  run has returned.
- `ExecResult.leftovers`: what the command left running when its run was
  over, seen while its ids were still held.
- `Executor.containment` (default `installDoorstop`) and the sealed
  `ProcessContainment` (`Doorstop`, `NoProcessGroup`). The doorstop ships in
  the package as bytes for linux-x64, linux-arm64, macos-x64 and
  macos-arm64; once per process it is written into a new folder of that
  process's own in the system temp folder and run once with `--probe`, which
  also says whether it can adopt orphans (`Doorstop.adoptsOrphans`).
  Anywhere else, or where it cannot run (a `noexec` temp folder), commands
  are refused with the reason, as on Windows.
- Breaking: `startInOwnGroup`, `GroupProcess`, `ProcessLedger` and
  `groupAlive` are removed (`groupAlive` asked `pgrep` about a group id after
  its leader had been reaped, when the id could be another's;
  `ExecResult.leftovers` replaces both it and the ledger).
  `Executor.resignalPause`, `Executor.resignalTries` and `ExecTimer.resignal`
  are removed; `ExecTimer.answer` is new. A missing program is still refused
  before the consent gate is asked; one removed after that check is reported
  as missing too, from the failed exec.

## 0.3.0

- `start` takes `maxOutputBytes`: how much a command may print on stdout,
  and as much again on stderr. The first time it prints past that on
  either, it is killed with its group by the same sequence as `kill()`,
  and the result's `whyKilled` is a `KilledForOutput` naming the channel
  and the limit. What it printed is kept, and streamed, up to the limit on
  each channel, cut where a UTF-8 character ends, even when the character
  arrived split across two writes. Past the limit after the command had
  exited, what it left running is killed and its exit code stands.
- Breaking: `WhyKilled` has a new case, `KilledForOutput`, so an
  exhaustive switch on it needs an arm for it. `OutputChannel` is new.

## 0.2.0

- `Running.kill()` kills a started command and everything in its process
  group, by the same sequence a timeout uses: the group, the process itself
  (the shim may not have made its group yet), then the group again until it
  is empty (a member forking as the signal went out). Before the command is
  started it is not started, and `result` is an `ExecNotStarted`; once it
  has ended, what it left holding its pipes is killed and its exit code is
  kept; a second call does no more. It completes once `result` has.
- `ExecResult.whyKilled`, a sealed `WhyKilled` (`KilledForTimeout`,
  `KilledForSilence`, `KilledOnRequest`), says why the executor killed a
  command, or is null when it ended by itself. `timedOut` and `silentFor` are
  now getters on it, and `killedOnRequest` is new. Breaking: `ExecResult`'s
  constructor takes `whyKilled` in place of `timedOut` and `silentFor`.

## 0.1.0

- First release, moved out of intersyntactic's monorepo. `start` runs a
  program in a folder under the executor's root, as the leader of its own
  process group, and returns a `Running`: its `stdout` and `stderr` as
  `Stream<String>`, and `result`, which completes when the run ends. A timeout
  kills the whole group.
