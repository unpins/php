# mingw-win32 build of the PHP multicall (cli + cgi + phpdbg) as ONE static
# php.exe — consumed by mkStandaloneFlake's `windowsBuild` hook, which calls
# this with `pkgs` = the lib's windowsPkgs (x86_64-linux base + cosmo overlay;
# pkgsCross.mingwW64 lives here) and emits packages.x86_64-linux."windows-x86_64".
#
# Why a from-scratch build and not `(mingwStaticCross pkgs).php`: PHP's Windows
# source path (the `PHP_WIN32` code in win32/*.c) is gated to the MSVC build
# (configure.js → config.w32.h → nmake) and is NEVER reached by PHP's autotools
# configure, which compiles the POSIX paths (fork/dlopen/...) that mingw can't
# provide. nixpkgs has no Windows PHP. So we bootstrap config.w32.h by hand and
# compile the win32 path with mingw-gcc: de-MSVC-ify the `#ifdef ZEND_WIN32`
# blocks (gate on _MSC_VER so mingw takes the __GNUC__ path), zero the
# __declspec(dll*) API macros (single static binary, no DLL boundary), and
# supply the few generated files configure.js would have (internal_functions.c,
# config.w32.h defines). See memory project_unpins_php_spike for the full why.
#
# fpm is POSIX-only → the Windows multicall is cli + cgi + phpdbg.
{ pkgs, ulib }:
let
  lib = pkgs.lib;
  S = ulib.mingwStaticCross pkgs;
  stdenv = S.stdenv;
  binutils = pkgs.pkgsCross.mingwW64.buildPackages.binutils;

  # curl over Schannel (Windows system TLS + system cert store), no OpenSSL in
  # the curl link chain — verbatim the recipe shipped in curl/flake.nix's
  # windowsBuild. PHP's own openssl ext still links a static OpenSSL (below).
  curlSchannel = ulib.mingwStaticBinary {
    pkg = S.curl;
    staticDeps = { opensslSupport = false; scpSupport = false; http3Support = false; };
    filterConfigureFlag = ff: ff != "--without-ssl";
    extraConfigureFlags = [ "--with-schannel" ];
    extraCFlags = [ "-DNGHTTP2_STATICLIB" "-DCURL_STATICLIB" "-DPSL_STATIC" ];
  };

  # oniguruma + libzip carry a conservative meta.platforms that omits Windows
  # (both are plain C and build fine under the mingw cross). Relax the gate.
  allowWin = drv: drv.overrideAttrs (o: {
    meta = (o.meta or { }) // {
      platforms = (o.meta.platforms or [ ]) ++ [ "x86_64-windows" ];
    };
  });

  # Static deps: ext deps + curl's transitive chain (resolved as one
  # --start-group at link) + xz(liblzma) for libzip's xz codec.
  depOut = [
    S.openssl S.sqlite S.gmp S.libsodium S.bzip2 S.gettext S.libiconv
    (allowWin S.oniguruma) (allowWin S.libzip) curlSchannel
    S.pcre2 S.zlib S.nghttp2 S.libidn2 S.libpsl S.zstd S.brotli S.libunistring
  ];
  incDirs = builtins.concatStringsSep " " (map (p: "-I${lib.getDev p}/include") depOut);
  # .a archives live in the `out`/`lib` output — curl/openssl/sqlite default to
  # `bin`, so resolve via getLib, NOT the package's default output.
  libSearch = builtins.concatStringsSep " "
    (map (p: "${lib.getLib p}/lib") (depOut ++ [ S.xz ]));

  multicall = stdenv.mkDerivation {
    pname = "php-windows";
    inherit (pkgs.php84) version;
    src = pkgs.php84.unwrapped.src;

    nativeBuildInputs = [ binutils ];
    dontConfigure = true;
    # We compile with the bare cross gcc and explicit -I/-L (the proven probe
    # recipe), so the stdenv wrapper's auto-CFLAGS don't apply to our objects.
    # We deliberately do NOT set dontStrip: the mkStandaloneFlake pipeline
    # (strippedOrJoined → stripAllList=[bin out]) must run the mingw strip in
    # fixupPhase — BEFORE withAliases' postFixup appends the alias ZIP, so the
    # ZIP survives. (dontStrip=true would suppress the hook entirely and ship a
    # 29 MB binary with a full 70k-symbol table.)

    postPatch = ''
      sed 's|@PREFIX@|C:\\\\php|g' win32/build/config.w32.h.in > main/config.w32.h
      cat >> main/config.w32.h <<'EOF'
      #define PHP_HAVE_BUILTIN_UNREACHABLE 1
      #define PHP_HAVE_BUILTIN_EXPECT 1
      #define ZEND_DEBUG 0
      #define PHP_CONFIG_FILE_SCAN_DIR ""
      #define PHP_LINKER_MAJOR 0
      #define PHP_LINKER_MINOR 0
      #define PHP_USE_PHP_CRYPT_R 1
      #define HAVE_OPENSSL_EXT 1
      #define HAVE_CURL 1
      #define HAVE_SQLITE3 1
      #define HAVE_SQLITE3_ERRSTR 1
      #define HAVE_SQLITE3_EXPANDED_SQL 1
      #define HAVE_SQLITE3_COLUMN_TABLE_NAME 1
      #define HAVE_SQLITE3_CLOSE_V2 1
      #define HAVE_MBSTRING 1
      #define HAVE_MBREGEX 1
      #define HAVE_GMP 1
      #define HAVE_LIBSODIUMLIB 1
      #define HAVE_BZ2 1
      #define HAVE_ZIP 1
      #define HAVE_ICONV 1
      #define HAVE_LIBICONV 1
      #define ICONV_ALIASED_LIBICONV 1
      #define PHP_ICONV_IMPL "libiconv"
      #define HAVE_BIND_TEXTDOMAIN_CODESET 1
      #define HAVE_DNGETTEXT 1
      #define HAVE_NGETTEXT 1
      #define HAVE_LIBINTL 1
      #define HAVE_DCNGETTEXT 1
      EOF
      # config.w32.h.in additions above are indented by the Nix heredoc; strip
      # the leading whitespace so the #defines are valid preprocessor lines.
      sed -i 's/^      //' main/config.w32.h

      # de-MSVC-ify: gate MSVC-only constructs on _MSC_VER, let mingw take __GNUC__.
      sed -i 's/#if defined(ZEND_WIN32) \&\& !defined(__clang__)/#if defined(_MSC_VER)/' Zend/zend_portability.h
      sed -i 's@ || (defined(ZEND_WIN32) \&\& (!defined(_M_ARM64)))@@g' Zend/zend_portability.h
      sed -i 's@ || defined(ZEND_WIN32)$@@' Zend/zend_portability.h
      for h in win32/*.h win32/*.c; do sed -i 's/__forceinline static/static inline/g; s/\bstatic __forceinline/static inline/g; s/\b__forceinline\b/inline/g' "$h" 2>/dev/null || true; done
      sed -i 's/#if defined(ZEND_WIN32) || defined(HAVE_SYNC_ATOMICS)/#if defined(_MSC_VER) || defined(HAVE_SYNC_ATOMICS)/; s/^#ifdef ZEND_WIN32$/#ifdef _MSC_VER/' Zend/zend_atomic.h Zend/zend_atomic.c
      sed -i 's/^typedef int pid_t;/#ifdef _MSC_VER\ntypedef int pid_t;\n#endif/' main/php.h Zend/zend_alloc.c
      sed -i 's/Ui64/ULL/g; s/\bi64\b/LL/g' win32/time.c
      find . -name '*.h' -exec sed -i -E 's/(#[[:space:]]*define[[:space:]]+[A-Z_]*API[A-Z0-9_]*)[[:space:]]+__declspec\(dll(export|import)\)/\1/g' {} +
      sed -i '/^#define PHP_WIN32_WINUTIL_H/a #include <windows.h>' win32/winutil.h
      sed -i '0,/#include "php.h"/s||#include "php.h"\n#ifdef PHP_WIN32\n#include "win32/winutil.h"\n#endif|' main/main.c
      sed -i 's/struct dirent \*(\*readdirfunc)();/struct dirent *(*readdirfunc)(DIR *);/' win32/glob.c
      # mingw <windows.h> #defines _M_X64 (MSVC compat) → PHP's MSVC-only xmm-save
      # asm guard fires and renames execute_ex→execute_ex_real (needs MASM). Require
      # _MSC_VER so mingw keeps plain execute_ex (its CALL VM saves XMM normally).
      sed -i 's/#if defined(_WIN64) \&\& defined(_M_X64)$/#if defined(_WIN64) \&\& defined(_M_X64) \&\& defined(_MSC_VER)/' Zend/zend_vm_execute.h
      # header case (mingw-on-linux is case-sensitive; PHP uses CamelCase names).
      grep -rlE 'Ws2tcpip\.h|Winsock2\.h|Windows\.h|Mmsystem\.h|Wincrypt\.h|Mswsock\.h|Shlwapi\.h|Winuser\.h|Sddl\.h|WinBase\.h|Winbase\.h|Windns\.h' main Zend TSRM win32 ext sapi 2>/dev/null \
        | xargs -r sed -i 's/Ws2tcpip\.h/ws2tcpip.h/g; s/Winsock2\.h/winsock2.h/g; s/Windows\.h/windows.h/g; s/Mmsystem\.h/mmsystem.h/g; s/Wincrypt\.h/wincrypt.h/g; s/Mswsock\.h/mswsock.h/g; s/Shlwapi\.h/shlwapi.h/g; s/Winuser\.h/winuser.h/g; s/Sddl\.h/sddl.h/g; s/WinBase\.h/winbase.h/g; s/Winbase\.h/winbase.h/g; s/Windns\.h/windns.h/g'
      sed -i 's@\.h >@.h>@g' ext/standard/dns_win32.c
      # phpdbg wraps main() in MSVC SEH (__try/__except) for a crash backtrace —
      # mingw-gcc has no __try. The two are the only bare `#ifdef _WIN32` in the
      # file; gate them on _MSC_VER so both brace-halves vanish together for mingw.
      sed -i 's/^#ifdef _WIN32$/#ifdef _MSC_VER/' sapi/phpdbg/phpdbg.c
      # mbstring's bundled libmbfl needs its win32 config header.
      cp ext/mbstring/libmbfl/config.h.w32 ext/mbstring/libmbfl/config.h
      # generated files configure.js would normally emit.
      cp ${./internal_functions_win.c} main/internal_functions.c
      cp ${./unpin_dispatch_win.c} unpin_dispatch_win.c
      printf '#include <basetsd.h>\n#include "config.w32.h"\n' > main/php_config.h
      cat > win32/wsyslog.h <<'EOF'
      #ifndef PHP_WSYSLOG_H
      #define PHP_WSYSLOG_H
      #include "syslog.h"
      #define PHP_SYSLOG_ERROR_TYPE   EVENTLOG_ERROR_TYPE
      #define PHP_SYSLOG_WARNING_TYPE EVENTLOG_WARNING_TYPE
      #define PHP_SYSLOG_INFO_TYPE    EVENTLOG_INFORMATION_TYPE
      #endif
      EOF
      sed -i 's/^      //' win32/wsyslog.h
      # PHP CLI does `#include <openssl/applink.c>` (MSVC CRT FILE* bridge);
      # nixpkgs openssl doesn't ship it and mingw/msvcrt needs no CRT bridge.
      # Empty stub, resolved AFTER the real openssl include (-I order below).
      mkdir -p openssl-applink-stub/openssl && : > openssl-applink-stub/openssl/applink.c
    '';

    buildPhase = ''
      runHook preBuild
      CC=$(echo ${stdenv.cc}/bin/*-gcc)
      NM=${binutils}/bin/x86_64-w64-mingw32-nm
      OBJCOPY=${binutils}/bin/x86_64-w64-mingw32-objcopy
      EXTINC="-Iext/mbstring -Iext/mbstring/libmbfl -Iext/mbstring/libmbfl/mbfl ${incDirs}"
      INC="-I. -Imain -IZend -ITSRM -Imain/streams -Iext/date/lib -Iext/hash/sha3/generic64lc -I${lib.getDev S.pcre2}/include $EXTINC -Iopenssl-applink-stub -Isapi/cgi -Isapi/phpdbg"
      DEF="-include time.h -DPHP_WIN32=1 -DZEND_WIN32=1 -DPHP_EXPORTS=1 -DLIBZEND_EXPORTS=1 -DCWD_EXPORTS=1 -DTSRM_EXPORTS=1 -DSAPI_EXPORTS=1 -D_WIN32_WINNT=0x0602 -DWIN32 -D_USE_MATH_DEFINES -DZEND_ENABLE_STATIC_TSRMLS_CACHE=1 -DPCRE2_CODE_UNIT_WIDTH=8 -DPCRE2_STATIC=1 -DKeccakP200_excluded -DKeccakP400_excluded -DKeccakP800_excluded -Wno-error=format-security -Wno-format-security -Wno-error=incompatible-pointer-types"
      EXTDEF="-DCURL_STATICLIB -DPHP_CURL_EXPORTS=1 -DSODIUM_STATIC=1 -DZIP_STATIC=1 -DLZMA_API_STATIC -DHAVE_SET_MTIME -DHAVE_ENCRYPTION -DHAVE_LIBZIP_VERSION -DHAVE_PROGRESS_CALLBACK -DHAVE_CANCEL_CALLBACK -DHAVE_METHOD_SUPPORTED -DHAVE_STRICMP -DMBFL_DLL_EXPORT=1 -DONIG_EXTERN=extern -DPHP_ONIG_BAD_KOI8_ENTRY=1 -DONIG_STATIC=1 -DPHP_ICONV_EXPORTS -DPHP_ICONV_IMPL=\"libiconv\" -DLIBXML_STATIC"
      mkdir -p obj; fail=0
      EXCL="sapi/cli/cli_win32.c Zend/Optimizer/ssa_integrity.c win32/cp_enc_map.c win32/cp_enc_map_gen.c win32/dllmain.c main/php_odbc_utils.c main/debug_gdb_scripts.c Zend/zend_gdb.c ext/standard/crc32_x86.c"
      CORE_SRCS="win32/*.c main/*.c main/streams/*.c Zend/*.c Zend/Optimizer/*.c TSRM/*.c \
            ext/date/*.c ext/date/lib/*.c ext/pcre/*.c ext/hash/*.c \
            ext/hash/sha3/generic64lc/KeccakHash.c ext/hash/sha3/generic64lc/KeccakSponge.c ext/hash/sha3/generic64lc/KeccakP-1600-opt64.c \
            ext/hash/murmur/*.c ext/hash/xxhash/*.c \
            ext/json/*.c ext/random/*.c ext/spl/*.c ext/reflection/*.c ext/standard/*.c ext/standard/libavifinfo/*.c \
            ext/openssl/openssl.c ext/openssl/openssl_pwhash.c ext/openssl/xp_ssl.c \
            ext/curl/interface.c ext/curl/multi.c ext/curl/share.c ext/curl/curl_file.c \
            ext/sqlite3/sqlite3.c \
            ext/pdo/pdo.c ext/pdo/pdo_dbh.c ext/pdo/pdo_stmt.c ext/pdo/pdo_sql_parser.c ext/pdo/pdo_sqlstate.c \
            ext/pdo_sqlite/pdo_sqlite.c ext/pdo_sqlite/sqlite_driver.c ext/pdo_sqlite/sqlite_statement.c ext/pdo_sqlite/sqlite_sql_parser.c \
            ext/mbstring/mbstring.c ext/mbstring/php_unicode.c ext/mbstring/mb_gpc.c ext/mbstring/php_mbregex.c \
            ext/mbstring/libmbfl/filters/*.c ext/mbstring/libmbfl/mbfl/*.c ext/mbstring/libmbfl/nls/*.c \
            ext/gmp/gmp.c ext/sodium/libsodium.c ext/sodium/sodium_pwhash.c \
            ext/bz2/bz2.c ext/bz2/bz2_filter.c ext/zip/php_zip.c ext/zip/zip_stream.c \
            ext/gettext/gettext.c ext/iconv/iconv.c"
      CLI_SRCS="sapi/cli/php_cli.c sapi/cli/php_cli_server.c sapi/cli/ps_title.c sapi/cli/php_http_parser.c sapi/cli/php_cli_process_title.c"
      CGI_SRCS="sapi/cgi/cgi_main.c"
      PHPDBG_SRCS="sapi/phpdbg/phpdbg.c sapi/phpdbg/phpdbg_prompt.c sapi/phpdbg/phpdbg_cmd.c sapi/phpdbg/phpdbg_info.c sapi/phpdbg/phpdbg_help.c sapi/phpdbg/phpdbg_break.c sapi/phpdbg/phpdbg_print.c sapi/phpdbg/phpdbg_bp.c sapi/phpdbg/phpdbg_list.c sapi/phpdbg/phpdbg_utils.c sapi/phpdbg/phpdbg_set.c sapi/phpdbg/phpdbg_frame.c sapi/phpdbg/phpdbg_watch.c sapi/phpdbg/phpdbg_win.c sapi/phpdbg/phpdbg_btree.c sapi/phpdbg/phpdbg_parser.c sapi/phpdbg/phpdbg_lexer.c sapi/phpdbg/phpdbg_sigsafe.c sapi/phpdbg/phpdbg_io.c sapi/phpdbg/phpdbg_out.c"
      compile_one() {
        srcfile="$1"; extra="$2"
        [ -f "$srcfile" ] || return 0
        case " $EXCL " in *" $srcfile "*) return 0;; esac
        case "$srcfile" in *hash_sha_ni.c) extra="$extra -msha -mssse3 -msse4.2";; esac
        o="obj/$(echo $srcfile|tr / _).o"
        if ! $CC $DEF $EXTDEF $INC $extra -c "$srcfile" -o "$o" 2>"$o.err"; then
          fail=$((fail+1)); echo "FAIL $srcfile"; grep -iE "error:|fatal error:" "$o.err" | head -2
        fi
      }
      for s in $CORE_SRCS $CLI_SRCS $CGI_SRCS; do compile_one "$s" ""; done
      for s in $PHPDBG_SRCS; do compile_one "$s" "-DYY_NO_UNISTD_H"; done
      for s in Zend/asm/jump_x86_64_ms_pe_gas.S Zend/asm/make_x86_64_ms_pe_gas.S; do
        $CC -c "$s" -o "obj/$(echo $s|tr / _).o"
      done
      if [ "$fail" -ne 0 ]; then echo "ABORT: $fail source(s) failed to compile" >&2; exit 1; fi

      # ---- MULTICALL: rename each sapi main, then genuine cross-sapi dups ----
      $OBJCOPY --redefine-sym main=unpin_cli_main    obj/sapi_cli_php_cli.c.o
      $OBJCOPY --redefine-sym main=unpin_cgi_main    obj/sapi_cgi_cgi_main.c.o
      $OBJCOPY --redefine-sym main=unpin_phpdbg_main obj/sapi_phpdbg_phpdbg.c.o
      defsof(){ for o in $1; do $NM -g --defined-only "$o" 2>/dev/null; done | awk '$2 ~ /^[TtDdBbRr]$/ {print $3}' | sort -u; }
      defsof "$(ls obj/sapi_cli_*.o)"    > defs_cli
      defsof "$(ls obj/sapi_cgi_*.o)"    > defs_cgi
      defsof "$(ls obj/sapi_phpdbg_*.o)" > defs_phpdbg
      # Exclude COFF compiler-generated `.refptr.<global>` indirection thunks
      # (one auto-emitted per object referencing a shared global — renaming them
      # breaks the linker's own indirection). Real overlap = zif_apache_*headers.
      cat defs_cli defs_cgi defs_phpdbg | sort | uniq -d | grep -vE '^\.' > dups || true
      for grp in cli cgi phpdbg; do
        : > redef_$grp
        while read s; do [ -n "$s" ] && echo "$s ''${grp}_$s" >> redef_$grp; done < dups
        if [ -s redef_$grp ]; then
          for o in $(ls obj/sapi_''${grp}_*.o); do $OBJCOPY --redefine-syms=redef_$grp "$o"; done
        fi
      done
      $CC $DEF $INC -c unpin_dispatch_win.c -o obj/unpin_dispatch_win.o

      # ---- link the single multicall php.exe ----
      WINLIBS="-lws2_32 -lwinmm -lshlwapi -lpsapi -ladvapi32 -luser32 -lkernel32 -lole32 -loleaut32 -lbcrypt -lcrypt32 -lwldap32 -lnetapi32 -liphlpapi -ldnsapi -lsecur32 -lnormaliz -lgdi32"
      ALLA=$(find ${libSearch} -name '*.a' 2>/dev/null | tr '\n' ' ')
      $CC obj/*.o -Wl,--start-group $ALLA -Wl,--end-group $WINLIBS -o php.exe
      runHook postBuild
    '';

    # Install as bin/php (+ alias symlinks) so withAliases can harvest the alias
    # names; windowsBuild renames bin/php → bin/php.exe afterwards (lua pattern).
    installPhase = ''
      runHook preInstall
      mkdir -p "$out/bin"
      install -m755 php.exe "$out/bin/php"
      ln -s php "$out/bin/php-cgi"
      ln -s php "$out/bin/phpdbg"
      runHook postInstall
    '';

    meta = {
      description = "PHP 8.4 CLI/CGI/phpdbg multicall — single static Windows binary";
      platforms = [ "x86_64-windows" ];
    };
  };

  # Embed the alias list (php-cgi, phpdbg) for the `unpin` tool, then give the
  # binary its .exe extension. Mirrors lua/multicall.nix's windows finalization.
  aliased = ulib.withAliases pkgs {
    primary = "php";
    aliasesFromSymlinksIn = "bin";
  } multicall;
in
aliased.overrideAttrs (o: {
  postFixup = (o.postFixup or "") + ''
    [ -f "$out/bin/php" ] && mv "$out/bin/php" "$out/bin/php.exe"
  '';
})
