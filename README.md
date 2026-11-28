# is_executor

Runs a program in a directory, having asked a consent gate first, as the
leader of a process group of its own, so a timeout kills everything it
started. Moved out of intersyntactic's monorepo so the program driver and the
monorepo's own tools share one copy.

A working directory must stay inside the executor's root, judged by
[is_path_confinement](https://github.com/intersyntactic/path_confinement).

## The doorstop

Every command starts under the doorstop (`native/doorstop.c`), a small
program that is the command's parent. It puts the command in a new session
and process group, and when the command exits it keeps it unreaped, so the
command's pid and group id cannot be given to another process while the run
still needs them. The doorstop is the only process that signals the command;
this library asks it to, over a unix socket, and never signals anything
itself.

What that promises, by platform:

| | Linux | macOS |
|---|---|---|
| A timeout or `kill()` reaches the command's group | yes | yes |
| A kill reaches only processes the command started | yes | yes |
| The host dying (crash, `kill -9`, Ctrl-C) kills the command's group | yes | yes |
| ...and a daemon it started that left the group | yes | no |
| The doorstop killed from outside takes the command with it | yes¹ | no |
| How the command ended: exit code or signal | yes | yes |

¹ Unless the command changed user (a setuid program), which clears it.

What a kill left, and what a run left running, are what could be seen: a
scan of running processes observes, it does not prove. `ExecResult.cleanup`
and `ExecResult.leftovers` say so in their types.

The doorstop ships inside this package as bytes
(`lib/src/doorstop_bytes.g.dart`, built by `tool/build_doorstop.dart` with
zig from the C source; CI rebuilds it and fails on any difference). On first
use it is written to the user's cache folder and run once with `--probe`.
Where there is no build for the platform, or it cannot be run there (a cache
mounted `noexec`), commands are refused with the reason, as on Windows, rather
than run without a process group.
