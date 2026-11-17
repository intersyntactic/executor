/// What is left of a command's process group once a run is over, for tests
/// that check a kill reached everything the command started.
library;

import 'dart:convert';
import 'dart:io';

/// The live members of the process [groups]: a zombie is dead, only not yet
/// reaped. Each as `ps` prints its group, state and name; never its
/// arguments, which can carry secrets.
List<String> liveIn(Set<int> groups) => [
  for (final line in const LineSplitter().convert(
    Process.runSync('ps', ['-A', '-o', 'pgid=,stat=,comm=']).stdout
        as String, // cast-ok: runSync decodes stdout to a String
  ))
    if (line.trim().split(RegExp(r'\s+')) case [final g, final stat, ...]
        when groups.contains(int.tryParse(g)) && !stat.startsWith('Z'))
      line.trim(),
];
