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
    /* Search-only directories can serve readable indexes without granting
     * directory read permission. Detect them without opening directory data;
     * the O_PATH probe retains exactly the same path-confinement policy. */
    if (fd < 0 && saved == EACCES) {
        struct open_how probe = {
            .flags = O_PATH | O_CLOEXEC,
            .resolve = how.resolve
        };
        int pathfd = syscall(SYS_openat2, dir, path, &probe, sizeof(probe));
        if (pathfd >= 0) {
            struct stat entry;
            if (fstat(pathfd, &entry) == 0 && S_ISDIR(entry.st_mode))
                saved = EISDIR;
            close(pathfd);
        }
    }
    close(dir);
    if (fd < 0) { errno = saved; return -1; }
    struct stat st;
    if (fstat(fd, &st) < 0) {
        saved = errno;
        close(fd);
        errno = saved;
        return -1;
    }
    if (!S_ISREG(st.st_mode)) {
        int invalid = S_ISDIR(st.st_mode) ? EISDIR : EACCES;
        close(fd);
        errno = invalid;
        return -1;
    }
    return fd;
}
