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
