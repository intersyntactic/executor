# is_executor

Two libraries, moved out of intersyntactic's monorepo so the program driver
and the monorepo's own tools run programs, and keep paths inside a tree, with
one copy of each:

- `package:is_executor/executor.dart`: runs a program in a directory, having
  asked a consent gate first, as the leader of a process group of its own
  (`setsid`, else a perl shim, since macOS has no `setsid`), so a timeout
  kills everything it started.
- `package:is_executor/path_confinement.dart`: whether a path stays inside a
  tree, through `..`, symlinks and absolute paths, including paths that don't
  exist yet. The executor checks working directories with it, and file tools
  check their paths with it: one implementation, because two drift.
