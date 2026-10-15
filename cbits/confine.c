/* Linux 5.6+: a tiny filesystem primitive, not an HTTP implementation.
 * No canonicalize-then-open check, no /proc reopens, no unsafe fallback. */
#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <linux/openat2.h>
#include <sys/stat.h>
#include <sys/syscall.h>
#include <unistd.h>

int lantern_open(const char *root, const char *path) {
    int dir = open(root, O_PATH | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW);
    if (dir < 0) return -1;
    struct open_how how = {
        .flags = O_RDONLY | O_CLOEXEC | O_NONBLOCK,
        .resolve = RESOLVE_BENEATH | RESOLVE_NO_SYMLINKS | RESOLVE_NO_MAGICLINKS
    };
    int fd = syscall(SYS_openat2, dir, path, &how, sizeof(how));
    int saved = errno;
    close(dir);
    if (fd < 0) { errno = saved; return -1; }
    struct stat st;
    if (fstat(fd, &st) < 0 || !S_ISREG(st.st_mode)) {
        close(fd);
        errno = EACCES;
        return -1;
    }
    return fd;
}
