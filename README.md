# is_executor

Runs a program in a directory, having asked a consent gate first, as the
leader of a process group of its own (`setsid`, else a perl shim, since macOS
has no `setsid`), so a timeout kills everything it started. Moved out of
intersyntactic's monorepo so the program driver and the monorepo's own tools
share one copy.

A working directory must stay inside the executor's root, judged by
[is_path_confinement](https://github.com/intersyntactic/path_confinement).
