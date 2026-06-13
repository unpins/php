# php

[PHP 8.4](https://www.php.net/) — the popular general-purpose scripting language. A single self-contained binary (`php` + `php-cgi` + `phpdbg`, plus `php-fpm` on Linux/macOS), built natively for Linux, macOS, and Windows.

[![CI](https://github.com/unpins/php/actions/workflows/php.yml/badge.svg)](https://github.com/unpins/php/actions)
![Linux](https://img.shields.io/badge/Linux-✓-success?logo=linux&logoColor=white)
![macOS](https://img.shields.io/badge/macOS-✓-success?logo=apple&logoColor=white)
![Windows](https://img.shields.io/badge/Windows-✓-success?logo=windows&logoColor=white)

Part of the [unpins](https://unpins.org) catalog; install it with [`unpin`](https://github.com/unpins/unpin): `unpin install php`.

## Usage

Run the `php` program with [unpin](https://github.com/unpins/unpin):

```bash
unpin php script.php               # run a script
unpin php -r 'echo 6 * 7;'         # run a one-liner
unpin php -v                       # version banner
unpin php -m                       # list compiled-in extensions
unpin php -S localhost:8000        # built-in dev web server
```

To install it onto your PATH:

```bash
unpin install php
```

Installing also creates the other SAPIs alongside `php`:

```bash
php-cgi script.php                 # CGI / FastCGI
php-fpm                            # FastCGI Process Manager (Linux/macOS)
phpdbg -r script.php               # the interactive debugger
```

## Build locally

```bash
nix build github:unpins/php
./result/bin/php -v
```

Or run directly:

```bash
nix run github:unpins/php -- -r 'echo PHP_VERSION;'
```

The first invocation will offer to add the [unpins.cachix.org](https://unpins.cachix.org) substituter so most pulls come pre-built.

## Manual download

The [Releases](https://github.com/unpins/php/releases) page has standalone binaries for manual download.

## Build notes

- **Single multicall binary.** PHP's CLI-adjacent SAPIs — `php` (cli),
  `php-cgi` (cgi/FastCGI), `phpdbg` (debugger), and `php-fpm` (FastCGI process
  manager) — are each a separate `main()` built from the same source tree.
  They are folded into one binary at `$out/bin/php`; `php-cgi`/`phpdbg`/
  `php-fpm` are `argv[0]`-dispatch aliases. The bare/canonical `php` runs the
  cli; the dispatcher matches on the program name (path- and `.exe`-stripped,
  case-insensitive). `nm` confirms each SAPI defines only `main` (+ a couple of
  cgi header symbols), so the shared PHP core is compiled once, just those
  per-SAPI entry symbols are renamed, and the SAPIs link against the single
  core. `php-fpm` is a POSIX daemon (fork/signals/setuid), so it is **not**
  built on Windows.
- **Curated extension set, all in-tree.** nixpkgs' `php` is a `buildEnv` that
  loads extensions as out-of-tree `.so` files (via `phpize`) and wraps `bin/php`
  with a store-path `PHP_INI_SCAN_DIR` — both incompatible with one relocatable
  binary. We take the raw `./configure` build (`.unwrapped`), turn off the
  module loader, and compile a "scripting essentials" extension set **in-tree**
  atop `--disable-all`: bcmath, calendar, ctype, curl, dom, exif, fileinfo,
  filter, ftp, gettext, gmp, iconv, mbstring, openssl, pcntl, pdo+pdo_sqlite,
  phar, posix, session, simplexml, soap, sockets, sodium, sqlite3, tokenizer,
  xml/xmlreader/xmlwriter, zip, zlib, bz2, and more.
- **OPcache + JIT, statically linked in.** OPcache is normally a runtime
  `zend_extension` `.so`; we vendor static-php-cli's `static_opcache_84.patch`
  so it compiles in-tree, with JIT on. It's the #1 perf feature for the
  long-running fpm/cgi SAPIs; for the cli it helps via `opcache.file_cache`.
- **Zero store leaks.** A handful of compile-time data paths that would pin a
  `/nix/store` ref (openssl `OPENSSLDIR`, libxml2's default catalog, gettext's
  `LOCALEDIR`, the sendmail path, libpsl's suffix-list data file) are
  neutralized or repointed to conventional system locations. TLS certs come from
  `SSL_CERT_FILE` / the system trust store at runtime; `curl` is built with
  Schannel on Windows and OpenSSL elsewhere.
- **Static linking, per target.** Linux/macOS link static-musl / static against
  curated static deps; Windows is a from-scratch mingw-win32 port (the win32
  source compiled with mingw-gcc, no MSVC) producing a single self-contained
  `php.exe` (`otool -L` / imports show only system libraries).
- **No PEAR / phar wrapper.** PEAR is a package manager (a tree of `.php`
  scripts + a runtime `phpize`/compiler), and the `phar` CLI tool hardcodes a
  non-relocatable `#!` to the build's `bin/php` — neither ships. The Phar
  *extension* is compiled in, so `Phar::` works from PHP code.
