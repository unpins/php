/* main/internal_functions.c for the mingw-win32 build.
 *
 * On a normal PHP build, configure (Unix) or configure.js (Windows/MSVC)
 * GENERATES this file from the enabled-extension set. The mingw-win32 build
 * bootstraps config.w32.h by hand and never runs configure.js, so we supply
 * the generated equivalent: the table of statically-linked module entries and
 * php_register_internal_extensions(), which the engine calls at startup.
 *
 * Curated Windows extension set (parity with the linux/darwin build minus the
 * POSIX-only exts — pcntl/posix/sockets-as-daemon etc. are dropped on Windows):
 * the 8 always-on (date/pcre/hash/json/random/reflection/spl/standard) plus the
 * 12 curated with-dep exts. Keep this list in sync with windows.nix's source
 * list and the AC_DEFINEs appended to config.w32.h. */

#include "php.h"
#include "php_main.h"
#include "zend_modules.h"
#include "ext/standard/php_standard.h"
#include "ext/date/php_date.h"
#include "ext/pcre/php_pcre.h"
#include "ext/hash/php_hash.h"
#include "ext/json/php_json.h"
#include "ext/random/php_random.h"
#include "ext/spl/php_spl.h"
#include "ext/reflection/php_reflection.h"

extern zend_module_entry openssl_module_entry;
extern zend_module_entry curl_module_entry;
extern zend_module_entry sqlite3_module_entry;
extern zend_module_entry pdo_module_entry;
extern zend_module_entry pdo_sqlite_module_entry;
extern zend_module_entry mbstring_module_entry;
extern zend_module_entry gmp_module_entry;
extern zend_module_entry sodium_module_entry;
extern zend_module_entry bz2_module_entry;
extern zend_module_entry zip_module_entry;
extern zend_module_entry php_gettext_module_entry; /* note the php_ prefix */
extern zend_module_entry iconv_module_entry;

static zend_module_entry *php_builtin_extensions[] = {
	phpext_date_ptr, phpext_pcre_ptr, phpext_hash_ptr, phpext_json_ptr,
	phpext_random_ptr, phpext_reflection_ptr, phpext_spl_ptr, phpext_standard_ptr,
	&openssl_module_entry, &curl_module_entry, &sqlite3_module_entry,
	&pdo_module_entry, &pdo_sqlite_module_entry, &mbstring_module_entry,
	&gmp_module_entry, &sodium_module_entry, &bz2_module_entry,
	&zip_module_entry, &php_gettext_module_entry, &iconv_module_entry
};

#define EXTCOUNT (sizeof(php_builtin_extensions) / sizeof(zend_module_entry *))

ZEND_API int php_register_internal_extensions(void)
{
	return php_register_extensions(php_builtin_extensions, EXTCOUNT);
}
