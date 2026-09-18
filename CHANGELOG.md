# Changelog

## [Unreleased]

### Fixed

- Weak references no longer crash the 32-bit x86 build. Storing an object in a
  `WeakMap` under a key that is itself a `WeakMap`, a `WeakReference` or an
  `SplObjectStorage` killed the process as soon as the map was printed or
  iterated — `$map[$other] = 1; var_dump($map);` was enough, and so was the
  self-storing map (`$map[$map] = $map;`) reported earlier as a known issue.
  Only the i686 build was affected; every other platform, 32-bit ARM included,
  was always correct.
- Deep recursion raises PHP's own error instead of crashing the process. On the
  8 MB stack Linux gives a process by default, comparing deeply nested objects
  (or any deep recursion) segfaulted; PHP's stack guard — the one that answers
  "Maximum call stack size reached" — had been compiled out of every binary we
  shipped, because the configure probe that enables it has to *run* a program
  and could not.
- `php -a` opens the interactive shell on Linux and macOS. It used to answer
  "Interactive shell (-a) requires the readline extension" there too, even
  though `php -m` listed readline and `readline()` worked from a script: inside
  a single static binary the extension could not find the shell's entry point.
  (The Windows build carries no readline, so `-a` is genuinely absent there.)
- Asking for a program that does not exist no longer runs a file of that name.
  `php --unpin-program=typo` used to hand `typo` to the interpreter as a script
  path, so a file called `typo` in the current directory was executed; it now
  says there is no such program and stops.
- `unpin man php phar` handed you the manual for `phar`, a command this binary
  does not contain. Only the manuals of the four programs it answers to are
  embedded now.
- `nix build` downloaded 69 MB to hand over a 33 MB binary. PHP bakes its
  install paths into the executable and Nix read them as a dependency on the
  build tree; the binary reaches none of them, and the download is now the
  binary itself.
