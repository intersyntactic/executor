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
| ...and a daemon it started that left the group | yes¹ | no |
| The doorstop killed from outside takes the command with it | yes² | no |
| How the command ended: exit code or signal | yes | yes |

¹ Unless a sandbox denies the doorstop the subreaper prctl; `Doorstop.adoptsOrphans`
says which, as the doorstop found when it was installed.
² Unless the command changed user (a setuid program), which clears it.

What a kill left, and what a run left running, are what could be seen: a
scan of running processes observes, it does not prove. `ExecResult.cleanup`
and `ExecResult.leftovers` say so in their types.

The doorstop ships inside this package as bytes
(`lib/src/doorstop_bytes.g.dart`, built by `tool/build_doorstop.dart` from
the C source; CI rebuilds it and fails on any difference). Build it with zig
0.15.2 as ziglang.org ships it (`ZIG=<path>` if it is not first on PATH): a
packaged zig of the same version, such as Homebrew's, builds with the system's
clang and makes different bytes, and the tool refuses it.

Once per process it is written into a new folder of that process's own in the
system temp folder (mkdtemp: 0700, never one that was there before) and run
once with `--probe`. There is no shared cache: a file kept at a known path is
one someone else may be able to replace between its check and its run.
Where there is no build for the platform, or it cannot be run there (a temp
folder mounted `noexec`; set `TMPDIR` to one that is not), commands are
refused with the reason, as on Windows, rather than run without a process
group.
