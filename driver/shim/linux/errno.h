/* On Linux hosts glibc's <errno.h> pulls <linux/errno.h>; defer to the real one if present. */
#if defined(__linux__)
#include_next <linux/errno.h>
#else
#include <errno.h>
#endif
