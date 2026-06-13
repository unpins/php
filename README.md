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

- **One multicall binary.** `php` (the cli) is the canonical name; `php-cgi`
  (cgi/FastCGI), `phpdbg` (the debugger), and `php-fpm` (the process manager)
  are folded into the same binary and dispatch on `argv[0]`. Each SAPI is a
  separate `main()` over the same core, so the core is linked once. `php-fpm` is
  a POSIX daemon (fork/signals/setuid) and is **not** built on Windows.
- **Extensions are compiled in, not loaded.** nixpkgs' `php` loads extensions as
  out-of-tree `.so` files and bakes a store path into `bin/php` — neither works
  in a single relocatable binary. Instead a curated set (bcmath, curl, dom, gmp,
  iconv, mbstring, openssl, pdo_sqlite, soap, sodium, zip, … — run `php -m`) is
  built statically into the binary, with OPcache + JIT on.
- **TLS / certificates.** `curl` uses Schannel on Windows and OpenSSL elsewhere;
  trust roots come from `SSL_CERT_FILE` / the system store at runtime, so no CA
  bundle or `/nix/store` path is baked in.
- **Windows** is a mingw build of PHP's own `win32` sources (no MSVC); the `.exe`
  is self-contained, importing only system DLLs.
- **No PEAR or `phar` wrapper.** PEAR is a runtime package manager and the `phar`
  tool hardcodes a non-relocatable path to `bin/php`; both are dropped. The Phar
  *extension* is compiled in, so `Phar::` still works from PHP.
