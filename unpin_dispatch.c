/* unpin multicall dispatcher for PHP.
 *
 * PHP's four CLI-adjacent sapis (cli, cgi, fpm, phpdbg) are each their own
 * executable with its own int main(); they all link the same libphp core. To
 * ship them as ONE relocatable binary we rename each sapi's `main` to
 * unpin_<sapi>_main (objcopy --redefine-sym at link time), link all four object
 * sets + the shared core into one ELF, and let this dispatcher own the real
 * main(). The applet is chosen, per the unpins multicall convention, by either
 * a leading --unpin-program=NAME flag (bare-binary dispatch) or the argv[0]
 * basename (alias dispatch); the default applet is the cli. */

#include <string.h>
#include <stdlib.h>
#include <unistd.h>

extern int unpin_cli_main(int, char **);
extern int unpin_cgi_main(int, char **);
extern int unpin_phpdbg_main(int, char **);
/* fpm is a POSIX daemon — present on Linux + darwin, absent on Windows/cosmo.
 * unpin-multicall.mk defines UNPIN_HAVE_FPM exactly when sapi/fpm was built, so
 * the fpm arm links only against a symbol that actually exists. */
#ifdef UNPIN_HAVE_FPM
extern int unpin_fpm_main(int, char **);
#endif

/* basename without modifying the input or pulling in libgen's POSIX basename
 * (which may scribble on its argument). */
static const char *base(const char *p)
{
	const char *s = strrchr(p, '/');
	return s ? s + 1 : p;
}

/* Returns the sapi's exit code, or -1 if `applet` names no known sapi. */
static int run(const char *applet, int argc, char **argv)
{
	if (!strcmp(applet, "php") || !strcmp(applet, "php-cli"))
		return unpin_cli_main(argc, argv);
	if (!strcmp(applet, "php-cgi"))
		return unpin_cgi_main(argc, argv);
#ifdef UNPIN_HAVE_FPM
	if (!strcmp(applet, "php-fpm"))
		return unpin_fpm_main(argc, argv);
#endif
	if (!strcmp(applet, "phpdbg"))
		return unpin_phpdbg_main(argc, argv);
	return -1;
}

int main(int argc, char **argv)
{
	int r;

	/* 1. explicit --unpin-program=NAME as the first argument: consume it and
	 * dispatch on NAME, leaving the sapi to see argv[0]=NAME, args after. */
	if (argc > 1 && !strncmp(argv[1], "--unpin-program=", 16)) {
		const char *name = argv[1] + 16;
		argv[1] = (char *)name; /* argv[1..] becomes the sapi's argv[0..] */
		r = run(name, argc - 1, argv + 1);
		if (r != -1)
			return r;
		/* unknown program name: fall through to argv[0]/default. */
	}

	/* 2. dispatch on the invoked name (symlink/alias). */
	r = run(base(argv[0]), argc, argv);
	if (r != -1)
		return r;

	/* 3. default applet: the cli. */
	return unpin_cli_main(argc, argv);
}
