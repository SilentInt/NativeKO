/*
 * detach -- run a command in a fully detached session.
 *
 * A plain "setsid sh ... &" can still be torn down when the adb shell or the
 * SuperSU session exits (the process may remain in the caller's process
 * group or be reparented through a short-lived su daemon child).  This helper
 * does the classic double fork + setsid and reparents the command to init.
 *
 * Usage:
 *   detach [-l LOG] command [args...]
 *
 * -l LOG redirects stdin to /dev/null and stdout/stderr to LOG (append).
 * The parent exits immediately; the grandchild runs the command.
 */

#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

int main(int argc, char **argv)
{
    const char *log = NULL;
    int i = 1;
    if (argc > 2 && strcmp(argv[1], "-l") == 0) {
        log = argv[2];
        i = 3;
    }
    if (i >= argc) {
        fprintf(stderr, "usage: %s [-l LOG] command [args...]\n", argv[0]);
        return 2;
    }

    pid_t pid = fork();
    if (pid < 0) {
        perror("detach: fork");
        return 1;
    }
    if (pid > 0) {
        return 0; /* original parent returns to the caller */
    }

    if (setsid() < 0) {
        _exit(1);
    }

    pid = fork();
    if (pid < 0) {
        _exit(1);
    }
    if (pid > 0) {
        _exit(0); /* first child exits; grandchild is reparented to init */
    }

    chdir("/");

    int devnull = open("/dev/null", O_RDONLY);
    if (devnull >= 0) {
        dup2(devnull, 0);
        if (devnull > 2) close(devnull);
    }

    if (log) {
        int fd = open(log, O_WRONLY | O_CREAT | O_APPEND, 0644);
        if (fd >= 0) {
            dup2(fd, 1);
            dup2(fd, 2);
            if (fd > 2) close(fd);
        }
    }

    execvp(argv[i], &argv[i]);
    _exit(127);
}
