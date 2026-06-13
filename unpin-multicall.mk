# unpin multicall link target — loaded alongside PHP's generated Makefile
# (`make -f Makefile -f unpin-multicall.mk unpin-multicall`) so it can reuse the
# real object lists, toolchain and link flags. For each CLI-adjacent sapi that
# was actually built, it renames that sapi's `main` (and the two apache_*_headers
# function impls that cli/cgi/fpm each define) to a unique symbol via objcopy,
# then links the shared core + every built sapi's objects + the dispatcher into
# one binary.
#
# Portability:
#  - $OBJCOPY/$NM/$CC/$LIBTOOL come from the nixpkgs build environment (correct on
#    every target — on darwin $OBJCOPY is llvm-objcopy; cctools ships no objcopy).
#  - Mach-O leads C symbols with '_', ELF does not. We detect the prefix once from
#    the cli main object (`nm` shows `_main` on Mach-O, `main` on ELF) and prepend
#    it to every redefine pair, so the same recipe works on Linux and darwin.
#  - fpm is a POSIX daemon: present on Linux + darwin, absent on Windows/cosmo. Its
#    objects are folded in only when sapi/fpm/fpm/fpm_main.o exists (guarded by
#    $(wildcard)); the dispatcher's fpm arm is compiled in to match (-DUNPIN_HAVE_FPM).
#    cgi is enabled on every target, so main/fastcgi.o (PHP_FASTCGI_OBJS, shared by
#    cgi and fpm) is always pulled in exactly once via the cgi fragment below.

FPM_MAIN_O := $(wildcard sapi/fpm/fpm/fpm_main.o)
HAVE_FPM   := $(if $(FPM_MAIN_O),1,)

unpin-multicall:
	@set -e ; \
	OC="$${OBJCOPY:-objcopy}" ; NMx="$${NM:-nm}" ; \
	cp sapi/cli/php_cli.o      unpin_cli_main.o ; \
	cp sapi/cgi/cgi_main.o     unpin_cgi_main.o ; \
	cp sapi/phpdbg/phpdbg.o    unpin_phpdbg_main.o ; \
	$(if $(HAVE_FPM),cp sapi/fpm/fpm/fpm_main.o unpin_fpm_main.o ;,) \
	if "$$NMx" --defined-only unpin_cli_main.o 2>/dev/null | awk '$$3=="_main"{f=1} END{exit !f}' ; then up=_ ; else up="" ; fi ; \
	{ printf '%smain %sunpin_cli_main\n' "$$up" "$$up" ; \
	  printf '%szif_apache_request_headers %scli_zif_apache_request_headers\n' "$$up" "$$up" ; \
	  printf '%szif_apache_response_headers %scli_zif_apache_response_headers\n' "$$up" "$$up" ; } > unpin_cli.redef ; \
	{ printf '%smain %sunpin_cgi_main\n' "$$up" "$$up" ; \
	  printf '%szif_apache_request_headers %scgi_zif_apache_request_headers\n' "$$up" "$$up" ; \
	  printf '%szif_apache_response_headers %scgi_zif_apache_response_headers\n' "$$up" "$$up" ; } > unpin_cgi.redef ; \
	printf '%smain %sunpin_phpdbg_main\n' "$$up" "$$up" > unpin_phpdbg.redef ; \
	"$$OC" --redefine-syms=unpin_cli.redef    unpin_cli_main.o ; \
	"$$OC" --redefine-syms=unpin_cgi.redef    unpin_cgi_main.o ; \
	"$$OC" --redefine-syms=unpin_phpdbg.redef unpin_phpdbg_main.o ; \
	$(if $(HAVE_FPM),{ printf '%smain %sunpin_fpm_main\n' "$$up" "$$up" ; printf '%szif_apache_request_headers %sfpm_zif_apache_request_headers\n' "$$up" "$$up" ; printf '%szif_apache_response_headers %sfpm_zif_apache_response_headers\n' "$$up" "$$up" ; } > unpin_fpm.redef ; "$$OC" --redefine-syms=unpin_fpm.redef unpin_fpm_main.o ;,) \
	$(CC) $(CFLAGS_CLEAN) $(EXTRA_CFLAGS) $(if $(HAVE_FPM),-DUNPIN_HAVE_FPM,) -c unpin_dispatch.c -o unpin_dispatch.o ; \
	$(LIBTOOL) --tag=CC --mode=link $(CC) -export-dynamic $(CFLAGS_CLEAN) $(EXTRA_CFLAGS) $(EXTRA_LDFLAGS_PROGRAM) $(LDFLAGS) $(PHP_RPATHS) \
	  $(filter-out sapi/cli/php_cli.o,$(PHP_GLOBAL_OBJS:.lo=.o) $(PHP_BINARY_OBJS:.lo=.o)) \
	  $(filter-out sapi/cli/php_cli.o,$(PHP_CLI_OBJS:.lo=.o)) \
	  $(filter-out sapi/cgi/cgi_main.o,$(PHP_FASTCGI_OBJS:.lo=.o) $(PHP_CGI_OBJS:.lo=.o)) \
	  $(if $(HAVE_FPM),$(filter-out sapi/fpm/fpm/fpm_main.o,$(PHP_FPM_OBJS:.lo=.o)),) \
	  $(filter-out sapi/phpdbg/phpdbg.o,$(PHP_PHPDBG_OBJS:.lo=.o)) \
	  unpin_cli_main.o unpin_cgi_main.o unpin_phpdbg_main.o $(if $(HAVE_FPM),unpin_fpm_main.o,) unpin_dispatch.o \
	  $(EXTRA_LIBS) $(FPM_EXTRA_LIBS) $(ZEND_EXTRA_LIBS) -o unpin-php-multi
