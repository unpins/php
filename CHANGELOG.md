# Changelog

## [Unreleased]

### Added

- Every extension nixpkgs enables by default is now built in: `mysqli` and
  `pdo_mysql` (through PHP's own MySQL client), `pgsql` and `pdo_pgsql`, `gd`
  (PNG, JPEG, WebP, AVIF, BMP and GIF, FreeType text, Japanese fonts), `intl`,
  `ldap`, `shmop` and the System V ones (`sysvmsg`, `sysvsem`, `sysvshm`).
  The one left out on Linux and macOS is `pdo_odbc`: unixODBC loads each
  database driver as a shared library at run time. The Windows binary has it,
  through Windows' own ODBC driver manager, and has all the others except the
  POSIX-only `pcntl`, `posix` and System V ones; its `ldap` binds with a
  password only, without SASL. `intl` carries ICU's locale data, so the
  binaries grow to about 83 MB.
- `php-fpm` honours `listen.acl_users` / `listen.acl_groups` (ACLs on its
  unix socket), as nixpkgs' php does.
- curl checks cookie domains against the Public Suffix List, as nixpkgs'
  curl does.

### Fixed

- `php -a` started no interactive shell: it answered "Interactive shell
  requires the readline extension" although readline is built in.
- Hostname lookups (`gethostbyname`, `fsockopen`, …) work on systems without
  `/etc/resolv.conf`, such as Android.
- The macOS binaries listed the Nix store directories of their build
  libraries as library search paths. Nothing was loaded from them, but
  `nix build` on a Mac fetched the whole build toolchain along with php.
- The Windows binary had only 21 of the extensions the Linux and macOS ones
  have. Besides the ones added above, it now has `bcmath`, `calendar`, `ctype`, `dom` (with the HTML5 parser),
  `exif`, `fileinfo`, `filter`, `ftp`, `libxml`, `Phar`, `readline` (so
  `php -a` edits lines and keeps history), `session`, `SimpleXML`, `soap`,
  `sockets`, `tokenizer`, `xml`, `xmlreader`, `xmlwriter`, `zlib`, and OPcache
  with the JIT.
- `gd`'s FreeType no longer looks for a HarfBuzz shared library at run time.
  It used one, when the system had it, to hint glyphs such as small caps and
  superscripts; that HarfBuzz is now built into the binary, so text drawn
  with `imagettftext()` no longer depends on what the system has installed.

## [8.4.25-1] - 2026-09-26

### Changed

- The Windows binary is now built by the same compiler as the Linux and macOS
  ones. It is about 29% smaller (26.0 MB to 18.4 MB); all three programs were
  checked under Wine — `php -v`, `php -r` arithmetic, `--unpin-program=php-cgi`
  and `phpdbg` by name — along with every one of the 21 extensions it loads
  (curl, openssl, mbstring, pcre, gmp, sodium, bz2, zip, iconv, gettext, hash,
  json, date, PDO/sqlite and the rest), each answering exactly what the
  previous binary answers.

  It now uses the Universal C Runtime, which is part of Windows 10 and later.
  On Windows 7 or 8.1 that runtime has to be installed first — it comes through
  Windows Update. The previous binary did not need it.

- `unpin install php` now also creates `php` itself, beside `php-cgi`,
  `phpdbg` and (off Windows) `php-fpm`. The list of names the binary carries
  is declared in one place now and names all of them.

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
