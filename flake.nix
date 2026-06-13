{
  description = "PHP 8.4 CLI as a single self-contained static binary (spike)";

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
            "--with-gmp=${s.gmp.dev}"
            "--with-gettext=${s.gettext}"
            "--with-sodium"
            "--with-bz2=${s.bzip2.dev}"
            "--with-sqlite3=${s.sqlite.dev}"
            "--with-pdo-sqlite=${s.sqlite.dev}"
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

          extInputs = [
            curlNoPsl
            s.openssl
            s.zlib
            s.libxml2
            s.sqlite
            s.oniguruma
            readlineFB
            s.gmp
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
            stdenv = s.stdenv;
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
          configureFlags = (old.configureFlags or [ ]) ++ extConfigure;
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
            export LDFLAGS="-framework CoreFoundation -framework CoreServices -framework SystemConfiguration -L${iconvCompat}/lib -liconvcompat -L${lib.getLib s.libiconvReal}/lib -liconv ''${LDFLAGS:-}"
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
        });
    in
    ulib.mkStandaloneFlake {
      inherit self;
      name = "php";
      embedMan = false;
      smoke = [ "-r" "echo 'php ' . (6 * 7);" ];
      smokePattern = "php 42";
      build = pkgs: mkPhp pkgs;
      # Windows (mingw-win32): cli+cgi+phpdbg multicall as one static php.exe,
      # 12 curated exts incl curl-over-Schannel + a statically-linked openssl
      # ext. No fpm (POSIX daemon). The whole win32 port lives in windows.nix.
      windowsBuild = pkgs: import ./windows.nix { inherit pkgs ulib; };
    };
}
