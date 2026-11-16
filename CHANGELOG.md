## 0.1.0

- First release, moved out of intersyntactic's monorepo. `start` runs a
  program in a folder under the executor's root, as the leader of its own
  process group, and returns a `Running`: its `stdout` and `stderr` as
  `Stream<String>`, and `result`, which completes when the run ends. A timeout
  kills the whole group.
