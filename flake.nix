{
  description = "PHP 8.4 (php + php-cgi + phpdbg + php-fpm) as a single self-contained binary";

  nixConfig = {
    extra-substituters = [ "https://unpins.cachix.org" ];
    extra-trusted-public-keys = [ "unpins.cachix.org-1:DDaShjbZ8VvcqxeTcAU3kV9vxZQBlyb7V/uLBHfTynI=" ];
  };

  inputs.unpins-lib.url = "github:unpins/nix-lib";

  # PHP CLI as ONE static binary. nixpkgs' `php` is a symlinkJoin/buildEnv that
  # loads extensions as runtime `.so` files (out-of-tree, via phpize) and wraps
  # bin/php with a PHP_INI_SCAN_DIR store path — both incompatible with a single
  # relocatable binary. So we take the raw `./configure` build (`.unwrapped`)
  # and compile a curated extension set IN-TREE (real top-level configure
  # flags) atop `--disable-all`; the four sapis fold into one binary.
  # PHP's stdlib is C, so — like lua — there is no tree of `.php` files to embed.
  #
  # IMPORTANT (eval blowup): do NOT route php through `pkgsStatic.php84`. The
  # static *overlay* re-instantiates php's whole extension fixpoint
  # (php-packages.nix's `phpPackage = phpWithExtensions` self-reference) and the
  # evaluator OOMs (>40 GB, unbounded). Instead we stay in the NON-static package
  # set and swap only the derivation's `stdenv` to the engine's (`engStdenv`)
  # via `.override` — php-packages then resolves once in the non-overlaid
  # fixpoint (cheap, ~1 s) while the core build still links static-musl. Individual static
  # deps (`pkgsStatic.curl`, …) are fine to reference; only php's own attribute
  # triggers the recursion.
  outputs = { self, unpins-lib }:
    let
      ulib = unpins-lib.lib;

      # The programs of the .exe, declared to CI. Its dispatcher is the
      # hand-written unpin_dispatch_win.c, not rendered from this table.
      winTable = ulib.multicallTable {
        name = "php";
        applets = [ { name = "php"; } { name = "php-cgi"; } { name = "phpdbg"; } ];
      };

      # PHP is C; build it under the unpin-llvm engine (clang/lld, static musl,
      # single multicall binary). Its deps stay ordinary pkgsStatic `.a`s (built
      # by the set-wide engine swap) linked as external native archives.
      #
      # LTO is OFF. PHP ships opcache's JIT — a runtime machine-code generator.
      # clang-21's whole-program LTO has a codegen-miscompile class (sox prints
      # "SoX v(null)"; the darwin ffmpeg teardown SIGSEGV — llvm/llvm-project
      # #186922 / ziglang/zig#20198) that bites silently. A miscompiled JIT
      # generator would corrupt emitted code only on hot paths, invisible to a
      # trivial smoke. LTO is an optimization, not required for the single-binary
      # fold, so drop it for the whole package; revisit only behind a
      # JIT-exercising correctness gate.
      # cxx = true: intl is C++ (on top of ICU, itself C++).
      engStdenv = pkgs:
        let sp = pkgs.pkgsStatic; in
        ulib.unpinAdapterStdenv {
          inherit pkgs;
          target = sp.stdenv.hostPlatform.config;
          native = pkgs.stdenv.buildPlatform.system == pkgs.stdenv.hostPlatform.system;
          cxx = true;
          lto = false;
          captureLinks = true;
        };

      mkPhp = pkgs:
        let
          s = pkgs.pkgsStatic;
          lib = pkgs.lib;

          # darwin static-link iconv shim. The pkgsStatic darwin C libs PHP links
          # (libxml2, gettext's libintl, the iconv ext) are compiled against a
          # plain <iconv.h> and reference _iconv/_iconv_open/_iconv_close, but the
          # only *static* libiconv on darwin (GNU "libiconvReal") exports only the
          # renamed _libiconv* symbols, and the SDK's plain-symbol libiconv is
          # dylib-only (a load command the darwin allow-list rejects). This leaf
          # archive defines the plain symbols as forwarders to _libiconv* (see
          # iconv_compat.c); linking it + the static GNU libiconv resolves every
          # iconv reference with no dylib dependency. Built only where it's used.
          iconvCompat = s.stdenv.mkDerivation {
            name = "iconv-compat";
            dontUnpack = true;
            buildPhase = ''
              runHook preBuild
              $CC -O2 -fvisibility=default -c ${./iconv_compat.c} -o iconv_compat.o
              $AR rcs libiconvcompat.a iconv_compat.o
              runHook postBuild
            '';
            installPhase = ''
              runHook preInstall
              mkdir -p "$out/lib"
              cp libiconvcompat.a "$out/lib/"
              runHook postInstall
            '';
          };

          extConfigure = [
            # configure otherwise adds `-Wl,-rpath,<dir>` for every library
            # directory. A static ELF has no dynamic section to keep them in, but
            # Mach-O does: the darwin binary carried an LC_RPATH per store path,
            # dragging the whole build closure along with it.
            "--disable-rpath"
            # zero-dep builtins
            "--enable-bcmath"
            "--enable-calendar"
            "--enable-ctype"
            "--enable-exif"
            "--enable-fileinfo"
            "--enable-filter"
            "--enable-ftp"
            "--enable-mbstring"
            "--enable-pcntl"
            "--enable-posix"
            "--enable-sockets"
            "--enable-pdo"
            "--enable-session"
            "--enable-tokenizer"
            "--enable-phar"
            # opcache + JIT, built STATICALLY into the binary. PHP's
            # ext/opcache/config.m4 hardcodes `ext_shared=yes` ("dnl Always build
            # as shared extension"), so a plain --enable-opcache still emits a
            # zend_extension .so (opcache.la) that can't link under the static-only
            # stdenv. static_opcache_84.patch flips that line to `ext_shared=no`
            # (static-php-cli's patch) so opcache compiles in-tree. opcache is
            # the #1 perf feature for the long-running fpm/cgi sapis (SHM opcode
            # cache shared across workers); for the CLI it only helps via a
            # configured opcache.file_cache, but it's cheap to carry. JIT stays on
            # (default); its host codegen tools (minilua, gen_ir_fold_hash) need
            # BUILD_CC set — see preConfigure.
            "--enable-opcache"
            # libxml2-backed (the base `libxml` ext must be on first; the
            # others depend on it, and --disable-all turned it off)
            "--with-libxml"
            "--enable-dom"
            "--enable-simplexml"
            "--enable-xml"
            "--enable-xmlreader"
            "--enable-xmlwriter"
            "--enable-soap"
            # with-dep builtins
            "--with-openssl"
            "--with-curl=${s.curl.dev}"
            "--with-zlib"
            "--with-iconv"
            "--with-gmp=${gmp.dev}"
            "--with-gettext=${s.gettext}"
            "--with-sodium"
            "--with-bz2=${s.bzip2.dev}"
            "--with-sqlite3=${sqlite.dev}"
            "--with-pdo-sqlite=${sqlite.dev}"
            "--with-readline=${s.readline.dev}"
            "--with-zip"
            # MySQL/MariaDB through PHP's own client (mysqlnd), no libmysqlclient.
            "--enable-mysqlnd"
            "--with-mysqli=mysqlnd"
            "--with-pdo-mysql=mysqlnd"
            # System V IPC and shared memory.
            "--enable-sysvsem"
            "--enable-sysvshm"
            "--enable-sysvmsg"
            "--enable-shmop"
            # PostgreSQL through libpq.
            "--with-pgsql"
            "--with-pdo-pgsql"
            # Images through PHP's bundled libgd.
            "--enable-gd"
            "--with-jpeg"
            "--with-webp"
            "--with-freetype"
            "--with-avif"
            "--enable-gd-jis-conv"
            # Unicode and locales (Normalizer, Collator, IntlDateFormatter, …).
            "--enable-intl"
            # LDAP directories through OpenLDAP's client; SASL binds on Linux,
            # as in nixpkgs.
            "--with-ldap"
            "LDAP_DIR=${s.openldap.dev}"
            "LDAP_INCDIR=${s.openldap.dev}/include"
            "LDAP_LIBDIR=${s.openldap.out}/lib"
            # generic.nix bakes PROG_SENDMAIL=${system-sendmail}/bin/sendmail (a
            # store path mail() would exec). Repoint to the conventional system
            # location so the relocatable binary carries no store ref; overridable
            # at runtime via the sendmail_path ini. The store flag itself is
            # filtered out below, or system-sendmail stays a build input.
            "PROG_SENDMAIL=/usr/sbin/sendmail"
          ] ++ lib.optionals s.stdenv.hostPlatform.isLinux [
            "--with-ldap-sasl"
          ];

          # Darwin-engine CC_FOR_BUILD fix. Several autotools/autosetup deps run a
          # build-host codegen bootstrap that probes CC_FOR_BUILD (gmp's gen tool;
          # sqlite's autosetup jimsh0 via autosetup-find-tclsh). pkgsStatic
          # (host≠build) leaves CC_FOR_BUILD at the vanilla darwin cc wrapper, but
          # under the engine that wrapper drives the ELF `ld.lld` and can't emit a
          # runnable Mach-O host tool → the probe fails (gmp: "Specified
          # CC_FOR_BUILD doesn't seem to work"; sqlite: silent — jimsh0 build is
          # `2>/dev/null >/dev/null`, then "No working C compiler", exit 1). Pin
          # CC_FOR_BUILD to $CC: on a native darwin build (every shipped darwin
          # target is build==host) the engine cc IS the build-host compiler and
          # links via ld64.lld. darwin-only → linux deps stay byte-identical. (The
          # local aarch64 cross-helper can't run these gen tools regardless — CI
          # macos-14 native is the source of truth for aarch64-darwin.)
          withDarwinBuildCC = drv:
            if s.stdenv.hostPlatform.isDarwin
            then drv.overrideAttrs (o: {
              preConfigure = (o.preConfigure or "") + ''
                export CC_FOR_BUILD=$CC
              '';
            })
            else drv;

          gmp = withDarwinBuildCC (s.gmp.overrideAttrs (o:
            lib.optionalAttrs s.stdenv.hostPlatform.isDarwin {
              # gmp's hand-written x86_64 mpn assembly (x86_64_add_n.o/sub_n.o)
              # emits a rel8 BRANCH the Mach-O ld64.lld rejects at the static-lib
              # link ("BRANCH relocation has width 1 bytes, but must be 4"). Linux
              # ELF lld relaxes it, so this is darwin-only; drop to gmp's generic
              # C mpn (same as gmp on arches without an asm path — functionally
              # identical, marginally slower bignum, nothing disabled). Linux keeps
              # the assembly, byte-identical. --disable-fat too: nixpkgs sets
              # --enable-fat (runtime per-CPU asm dispatch), which configure
              # refuses to combine with --disable-assembly ("when doing a fat
              # build, disabling assembly will not work"); dropping fat leaves the
              # plain generic-C build.
              configureFlags = (o.configureFlags or [ ])
                ++ [ "--disable-fat" "--disable-assembly" ];
            }));

          sqlite = withDarwinBuildCC s.sqlite;

          # gd's AVIF: libavif with its aom (encode) and dav1d (decode) codecs,
          # through nix-lib's static fixes, as the avif package builds it.
          libavif = ulib.nativeFixes.libavif (s.extend (final: prev:
            { libyuv = ulib.nativeFixes.libyuv prev; }
            // lib.optionalAttrs s.stdenv.hostPlatform.isDarwin {
              dav1d = ulib.nativeFixes.dav1d prev;
            }));

          # nixpkgs picks libpq's CFLAGS by `cc.isClang`, which the engine cc
          # does not claim, so darwin gets the GNU ld `-Wl,--gc-sections` and
          # configure's first test link fails ("C compiler cannot create
          # executables"). libpq installs only a static archive, so the flag
          # does nothing there anyway.
          libpq =
            if s.stdenv.hostPlatform.isDarwin
            then s.libpq.overrideAttrs (o: {
              env = o.env // {
                CFLAGS = lib.replaceStrings [ " -Wl,--gc-sections" ] [ "" ] o.env.CFLAGS;
              };
            })
            else s.libpq;

          extInputs = [
            s.curl
            s.openssl
            s.zlib
            s.libxml2
            sqlite
            s.oniguruma
            s.readline
            gmp
            s.gettext
            s.libsodium
            s.bzip2
            s.libzip
            s.pcre2
            s.libiconv
            libpq
            s.libpng
            s.libjpeg
            s.libwebp
            s.freetype
            libavif
            s.icu
            s.openldap
          ] ++ lib.optionals s.stdenv.hostPlatform.isLinux [
            s.cyrus_sasl
          ];

          # Build the wrapper from the NON-static set, overriding only the
          # stdenv (-> static musl) and the generic.nix named deps that we link.
          # The sapis are chosen through the *generic args* (cleaner than
          # filtering configureFlags by string), which also brings or drops
          # their deps: acl for fpm, no pear install step.
          php = pkgs.php84.override {
            stdenv = engStdenv pkgs;
            pcre2 = s.pcre2;
            curl = s.curl;
            # fpm's listen.acl_users (ACLs on the unix socket), as in nixpkgs.
            acl = s.acl;
            libxml2 = s.libxml2;
            # argon2Support off: both libargon2 (password_hash Argon2) and
            # libsodium (--with-sodium) vendor the same upstream argon2 and export
            # `argon2id_hash_raw` &c. — a duplicate-definition clash that only bites
            # at static link. Keep sodium (a whole modern-crypto ext, and it still
            # exposes argon2 via sodium_crypto_pwhash); password_hash() keeps its
            # bcrypt default. Dropping sodium instead would lose far more.
            argon2Support = false;
            # The three extra CLI-adjacent sapis are each their own static ELF/
            # Mach-O (sapi/cgi/php-cgi, sapi/fpm/php-fpm, sapi/phpdbg/phpdbg), built
            # from the same tree. cgi (also FastCGI) and phpdbg link clean on every
            # target. fpm is a POSIX daemon (fork/signals/setuid) -> Linux + darwin
            # (no Windows/cosmo). mkPhp is only ever instantiated for the native
            # Linux and darwin targets (Windows goes through the lib's separate
            # windowsBuild path), so enabling it unconditionally here is correct;
            # the multicall makefile + dispatcher fold fpm in only when its objects
            # exist, so a future cosmo reuse degrades gracefully. pear stays OFF:
            # it's not a sapi but a package manager (a tree of .php scripts + a
            # runtime phpize/compiler) — incompatible with a single self-contained
            # binary.
            cgiSupport = true;
            fpmSupport = true;
            pearSupport = false;
            phpdbgSupport = true;
            systemdSupport = false;
            valgrindSupport = false;
          };
        in
        # `.unwrapped` is the raw ./configure derivation. Layer the curated
        # extension set on top of its `--disable-all` base.
        php.unwrapped.overrideAttrs (old: {
          # `--with-config-file-path` defaults to `$prefix/lib`, so `php -i`
          # reported the php.ini path as a /nix/store directory that does not
          # exist on a user's machine -- every php.ini (timezone, memory_limit,
          # error_reporting) was silently ignored. /etc is where PHP looks on
          # every distro; the scan dir follows the same convention. Same class as
          # e2fsprogs' mke2fs.conf and mtools' --sysconfdir.
          configureFlags = builtins.filter (f: !lib.hasPrefix "PROG_SENDMAIL=" f)
            (old.configureFlags or [ ]) ++ extConfigure ++ [
            "--with-config-file-path=/etc"
            "--with-config-file-scan-dir=/etc/php.d"
          ];
          buildInputs = (old.buildInputs or [ ]) ++ extInputs;

          # PHP's fopencookie seeker test can't run under cross (pkgsStatic =
          # glibc-build -> musl-host), so configure guesses from the host triple:
          # `*linux* => off64_t`. That's a glibc assumption — modern musl (1.2.4+)
          # dropped off64_t, so cast.c fails to compile. Preset the autoconf cache
          # var to pick the off_t seeker instead. Applies to every musl target.
          php_cv_type_cookie_off64_t = "no";

          # opcache's shared-memory detection uses AC_RUN tests, which can't execute
          # under cross-compilation. Its built-in cross fallback guesses `yes` only
          # for `*linux*` hosts, so a darwin cross (e.g. the x86_64-darwin ->
          # aarch64-darwin compile-check) guesses `no` for every backend and bails
          # with "No supported shared memory caching support". macOS does support
          # anonymous-mmap shared memory (the native darwin build detects it at
          # run time), so preset the cache var. Native builds re-confirm it by
          # running the test; this only supplies the answer the cross host can't.
          php_cv_shm_mmap_anon = "yes";

          # ZEND_CHECK_ALIGNMENT is another AC_RUN test, and its cross fallback is
          # a hardcoded `(size_t)8 (size_t)3 0` — right for every 64-bit target and
          # for armv7l (ARM EABI aligns `double` to 8), wrong for i686, where the
          # i386 SysV ABI aligns `double` to 4, so __alignof__ of Zend's probe union
          # {void*, double, long} is 4 and LOG2 is 2. Measured with clang -target
          # across all nine shipped targets: i686 is the only 4; x86_64, i686's
          # 32-bit sibling armv7l, aarch64, riscv64, ppc64le, the mingw x86_64 and
          # both darwins are all 8.
          #
          # This is not a tuning knob. zend_weakrefs keys the weak-reference
          # registry by `(uintptr_t)object >> ZEND_MM_ALIGNMENT_LOG2` and rebuilds
          # the pointer with `key << ZEND_MM_ALIGNMENT_LOG2`, so a LOG2 one too
          # large silently drops bit 2 of every object address. Objects that happen
          # to land 8-aligned survive; the ones at 4 (mod 8) come back as a pointer
          # 4 bytes off and the first dereference segfaults. That is the i686
          # WeakMap crash: `$a[$b] = 1; var_dump($a)` with `$b` a WeakMap,
          # WeakReference or SplObjectStorage (the classes the registry tracks)
          # dies, while a plain stdClass key survives. Control: the same PHP 8.4.21
          # built natively for i686 (where the AC_RUN test does run) prints fine
          # under both gcc and clang 21.
          # Set for every target, not just i686: an empty value would look "cached"
          # to AC_CACHE_CHECK and define ZEND_MM_ALIGNMENT to nothing, so the
          # non-i686 branch has to carry the real answer rather than be omitted.
          php_cv_align_mm =
            if s.stdenv.hostPlatform.isx86_32
            then "(size_t)4 (size_t)2 0"
            else "(size_t)8 (size_t)3 0";

          # Static opcache+JIT. opcache is a zend_extension, not a regular module:
          # flipping config.m4's `ext_shared=yes` alone makes genif emit a bogus
          # `phpext_opcache_ptr` reference (build error). Upstream PHP 8.4 still
          # only supports opcache as a runtime .so, so we vendor static-php-cli's
          # `static_opcache_84.patch`, which (a) skips opcache in
          # build/order_by_dep.awk so it's left out of the static module table,
          # (b) renames `zend_extension_entry` -> `opcache_zend_extension_entry`
          # for the static case and guards `ZEND_EXTENSION()` behind
          # COMPILE_DL_OPCACHE, (c) comments out `ext_shared=yes` + AC_DEFINEs
          # HAVE_OPCACHE, (d) registers the zend_extension at startup via a new
          # zend_load_static_extensions() in main/main.c, and (e) makes the IR
          # gdb-jit symbols static to avoid a duplicate-symbol clash. ./buildconf
          # (in preConfigure) regenerates configure so the AC_DEFINE takes effect.
          # Source: github.com/crazywhalecc/static-php-cli, branch v3, commit
          # 14bfb4198a88, src/globals/patch/php-src-patches/static_opcache_84.patch
          # (byte-identical). Drop it when nixpkgs moves `php` to 8.5, where
          # opcache is always compiled in. The other two are ours; each says why
          # in its header.
          patches = (old.patches or [ ]) ++ [
            ./static_opcache_84.patch
            ./opcache-jit-arm64-host-alias.patch
            ./readline-cli-static-shell-callbacks.patch
          ];

          # Multicall: drop the dispatcher + the relink makefile into the tree.
          preBuild = (old.preBuild or "") + ''
            cp ${./unpin_dispatch.c} unpin_dispatch.c
            cp ${./unpin-multicall.mk} unpin-multicall.mk
          '';

          # After the normal build links the four standalone sapis, relink them
          # into ONE binary (renamed mains + shared core + dispatcher) and put it
          # where `make install` expects the cli, so it installs as bin/php.
          postBuild = (old.postBuild or "") + ''
            make -f Makefile -f unpin-multicall.mk unpin-multicall
            cp -f unpin-php-multi sapi/cli/php
            touch sapi/cli/php
          '';

          # The standalone php-cgi/php-fpm/phpdbg that `make install` drops are now
          # redundant — replace each with a symlink to the multicall php, which
          # dispatches on argv[0]. (php-fpm may land in sbin on some layouts.)
          postInstall = (old.postInstall or "") + ''
            for a in php-cgi php-fpm phpdbg; do
              if [ -e "$out/bin/$a" ] && [ ! -L "$out/bin/$a" ]; then
                rm -f "$out/bin/$a"; ln -s php "$out/bin/$a"
              fi
              if [ -e "$out/sbin/$a" ] && [ ! -L "$out/sbin/$a" ]; then
                rm -f "$out/sbin/$a"; ln -s ../bin/php "$out/sbin/$a"
              fi
            done
            # `make install` also drops the `phar` CLI tool: a PHAR archive
            # (phar.phar — PHP bytecode, not a C main()) plus a `phar` symlink. Its
            # `#!` shebang hardcodes the build-time store path to bin/php, so it is
            # NOT relocatable (breaks once the binary leaves the store). It is not a
            # sapi and can't join the multicall ELF; the Phar *extension* is already
            # compiled in (--enable-phar), so `Phar::` works from PHP code. Drop the
            # non-relocatable command-line wrapper from the shipped binary.
            rm -f "$out/bin/phar" "$out/bin/phar.phar"
            # And their manuals with them. The man pages are embedded wholesale
            # from this output, so leaving these two behind ships `unpin man php
            # phar` — a manual for a command the binary does not have.
            rm -f "$out/share/man/man1/phar.1"* "$out/share/man/man1/phar.phar.1"*
          '';

          # Static link needs every transitive dep on the line in order — but
          # PHP's PKG_CHECK_MODULES uses plain `$PKG_CONFIG --libs`, emitting only
          # the top-level `-lcurl`/`-lzip`/`-lxml2` and dropping each .pc's
          # Libs.private (curl's nghttp2/3, ngtcp2, brotli, idn2, psl, ssh2, zstd,
          # ssl…; libzip's bz2/lzma/zstd; libxml2's lzma/z). Append `--static` to
          # the nixpkgs-exported PKG_CONFIG so every probe pulls the full private
          # chain (with correct -L and ordering) in one shot.
          preConfigure = (old.preConfigure or "") + ''
            export PKG_CONFIG="''${PKG_CONFIG:-pkg-config} --static"

            # PHP guards against blowing the C stack (deep recursion, nested
            # object comparison) and raises "Maximum call stack size reached"
            # instead of dying. The whole feature hangs on one configure probe
            # that RUNS a program to see which way the stack grows — and under
            # pkgsStatic build != host, so autoconf cannot run it and takes the
            # cross branch, which answers "no". The guard was compiled out of
            # every binary we ship: measured, `zend.max_allowed_stack_size` did
            # not even exist as a setting, and on a normal 8 MB stack deep
            # recursion SEGFAULTED where nixpkgs' php raises the error. The
            # stack grows downwards on every platform in this catalog, so
            # answer the probe.
            export php_cv_have_stack_limit=yes
          ''
          # darwin static link needs two things PHP's own configure won't supply:
          #
          #  1. Frameworks. libcurl's Curl_macos_init (proxy detection, always
          #     compiled in) references CFRelease / SCDynamicStoreCopyProxies, i.e.
          #     the CoreFoundation + SystemConfiguration frameworks. curl's
          #     libcurl.pc lists these in Libs.private, but PHP's PHP_EVAL_LIBLINE /
          #     PHP_CHECK_LIBRARY silently drop `-framework X` tokens (their case
          #     statement only matches -l/-L/-R/-Wl), so the curl probe — and later
          #     the multicall relink — fail with undefined CF/SC symbols.
          #
          #  2. The iconv shim + static GNU libiconv. libxml2 / libintl / the iconv
          #     ext reference plain _iconv* but only the renamed _libiconv* exists
          #     in a static archive on darwin; iconvCompat bridges the two (see its
          #     definition above). Put the shim archive *before* libiconvReal so the
          #     plain symbols resolve from the shim and its _libiconv* calls resolve
          #     from GNU libiconv — all static, no iconv dylib load command.
          #
          # Both go through LDFLAGS, which PHP uses for conftests and bakes into the
          # generated Makefile's $(LDFLAGS), so unpin-multicall.mk picks them up too.
          # macOS resolves -framework and archives regardless of link position.
          + lib.optionalString s.stdenv.hostPlatform.isDarwin ''
            # libresolv: php's ext/standard/dns.c (dns_get_record/checkdnsrr/
            # getmxrr) needs the macOS resolver — dns_search + the res_9_*/dn_expand
            # family. These live ONLY in libresolv, not libSystem. The pre-engine
            # (full-SDK) build linked nixpkgs' STATIC `libresolv.a` (its `-lresolv`
            # conftest resolved to the static archive), so the symbols were embedded
            # and the binary carried NO libresolv load command — which is what keeps
            # it inside the darwin portability allow-list (libSystem/frameworks/
            # libobjc only; libresolv.9.dylib would be rejected). Link the same
            # static archive here. (An earlier engine attempt linked the host SDK's
            # libresolv.tbd — a DYLIB stub — which added a `/usr/lib/libresolv.9.dylib`
            # load command the allow-list rejects; the static .a is the fix.)
            export LDFLAGS="-framework CoreFoundation -framework CoreServices -framework SystemConfiguration -L${s.darwin.libresolv}/lib -lresolv -L${iconvCompat}/lib -liconvcompat -L${lib.getLib s.libiconvReal}/lib -liconv ''${LDFLAGS:-}"
            # ext/iconv.c, when it detects GNU libiconv (HAVE_LIBICONV, via the
            # _libiconv_version probe), `#undef`s any iconv->libiconv rename and
            # then calls the *plain* iconv() — which needs the included <iconv.h>
            # to declare plain iconv after that #undef. Whether `#include <iconv.h>`
            # resolves to the Apple/SDK header (declares plain iconv) or GNU
            # libiconv's (`#define iconv libiconv`, declares only libiconv) depends
            # on the wrapped toolchain's injected search paths and flips between
            # native and cross — so neither the plain-iconv nor the libiconv path
            # is reliable. Sidestep it: force the impl to "unknown" so HAVE_LIBICONV
            # stays undefined and iconv.c never `#undef`s. The source then uses the
            # `iconv` token verbatim, which resolves under *either* header (GNU's
            # macro rewrites it to libiconv -> _libiconv in the static GNU archive;
            # the plain header leaves it iconv -> _iconv via the iconvCompat shim).
            # Cosmetic only: phpinfo reports the iconv impl as "unknown".
            export php_cv_iconv_implementation=unknown
            # ext/standard/dns.c needs <resolv.h> + <arpa/nameser.h> for PHP's
            # real DNS resolver (dns_get_record / checkdnsrr / getmxrr / dns_get_mx).
            # The nixpkgs apple-sdk that the engine pins as SDKROOT is a trimmed
            # subset that omits exactly those two headers (verified: absent from
            # apple-sdk-14.4, and nixpkgs ships them nowhere for darwin) — so the
            # SDK-always base needs supplementing here. Both build hosts (the local
            # Mac builder and GHA macos-14) carry a full macOS SDK, and the resolver
            # headers are decades-stable, so fill the gap from the host SDK. Use
            # -idirafter (LOWEST search priority) so the pinned apple-sdk stays
            # authoritative for every header it does ship; the host SDK is consulted
            # only for the two it lacks. darwin-only. (Same trimmed-SDK gap tmux
            # sidesteps by stripping the include — php can't, it uses the resolver.)
            # Injected via CPPFLAGS (php bakes it into the Makefile's compile line,
            # the same channel the darwin LDFLAGS above uses) — the engine darwin
            # cc-wrapper does not honor NIX_CFLAGS_COMPILE. `env -u` strips the
            # build's DEVELOPER_DIR / SDKROOT (both point at the pinned nixpkgs SDK),
            # so `xcrun --show-sdk-path` resolves the HOST's full SDK via xcode-select
            # instead of the trimmed one — portable across the CLT layout on the
            # local Mac builder and the Xcode layout on GHA macos-14.
            export CPPFLAGS="-idirafter $(/usr/bin/env -u DEVELOPER_DIR -u SDKROOT /usr/bin/xcrun --show-sdk-path)/usr/include ''${CPPFLAGS:-}"
          ''
          # Engine (Linux/musl): the C++ runtime is libc++, and PHP_REQUIRE_CXX
          # (intl) hardcodes `-lstdc++`, which no engine target has: every
          # configure link test after intl's check then fails. generic.nix
          # makes the same swap on darwin. `-lc++` also makes the engine's link
          # driver (unpin_musl.cpp wantsCxx) emit its `--start-group -lc++
          # -lc++abi -lunwind …` group, which carries the _Unwind_Backtrace /
          # _Unwind_GetCFA that opcache's JIT and Zend/zend_call_stack.c call
          # (libgcc supplied them under gcc). LDFLAGS is baked into the
          # Makefile's $(LDFLAGS), so the four sapi links AND
          # unpin-multicall.mk's relink all pick it up.
          + lib.optionalString s.stdenv.hostPlatform.isLinux ''
            substituteInPlace configure --replace-fail "-lstdc++" "-lc++"
            export LDFLAGS="-lc++ ''${LDFLAGS:-}"
          ''
          + ''
            # JIT's host codegen tools (minilua, gen_ir_fold_hash) compile and run
            # on the BUILD host, so configure probes for a second, build-machine
            # compiler: under `cross_compiling`, `AC_CHECK_PROGS(BUILD_CC, [gcc
            # clang c99 c89 cc cl])`, falling back to the literal "none".
            #
            # This export predates the engine, when the failure was that fallback
            # ("none: command not found") because a gcc cross put only
            # triple-prefixed names in PATH. Under the engine the failure is the
            # opposite and quieter: the engine cc ships BARE `gcc`/`clang`/`cc`
            # (they are the same wrapper with a baked `-target`), so the probe
            # finds `gcc` on the first candidate and hands the build-host tools a
            # compiler that emits TARGET code. Both ways the export is the fix,
            # and the probe honors it — autoconf short-circuits the search with
            # `ac_cv_prog_BUILD_CC="$BUILD_CC" # Let the user override the test.`
            #
            # nix-lib presets BUILD_CC too, but only where meson can mislabel the
            # build cpu (aarch32/i686 hosts) and only with `:=`; a package's own
            # preConfigure runs BEFORE preConfigureHooks, so this one wins on
            # every host and keeps covering the ones that gate out.
            # (Emits target-arch dasm headers via IR_TARGET, so correct cross too.)
            export BUILD_CC=${pkgs.buildPackages.stdenv.cc}/bin/cc
          '';

          # PHP's own suite, restricted to the engine and the language tests:
          # 5600 tests in 11 seconds, all green under static musl and the
          # engine — and the first thing a codegen miscompile would take down.
          # The extension suites stay out: 9 of their ~14 900 tests fail for
          # reasons that are musl's or nixpkgs' rather than defects (musl's
          # gettext drops the `.UTF-8` of a locale name when it looks for a
          # catalog, pathconf is unimplemented, nixpkgs' libzip has no AES), and
          # pinning test names would go stale at the next PHP release.
          # run-tests.php exits non-zero on failure, so this needs no output
          # matching; by checkPhase time sapi/cli/php is already the multicall
          # binary.
          doCheck = pkgs.pkgsStatic.stdenv.buildPlatform.canExecute
            pkgs.pkgsStatic.stdenv.hostPlatform;
          # weakmap_weakness.phpt used to be deleted here on i686, where it
          # segfaulted. It was right and we were wrong: the crash was the
          # hardcoded ZEND_MM_ALIGNMENT cross fallback (see php_cv_align_mm
          # above), not a codegen defect. The test runs on every target now, and
          # it is the gate that keeps that fallback honest.
          checkPhase = ''
            runHook preCheck
            TEST_PHP_EXECUTABLE="$PWD/sapi/cli/php" NO_INTERACTION=1 SKIP_PERF_SENSITIVE=1 \
              "$PWD/sapi/cli/php" run-tests.php -q -j"''${NIX_BUILD_CORES:-4}" Zend tests
            runHook postCheck
          '';
        }
        # darwin: php's configure-generated `libtool` used to misdetect GNU ld —
        # the engine's ld64.lld advertises "compatible with GNU linkers" — and bake
        # ELF-spelled flag-specs (`--export-dynamic`, a per-libdir `--rpath`,
        # `--whole-archive`) that ld64.lld rejects, breaking every sapi link. It
        # detects darwin correctly since nix-lib 4302d17 wrapped ld64.lld in the
        # `-r` guard: `checking if the linker is GNU ld` went yes -> no, and the
        # three specs now arrive at their native-darwin values on their own. The
        # substitutions that forced them are therefore gone.
        #
        # What stays is the alarm. The misdetection is one linker banner away from
        # returning, and it does not fail here — it fails much later, at the sapi
        # link, as `unknown argument '--export-dynamic'`. So assert the OUTCOME
        # rather than patch the input: a spec spelled the GNU way is a hard error
        # at configure time. Checking the result also survives a respelling, which
        # the old `--replace-fail` patterns could not.
        # optionalAttrs (not a gated string) so the key is ABSENT on Linux — adding
        # even an empty `postConfigure=""` would perturb the Linux derivation hash.
        // lib.optionalAttrs s.stdenv.hostPlatform.isDarwin {
          postConfigure = (old.postConfigure or "") + ''
            if grep -nE '^(export_dynamic_flag_spec|hardcode_libdir_flag_spec|whole_archive_flag_spec)=.*(--export-dynamic|--rpath|--whole-archive)' libtool; then
              echo "libtool baked GNU linker specs on darwin: ld64.lld will reject them at the sapi link. See the comment above this check in flake.nix." >&2
              exit 1
            fi
          '';
        });
    in
    ulib.mkStandaloneFlake {
      inherit self;
      name = "php";
      # The darwin-engine gaps are each handled darwin-gated above (Linux stays
      # untouched): gmp's CC_FOR_BUILD and --disable-fat/assembly, sqlite's
      # CC_FOR_BUILD, the resolver headers and the static libresolv.a, and the
      # postConfigure assert against libtool's GNU-ld specs.
      engine = "unpin-llvm";
      dnsFallback = true; # resolves hostnames; opt into the Android DNS fallback
      # php folds its own sapis on BOTH halves (unpin-multicall.mk natively,
      # windows.nix for the `.exe`), so nix-lib emits no bitcode module; the
      # block is here to put the `.exe` on the engine too, instead of the
      # nixpkgs mingw-gcc cross, and to state the program list in one place.
      # fpm is a POSIX daemon — fork, signals, setuid — so it is not on windows.
      multicall = {
        windows = true;
        module = false;
        windowsTable = winTable;
        programs = [
          { name = "php"; }
          { name = "php-cgi"; }
          { name = "phpdbg"; }
          { name = "php-fpm"; supportedTarget = h: !(h.isWindows or false); }
        ];
      };
      # Four manuals ride along, one per program the binary answers to: php.1,
      # php-cgi.1, phpdbg.1 and php-fpm.8. The base installs two more, for the
      # `phar` tool that postInstall deletes; they go with it.
      # PHP bakes its install prefix into the binary nine times over — bindir,
      # libdir, sysconfdir, extension_dir and the rest — and Nix reads them as a
      # runtime reference to the build output, so `nix build` fetched that whole
      # 35 MB tree (php-fpm, php-cgi, phpdbg, configs, manuals) to hand over a
      # 33 MB binary that reaches none of it: the extension directory does not
      # even exist, and the ini path is already /etc. The `.exe` had two of its
      # own — gettext's locale root and curl's public-suffix list, both paths
      # that exist on no Windows machine — dragging a 113 MB closure behind a
      # 26 MB binary. The native binary carries the same two dead paths
      # (gettext's only on darwin).
      removeReferences = [ "php-static" "php-windows" "gettext" "publicsuffix" ];
      smoke = [ "-r" "echo 'php ' . (6 * 7);" ];
      smokePattern = "php 42";
      build = pkgs: mkPhp pkgs;
      # Windows (mingw-win32): cli+cgi+phpdbg multicall as one static php.exe,
      # 12 curated exts incl curl-over-Schannel + a statically-linked openssl
      # ext. No fpm (POSIX daemon). The whole win32 port lives in windows.nix.
      windowsBuild = pkgs: import ./windows.nix { inherit pkgs ulib; };
    };
}
