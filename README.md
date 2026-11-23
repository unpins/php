# php

[PHP](https://www.php.net/) — the general-purpose scripting language. A single self-contained binary, built natively for Linux, macOS, and Windows.

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

- **One binary.** `php` (the command line), `php-cgi` (CGI/FastCGI), `phpdbg`
  (the debugger) and `php-fpm` (the process manager) are the same file, which
  acts as whichever of them it is run as. `php-fpm` is a POSIX daemon
  (fork/signals/setuid) and is **not** built on Windows. Its systemd
  integration (`Type=notify`) is left out: it needs `libsystemd`, which nixpkgs
  marks as unsupported in static builds.
- **Extensions are compiled in, not loaded.** nixpkgs' `php` loads extensions as
  out-of-tree `.so` files and bakes a store path into `bin/php` — neither works
  in a single relocatable binary. Instead every extension nixpkgs enables by
  default (bcmath, curl, gd, intl, ldap, mysqli, pgsql, soap, sodium, zip, … —
  run `php -m`) is built statically into the binary, with OPcache + JIT on. The
  one exception is `pdo_odbc` on Linux and macOS: unixODBC loads each database
  driver as a shared library at run time, which a single self-contained binary
  cannot do. `intl` carries ICU's locale data, which roughly doubles the size
  of the binary.
- **Tests.** PHP's own suite runs on every build that can execute what it just
  produced, restricted to the engine and the language tests: 5600 tests, all
  green under static musl. The extension suites are not run. Nine of their
  ~14 900 tests do fail here, and they say what you would expect a static musl
  build to say: musl's `gettext` ignores the `.UTF-8` in a locale name when it
  looks for a translation catalog, so the tests' `en_US.UTF-8/` catalogs are
  not found (six tests); `posix_pathconf` is not implemented (two); and libzip,
  built as nixpkgs builds it, has no AES encryption (one). Pinning that list
  of names would go stale at the next PHP release.
- **TLS / certificates.** On Linux and macOS, OpenSSL trusts the host's
  certificates first: `SSL_CERT_FILE` / `SSL_CERT_DIR`, then the bundles and
  certificate directories the common distributions install. Only on a host with
  none of them does it fall back to the Mozilla roots built into the binary. On
  Windows, `curl` uses the system's Schannel.
- **Windows** is a mingw build of PHP's own `win32` sources (no MSVC); the `.exe`
  is self-contained, importing only system DLLs. It has the same extensions as
  Linux and macOS, OPcache + JIT and readline included, except `pcntl`, `posix`
  and the System V ones (`sysvmsg`, `sysvsem`, `sysvshm`), which exist only on
  POSIX systems. It adds `pdo_odbc`, through Windows' own ODBC driver manager.
  `ldap` binds with a password only, without SASL: nixpkgs' Cyrus SASL does not
  build for Windows.
- **No PEAR or `phar` wrapper.** PEAR is a runtime package manager and the `phar`
  tool hardcodes a non-relocatable path to `bin/php`; both are dropped. The Phar
  *extension* is compiled in, so `Phar::` still works from PHP.
