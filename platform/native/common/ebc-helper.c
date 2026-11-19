/*
 * nativeko-ebc: bounded-time wrappers for the Rockchip EBC ioctls.
 *
 * GET_BUFFER (0x7000) blocks in the kernel (ebc_empty_buf_get) when the EBC
 * refresh thread has no free buffer, which normally means a previous frame
 * timed out.  Calling it directly from KOReader's single UI thread then
 * deadlocks input/UI.  These wrappers use SIGALRM to bound the wait so the
 * caller can log, mark the display wedged, and keep the UI responsive.
 */

#include <errno.h>
#include <signal.h>
#include <stdint.h>
#include <string.h>
#include <sys/ioctl.h>
#include <unistd.h>

#define EBC_GET_BUFFER      0x7000
#define EBC_SEND_BUFFER     0x7001
#define EBC_GET_STATUS      0x7007
#define EBC_DRAW_ENABLE     0x7008
#define EBC_DRAW_STOP       0x7006

struct ebc_buf_info {
    int32_t offset;
    int32_t epd_mode;
    int32_t height;
    int32_t width;
    int32_t vir_height;
    int32_t vir_width;
    int32_t fb_width;
    int32_t fb_height;
    int32_t color_panel;
    int32_t win_x1;
    int32_t win_y1;
    int32_t win_x2;
    int32_t win_y2;
    int32_t rotate;
};

static volatile sig_atomic_t alarm_fired;

static void on_alarm(int sig)
{
    (void)sig;
    alarm_fired = 1;
}

static int ioctl_timeout(int fd, unsigned long cmd, void *arg, int timeout_ms)
{
    struct sigaction sa, old;
    memset(&sa, 0, sizeof(sa));
    sa.sa_handler = on_alarm;
    sigemptyset(&sa.sa_mask);
    sa.sa_flags = 0;              /* no SA_RESTART: interrupt the ioctl */
    if (sigaction(SIGALRM, &sa, &old) < 0) {
        return -1;
    }

    unsigned int secs = (timeout_ms > 0)
        ? (unsigned int)((timeout_ms + 999) / 1000) : 1;
    alarm_fired = 0;
    alarm(secs);
    int rc = ioctl(fd, cmd, arg);
    int saved = errno;
    alarm(0);
    sigaction(SIGALRM, &old, NULL);

    if (alarm_fired) {
        errno = ETIMEDOUT;
        return -1;
    }
    errno = saved;
    return rc;
}

int nativeko_ebc_acquire(int fd, struct ebc_buf_info *info, int timeout_ms)
{
    return ioctl_timeout(fd, EBC_GET_BUFFER, info, timeout_ms);
}

int nativeko_ebc_send(int fd, struct ebc_buf_info *info)
{
    return (int)ioctl(fd, EBC_SEND_BUFFER, info);
}

int nativeko_ebc_status(int fd, int *status, int timeout_ms)
{
    return ioctl_timeout(fd, EBC_GET_STATUS, status, timeout_ms);
}

int nativeko_ebc_draw_enable(int fd)
{
    return (int)ioctl(fd, EBC_DRAW_ENABLE, 0);
}

int nativeko_ebc_draw_stop(int fd)
{
    return (int)ioctl(fd, EBC_DRAW_STOP, 0);
}
