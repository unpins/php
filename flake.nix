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
  # relocatable binary. So we take the raw `./configure` build (`.unwrapped`),
  # turn off the non-CLI sapis, and compile a curated "scripting essentials"
  # extension set IN-TREE (real top-level configure flags) atop `--disable-all`.
  # PHP's stdlib is C, so — like lua — there is no tree of `.php` files to embed.
  #
  # IMPORTANT (eval blowup): do NOT route php through `pkgsStatic.php84`. The
  # static *overlay* re-instantiates php's whole extension fixpoint
  # (php-packages.nix's `phpPackage = phpWithExtensions` self-reference) and the
  # evaluator OOMs (>40 GB, unbounded). Instead we stay in the NON-static package
  # set and swap only the derivation's `stdenv` to `pkgsStatic.stdenv` via
  # `.override` — php-packages then resolves once in the non-overlaid fixpoint
  # (cheap, ~1 s) while the core build still links static-musl. Individual static
  # deps (`pkgsStatic.curl`, …) are fine to reference; only php's own attribute
  # triggers the recursion.
  outputs = { self, unpins-lib }:
    let
      ulib = unpins-lib.lib;

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
      # cxx = false: PHP is pure C. The libunwind dependency (see the -lc++ link
      # trigger in mkPhp's preConfigure) is pulled at LINK time via the driver's
      # wantsCxx detection, not this stdenv flag — the engine's link driver reads
      # `cxx` from the link ARGS (clang++/`-lc++`/`.cpp` inputs), so this param
      # only governs whether a C++ compiler is wired for compilation, which PHP
      # doesn't use.
      engStdenv = pkgs:
        let sp = pkgs.pkgsStatic; in
        ulib.unpinAdapterStdenv {
          inherit pkgs;
          target = sp.stdenv.hostPlatform.config;
          native = pkgs.stdenv.buildPlatform.system == pkgs.stdenv.hostPlatform.system;
          cxx = false;
          lto = false;
          captureLinks = true;
        };

      mkPhp = pkgs:
        let
          s = pkgs.pkgsStatic;
          lib = pkgs.lib;

          # The interactive CLI links readline -> ncurses(libtinfo), which bakes
          # the terminfo store path in (same leak lua hit). Curate a fallback
          # terminfo set into libtinfo.a + --disable-database.
          ncursesFB = ulib.embedFallbackTerminfoOnly s.ncurses;
          readlineFB = s.readline.override { ncurses = ncursesFB; };

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
            # stdenv. We flip that line to `ext_shared=no` in postPatch (the same
            # approach static-php-cli uses) so opcache compiles in-tree. opcache is
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
            "--with-curl=${curlNoPsl.dev}"
            "--with-zlib"
            "--with-iconv"
            "--with-gmp=${gmp.dev}"
            "--with-gettext=${s.gettext}"
            "--with-sodium"
            "--with-bz2=${s.bzip2.dev}"
            "--with-sqlite3=${sqlite.dev}"
            "--with-pdo-sqlite=${sqlite.dev}"
            "--with-readline=${readlineFB.dev}"
            "--with-zip"
            # generic.nix bakes PROG_SENDMAIL=${system-sendmail}/bin/sendmail (a
            # store path mail() would exec). Repoint to the conventional system
            # location so the relocatable binary carries no store ref; overridable
            # at runtime via the sendmail_path ini.
            "PROG_SENDMAIL=/usr/sbin/sendmail"
          ]
          # fpm's optional ACL feature (listen.acl_users on the unix socket) pulls
          # libacl. generic.nix adds the NON-static `acl` as a buildInput and
          # passes --with-fpm-acl, which would drag a dynamic libacl into the
          # static link. ACL-on-socket is marginal for a relocatable binary, so
          # turn it off (last --with/--without wins); fpm itself stays fully
          # functional. Revisit with pkgsStatic.acl if socket ACLs are ever wanted.
          ++ lib.optional pkgs.stdenv.hostPlatform.isLinux "--without-fpm-acl";

          # curl with psl off: libpsl bakes a store path to the public-suffix-list
          # data file (.dat) — a runtime store leak. PSL only refines cookie-domain
          # checks; dropping it removes the leak with negligible functional loss.
          curlNoPsl = s.curl.override { pslSupport = false; };

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

          extInputs = [
            curlNoPsl
            s.openssl
            s.zlib
            s.libxml2
            sqlite
            s.oniguruma
            readlineFB
            gmp
            s.gettext
            s.libsodium
            s.bzip2
            s.libzip
            s.pcre2
            s.libiconv
          ];

          # Build the wrapper from the NON-static set, overriding only the
          # stdenv (-> static musl) and the generic.nix named deps that we link.
          # Turning off the extra sapis through the *generic args* (cleaner than
          # filtering configureFlags by string) also drops their deps: no acl
          # (fpm), no pear install step.
          php = pkgs.php84.override {
            stdenv = engStdenv pkgs;
            pcre2 = s.pcre2;
            # Use the psl-disabled curl as php84's named `curl` dep too, not just
            # via the --with-curl flag below. generic.nix adds this attr as a
            # buildInput; if it stayed `s.curl` the link line would carry the
            # psl-enabled curl's libpsl (store-path .dat leak) alongside the
            # curlNoPsl we point configure at. Keeping both the named dep and the
            # flag on curlNoPsl means a single, leak-free curl on the line.
            curl = curlNoPsl;
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
        # `.unwrapped` is the raw ./configure derivation (bin/php only). Layer the
        # curated extension set on top of its `--disable-all` base.
        php.unwrapped.overrideAttrs (old: {
          # `--with-config-file-path` defaults to `$prefix/lib`, so `php -i`
          # reported the php.ini path as a /nix/store directory that does not
          # exist on a user's machine -- every php.ini (timezone, memory_limit,
          # error_reporting) was silently ignored. /etc is where PHP looks on
          # every distro; the scan dir follows the same convention. Same class as
          # e2fsprogs' mke2fs.conf and mtools' --sysconfdir.
          configureFlags = (old.configureFlags or [ ]) ++ extConfigure ++ [
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
          patches = (old.patches or [ ]) ++ [ ./static_opcache_84.patch ];

          # opcache JIT selects its IR backend by matching `$host_alias` — the RAW
          # --host value, not the config.sub-canonicalized `$host`. nixpkgs darwin
          # spells the arm64 triple `arm64-apple-darwin`, but config.m4 only matches
          # `aarch64*`, so IR_TARGET comes out EMPTY and the build emits a malformed
          # `-D -DIR_PHP` ("macro name must be an identifier"). (config.guess on a
          # native Apple-Silicon runner yields `aarch64-apple-darwin`, so this only
          # bites the nix arm64 spelling.) Teach the case to also accept `arm64*`.
          # buildconf (preConfigure) regenerates configure from this config.m4.
          postPatch = (old.postPatch or "") + ''
            substituteInPlace ext/opcache/config.m4 \
              --replace-fail '[aarch64*], [' '[aarch64*|arm64*], ['
          '';

          # Static link needs every transitive dep on the line in order — but
          # PHP's PKG_CHECK_MODULES uses plain `$PKG_CONFIG --libs`, emitting only
          # the top-level `-lcurl`/`-lzip`/`-lxml2` and dropping each .pc's
          # Libs.private (curl's nghttp2/3, ngtcp2, brotli, idn2, psl, ssh2, zstd,
          # ssl…; libzip's bz2/lzma/zstd; libxml2's lzma/z). Append `--static` to
          # the nixpkgs-exported PKG_CONFIG so every probe pulls the full private
          # chain (with correct -L and ordering) in one shot.
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
          '';

          preConfigure = (old.preConfigure or "") + ''
            export PKG_CONFIG="''${PKG_CONFIG:-pkg-config} --static"
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
          # Engine (Linux/musl): opcache JIT's zend_jit_unwind_cb and
          # Zend/zend_call_stack.c (HAVE_UNWIND, JIT/fiber stack-bounds probing)
          # call _Unwind_Backtrace + _Unwind_GetCFA. gcc/musl pulled these from
          # libgcc; the engine (compiler-rt, no libgcc) provides the _Unwind_*
          # API only in libunwind, and its link driver adds -lunwind ONLY when it
          # detects a C++ link (unpin_musl.cpp wantsCxx: argv0 "++", -lc++,
          # .cpp inputs). A bare `-lc++` on the link line flips that detection,
          # so the driver emits its `--start-group -lc++ -lc++abi -lunwind …`
          # group. The libc++/libc++abi archives stay inert (no C++ symbol is
          # referenced by this C binary — archive semantics link only libunwind's
          # _Unwind_* objects), so the fold gains exactly the unwinder gcc used to
          # supply, nothing more. LDFLAGS is baked into the Makefile's $(LDFLAGS),
          # so the four sapi links AND unpin-multicall.mk's relink all pick it up.
          + lib.optionalString s.stdenv.hostPlatform.isLinux ''
            export LDFLAGS="-lc++ ''${LDFLAGS:-}"
          ''
          + ''
            # JIT's host codegen tools (minilua, gen_ir_fold_hash) compile and run
            # on the BUILD host. Under pkgsStatic (a cross from the glibc build
            # host) configure's BUILD_CC probe finds no bare `cc`/`gcc` in PATH and
            # falls back to "none" -> "none: command not found". Point it at the
            # build-host compiler explicitly (emits target-arch dasm headers via
            # IR_TARGET, so this is correct cross too).
            export BUILD_CC=${pkgs.buildPackages.stdenv.cc}/bin/cc
          '';

          # A few compile-time default DATA-dir paths get baked into the binary as
          # store refs (the 0-ref gate rejects them): openssl's OPENSSLDIR
          # (${"$"}etc/etc/ssl/certs — an *empty* dir; nixpkgs rmdir's certs/private),
          # libxml2's default catalog (${"$"}out/etc/xml/catalog — also empty), and
          # (darwin only) gettext's libintl default LOCALEDIR (${"$"}gettext/share/
          # locale). None holds data the relocatable binary should pin: TLS certs
          # come from SSL_CERT_FILE / the system store at runtime (the documented
          # unpins precedence; full native-trust via libunpinca is the follow-up),
          # the XML catalog is a system concern, and gettext message catalogs are
          # selected by the script via bindtextdomain() (the baked LOCALEDIR is only
          # a fallback). Neutralize the refs the way openssl does its own self-ref —
          # remove-references-to rewrites the hash to a non-reference marker.
          nativeBuildInputs = (old.nativeBuildInputs or [ ])
            ++ [ pkgs.removeReferencesTo ];
          # Only the real multicall binary needs scrubbing; the sapi names are
          # symlinks to it.
          postFixup = (old.postFixup or "") + ''
            remove-references-to \
              -t ${lib.getOutput "etc" s.openssl} \
              -t ${lib.getLib s.libxml2} \
              -t ${lib.getOutput "out" s.gettext} \
              "$out/bin/php"
          '';
        }
        # darwin: the engine's ld64.lld advertises "compatible with GNU linkers",
        # so php's configure-generated `libtool` (its C/default tag) misdetects GNU
        # ld and bakes ELF-spelled linker flag-specs — `--export-dynamic` and a
        # per-libdir `--rpath` — which ld64.lld rejects (`unknown argument
        # '--export-dynamic'` / `'--rpath', did you mean '-rpath'`), breaking every
        # sapi link. The SAME libtool's C++ (CXX) tag detected darwin correctly and
        # left these specs empty — the native-darwin value. Reset the C-tag specs to
        # match: empty is what a real macOS libtool emits (Mach-O needs neither — a
        # fully-static all-in binary dlopen's no extension, and hardcoded runpaths
        # into /nix/store are meaningless). Also blank whole_archive_flag_spec (GNU
        # `--whole-archive`) so a convenience-archive link — e.g. the unpin-multicall
        # relink — can't reintroduce the gap. archive_cmds' `-soname` differs too but
        # only fires when building a *shared* lib, which this static build never does.
        # optionalAttrs (not a gated string) so the key is ABSENT on Linux — adding
        # even an empty `postConfigure=""` would perturb the Linux derivation hash.
        // lib.optionalAttrs s.stdenv.hostPlatform.isDarwin {
          postConfigure = (old.postConfigure or "") + ''
            substituteInPlace libtool \
              --replace-fail 'export_dynamic_flag_spec="\''${wl}--export-dynamic"' 'export_dynamic_flag_spec=""' \
              --replace-fail 'hardcode_libdir_flag_spec="\''${wl}--rpath \''${wl}\$libdir"' 'hardcode_libdir_flag_spec=""' \
              --replace-fail 'whole_archive_flag_spec="\''${wl}--whole-archive\$convenience \''${wl}--no-whole-archive"' 'whole_archive_flag_spec=""'
          '';
        });
    in
    ulib.mkStandaloneFlake {
      inherit self;
      name = "php";
      # unpin-llvm engine. All targets green: Linux (x86_64/i686/ppc64le/riscv64/
      # aarch64/armv7l) + Windows + darwin. The set-wide engine swap surfaced a
      # tail of darwin-engine gaps, all resolved darwin-gated (linux byte-
      # identical): gmp CC_FOR_BUILD + --disable-fat/assembly; sqlite autosetup
      # CC_FOR_BUILD; the trimmed apple-sdk's missing resolver headers (-idirafter
      # host SDK); the libtool GNU-ld misdetection that baked ELF `--export-dynamic`/
      # `--rpath` into the sapi links (postConfigure resets the C-tag flag-specs to
      # their native-darwin empty values — see below); and the resolver link — use
      # nixpkgs' STATIC libresolv.a (symbols embedded, no dylib load command) so the
      # binary stays inside the darwin portability allow-list, matching how the
      # pre-engine full-SDK build linked it (see the darwin LDFLAGS above).
      engine = "unpin-llvm";
      # php.1, php-cgi.1, phpdbg.1, phar.1 and phar.phar.1 -- the base installs
      # all five, and this is a cli+cgi+phpdbg multicall whose flags are worth a
      # man page. The opt-out here was never explained and never revisited since
      # the package's first commit.
      smoke = [ "-r" "echo 'php ' . (6 * 7);" ];
      smokePattern = "php 42";
      build = pkgs: mkPhp pkgs;
      # Windows (mingw-win32): cli+cgi+phpdbg multicall as one static php.exe,
      # 12 curated exts incl curl-over-Schannel + a statically-linked openssl
      # ext. No fpm (POSIX daemon). The whole win32 port lives in windows.nix.
      windowsBuild = pkgs: import ./windows.nix { inherit pkgs ulib; };
    };
}
