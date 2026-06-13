/* unpin multicall dispatcher for PHP on Windows (mingw-win32 build).
 *
 * Mirror of unpin_dispatch.c, but Windows-aware and fpm-free: PHP's fpm sapi
 * is a POSIX daemon (fork/signals/setuid) that does not exist on Windows, so
 * the Windows multicall folds in only cli + cgi + phpdbg. Each sapi's `main`
 * is renamed to unpin_<sapi>_main (objcopy --redefine-sym at link time); this
 * file owns the real main() and dispatches on either a leading
 * --unpin-program=NAME flag (bare-binary dispatch) or the argv[0] basename
 * (alias dispatch, e.g. php-cgi.exe), defaulting to the cli.
 *
 * vs the POSIX dispatcher: basename splits on BOTH '/' and '\\', strips a
 * trailing ".exe" (case-insensitively), and matching is case-insensitive —
 * all to suit Windows path/exe-name conventions. No <unistd.h>. */

#include <string.h>

extern int unpin_cli_main(int, char **);
extern int unpin_cgi_main(int, char **);
extern int unpin_phpdbg_main(int, char **);

static int ieq(const char *a, const char *b)
{
	while (*a && *b) {
		char x = *a, y = *b;
		if (x >= 'A' && x <= 'Z') x += 32;
		if (y >= 'A' && y <= 'Z') y += 32;
		if (x != y) return 0;
		a++; b++;
	}
	return *a == *b;
}

/* Copy argv[0]'s basename (after the last '/' or '\\') into out, then strip a
 * trailing ".exe" so an invoked `php-cgi.exe` matches the alias "php-cgi". */
static void base(const char *p, char *out, int n)
{
	const char *s = p, *q;
	int i, L;
	for (q = p; *q; q++)
		if (*q == '/' || *q == '\\')
			s = q + 1;
	for (i = 0; s[i] && i < n - 1; i++)
		out[i] = s[i];
	out[i] = 0;
	L = (int)strlen(out);
	if (L > 4 && ieq(out + L - 4, ".exe"))
		out[L - 4] = 0;
}

/* Returns the sapi's exit code, or -1 if `applet` names no known sapi. */
static int run(const char *a, int argc, char **argv)
{
	if (ieq(a, "php") || ieq(a, "php-cli")) return unpin_cli_main(argc, argv);
	if (ieq(a, "php-cgi"))                  return unpin_cgi_main(argc, argv);
	if (ieq(a, "phpdbg"))                   return unpin_phpdbg_main(argc, argv);
	return -1;
}

int main(int argc, char **argv)
{
	int r;
	char nm[64];

	/* 1. explicit --unpin-program=NAME first arg: consume it, dispatch on NAME,
	 * the sapi sees argv[0]=NAME and the args after it. */
	if (argc > 1 && !strncmp(argv[1], "--unpin-program=", 16)) {
		const char *name = argv[1] + 16;
		argv[1] = (char *)name;
		r = run(name, argc - 1, argv + 1);
		if (r != -1)
			return r;
		/* unknown program name: fall through to argv[0]/default. */
	}

	/* 2. dispatch on the invoked name (alias / .exe copy). */
	base(argv[0], nm, sizeof nm);
	r = run(nm, argc, argv);
	if (r != -1)
		return r;

	/* 3. default applet: the cli. */
	return unpin_cli_main(argc, argv);
}
