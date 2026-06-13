/* iconv_compat.c — darwin static-link shim.
 *
 * Provide the plain POSIX iconv symbols (iconv / iconv_open / iconv_close) as
 * thin forwarders to GNU libiconv's libiconv_* symbols.
 *
 * Why this is needed (darwin only):
 *   In nixpkgs' pkgsStatic darwin set, the C libraries PHP links (libxml2's
 *   encoding.o, gettext's libintl dcigettext.o, the bundled iconv extension)
 *   are compiled against a *plain* <iconv.h> and therefore reference the
 *   unprefixed symbols _iconv / _iconv_open / _iconv_close. The only *static*
 *   libiconv available on darwin is GNU libiconv ("libiconvReal"), which is
 *   built with iconv.h's `#define iconv libiconv` rename and so exports only
 *   _libiconv / _libiconv_open / _libiconv_close. The macOS SDK libiconv does
 *   export the plain names, but only as a .dylib — linking it would add a
 *   libiconv.2.dylib load command, which the unpins darwin allow-list rejects.
 *
 *   These three forwarders bridge the gap: everything resolves _iconv* against
 *   this shim, the shim calls _libiconv* in the static GNU archive, and the
 *   final binary carries no iconv dylib dependency. (glibc/musl keep iconv in
 *   libc, so this shim is darwin-only.)
 *
 * The forwarders are declared with the same prototypes GNU libiconv exports;
 * iconv_t is the usual opaque handle. We avoid including <iconv.h> so the
 * GNU `#define iconv libiconv` rename does not rewrite our own definitions. */
#include <stddef.h>

typedef void *iconv_t;

extern iconv_t libiconv_open(const char *to, const char *from);
extern size_t  libiconv(iconv_t cd, char **inbuf, size_t *inbytesleft,
                        char **outbuf, size_t *outbytesleft);
extern int     libiconv_close(iconv_t cd);

iconv_t iconv_open(const char *to, const char *from)
{
	return libiconv_open(to, from);
}

size_t iconv(iconv_t cd, char **inbuf, size_t *inbytesleft,
             char **outbuf, size_t *outbytesleft)
{
	return libiconv(cd, inbuf, inbytesleft, outbuf, outbytesleft);
}

int iconv_close(iconv_t cd)
{
	return libiconv_close(cd);
}
