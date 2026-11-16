/*
 * rk-ebc-probe -- inspect and calibrate Rockchip EBC e-ink display buffers.
 *
 * Built for Android/armv7 (bionic); run as root.
 *
 * Commands:
 *   info                          read-only: driver SN, buffer info, fb0 info,
 *                                 CPU/kernel/input/misc clues
 *   hist                          read-only: mmap /dev/ebc and print byte
 *                                 histograms at several offsets
 *   pattern BPP STRIDE KIND [N]   draw a calibration pattern into /dev/ebc
 *                                 and submit it (SEND_BUFFER + SEND_UPDATE)
 *   test                           print the recommended calibration sequence
 *
 * KIND: white, black, stripes, corner, quadrants
 *       corner uses N=0..3 for buffer TL/TR/BL/BR.
 *
 * Options:
 *   --force        run even if surfaceflinger is alive
 *   --no-update    SEND_BUFFER only, do not call SEND_UPDATE
 *   --offset N     buffer offset (default 0)
 *   --epd-mode N   SET_EBC_SEND_BUFFER epd_mode (default 1 = EPD_FULL)
 *
 * Safety:
 *   * Stop SurfaceFlinger first; otherwise the framework and this tool fight
 *     over the panel.
 *   * A blocked GET_BUFFER (printed as BLOCKED) means the EBC kernel thread is
 *     wedged.  Reboot and retry; do not run more EBC ioctls.
 *   * If the panel shows only a narrow strip, the BPP/STRIDE are wrong:
 *     try 8, 16, and 32 bpp.
 *   * A black square in buffer (0,0) appearing in the portrait top-right on
 *     the NoteSL means the panel scans the buffer rotated 90 degrees CW.
 */

#include <errno.h>
#include <fcntl.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/mman.h>
#include <dirent.h>
#include <unistd.h>
#include <linux/fb.h>

#define EBC_GET_BUFFER      0x7000
#define EBC_SEND_BUFFER     0x7001
#define EBC_GET_DRIVER_SN   0x7002
#define EBC_GET_BUFFER_INFO 0x7003
#define EBC_SEND_UPDATE     0x700c

#define EBC_DEVICE "/dev/ebc"
#define FB_DEVICE  "/dev/graphics/fb0"
#define MAP_LEN    (8 * 1024 * 1024)

struct ebc_buf_info {
    int offset;
    int epd_mode;
    int height;
    int width;
    int vir_height;
    int vir_width;
    int fb_width;
    int fb_height;
    int color_panel;
    int win_x1, win_y1, win_x2, win_y2;
    int rotate;
};

struct ebc_send_update {
    int32_t rect[4];      /* y, x, w, h on rk29 */
    int32_t waveform_mode;
    int32_t update_mode;
    int32_t update_marker;
    int32_t unknown_1c;
    int32_t flags;
    int32_t unknown_24;
};

static volatile sig_atomic_t timed_out;
static void on_alarm(int sig) { (void)sig; timed_out = 1; }

static int read_file(const char *path, char *buf, size_t len)
{
    int fd = open(path, O_RDONLY);
    if (fd < 0) return -1;
    ssize_t n = read(fd, buf, len - 1);
    close(fd);
    if (n < 0) return -1;
    buf[n] = 0;
    return 0;
}

static void print_file(const char *path)
{
    char buf[4096];
    if (read_file(path, buf, sizeof(buf)) == 0) {
        for (char *p = buf; *p; p++) if (*p == '\n') *p = ' ';
        printf("  %s = %s\n", path, buf);
    }
}

static int surfaceflinger_running(void)
{
    DIR *d = opendir("/proc");
    if (!d) return 0;
    struct dirent *de;
    int found = 0;
    while ((de = readdir(d)) != NULL) {
        if (de->d_name[0] < '0' || de->d_name[0] > '9') continue;
        char path[64], comm[64] = {0};
        snprintf(path, sizeof(path), "/proc/%s/comm", de->d_name);
        if (read_file(path, comm, sizeof(comm)) == 0 &&
            strstr(comm, "surfaceflinger")) {
            found = 1;
            break;
        }
    }
    closedir(d);
    return found;
}

static void dump_info(const char *tag, const struct ebc_buf_info *i)
{
    printf("%s: offset=%d epd_mode=%d %dx%d vir=%dx%d fb=%dx%d "
           "color=%d win=(%d,%d)-(%d,%d) rotate=%d\n",
           tag, i->offset, i->epd_mode, i->width, i->height,
           i->vir_width, i->vir_height, i->fb_width, i->fb_height,
           i->color_panel, i->win_x1, i->win_y1, i->win_x2, i->win_y2,
           i->rotate);
}

static void hist_region(const char *tag, const unsigned char *p, size_t len)
{
    unsigned long hist[256];
    memset(hist, 0, sizeof(hist));
    for (size_t i = 0; i < len; i++) hist[p[i]]++;
    int distinct = 0;
    unsigned long top = 0;
    int topval = 0;
    for (int i = 0; i < 256; i++) {
        if (hist[i]) distinct++;
        if (hist[i] > top) { top = hist[i]; topval = i; }
    }
    printf("%s: %zu bytes, distinct=%d, top=0x%02x %.1f%%\n",
           tag, len, distinct, topval, 100.0 * (double)top / (double)len);
}

static int do_info(void)
{
    char buf[4096];

    printf("== system ==\n");
    if (read_file("/proc/version", buf, sizeof(buf)) == 0) {
        buf[strcspn(buf, "\n")] = 0;
        printf("  /proc/version = %s\n", buf);
    }
    if (read_file("/proc/cpuinfo", buf, sizeof(buf)) == 0) {
        for (char *line = strtok(buf, "\n"); line; line = strtok(NULL, "\n")) {
            if (strstr(line, "model name") || strstr(line, "CPU part") ||
                strstr(line, "Features") || strstr(line, "Hardware"))
                printf("  cpu: %s\n", line);
        }
    }

    printf("== fb0 ==\n");
    print_file("/sys/class/graphics/fb0/virtual_size");
    print_file("/sys/class/graphics/fb0/stride");
    print_file("/sys/class/graphics/fb0/bits_per_pixel");
    print_file("/sys/class/graphics/fb0/rotate");
    print_file("/sys/class/graphics/fb0/screen_info");
    print_file("/sys/class/graphics/fb0/pan");
    print_file("/sys/class/graphics/fb0/state");
    print_file("/sys/class/graphics/fb0/phys_addr");
    print_file("/proc/misc");

    int ebc = open(EBC_DEVICE, O_RDWR);
    if (ebc < 0) {
        perror("open " EBC_DEVICE);
        return 1;
    }

    printf("== EBC driver ==\n");
    memset(buf, 0, sizeof(buf));
    if (ioctl(ebc, EBC_GET_DRIVER_SN, buf) == 0) {
        buf[sizeof(buf) - 1] = 0;
        printf("  driver SN: %s\n", buf);
    } else {
        printf("  driver SN: ioctl failed (%s)\n", strerror(errno));
    }

    struct ebc_buf_info info;
    memset(&info, 0, sizeof(info));
    if (ioctl(ebc, EBC_GET_BUFFER_INFO, &info) == 0)
        dump_info("buffer info", &info);
    else
        printf("  buffer info: ioctl failed (%s)\n", strerror(errno));

    struct sigaction sa;
    memset(&sa, 0, sizeof(sa));
    sa.sa_handler = on_alarm;
    sigaction(SIGALRM, &sa, NULL);
    memset(&info, 0, sizeof(info));
    timed_out = 0;
    alarm(3);
    errno = 0;
    int rc = ioctl(ebc, EBC_GET_BUFFER, &info);
    alarm(0);
    if (timed_out && rc < 0)
        printf("  GET_BUFFER BLOCKED (EBC thread wedged; reboot)\n");
    else if (rc == 0)
        dump_info("free buffer", &info);
    else
        printf("  GET_BUFFER failed rc=%d (%s)\n", rc, strerror(errno));

    printf("== input ==\n");
    if (read_file("/proc/bus/input/devices", buf, sizeof(buf)) == 0) {
        for (char *line = strtok(buf, "\n"); line; line = strtok(NULL, "\n")) {
            if (strncmp(line, "N:", 2) == 0 || strncmp(line, "H:", 2) == 0)
                printf("  %s\n", line);
        }
    }
    close(ebc);
    return 0;
}

static int do_hist(void)
{
    int fd = open(EBC_DEVICE, O_RDONLY);
    if (fd < 0) { perror("open " EBC_DEVICE); return 1; }
    unsigned char *p = mmap(NULL, MAP_LEN, PROT_READ, MAP_SHARED, fd, 0);
    if (p == MAP_FAILED) { perror("mmap"); return 1; }
    for (size_t off = 0; off < MAP_LEN; off += (1 << 20)) {
        char tag[32];
        snprintf(tag, sizeof(tag), "map+%zuM", off >> 20);
        hist_region(tag, p + off, 1 << 20);
    }
    return 0;
}

static void fill_pattern(unsigned char *d, int w, int h, int bpp,
                         const char *kind, int n)
{
    size_t row = (size_t)w * bpp / 8;
    for (int y = 0; y < h; y++) {
        unsigned char *p = d + (size_t)y * row;
        for (int x = 0; x < w; x++) {
            int black = 0;
            if (!strcmp(kind, "black")) black = 1;
            else if (!strcmp(kind, "stripes")) black = ((x / 100) & 1);
            else if (!strcmp(kind, "quadrants"))
                black = (x >= w / 2) ^ (y >= h / 2);
            else if (!strcmp(kind, "corner")) {
                int x0 = (n & 1) ? w - 200 : 0;
                int y0 = (n & 2) ? h - 200 : 0;
                black = (x >= x0 && x < x0 + 200 &&
                         y >= y0 && y < y0 + 200);
            }
            if (bpp == 4) {
                if ((x & 1) == 0) p[x / 2] = 0;
                p[x / 2] |= black ? 0x00 : 0x0F;
                if (black) p[x / 2] &= 0xF0;
            } else if (bpp == 8) {
                p[x] = black ? 0x00 : 0xFF;
            } else if (bpp == 16) {
                uint16_t v = black ? 0x0000 : 0xFFFF;
                memcpy(p + x * 2, &v, 2);
            } else if (bpp == 32) {
                uint32_t v = black ? 0xFF000000u : 0xFFFFFFFFu;
                memcpy(p + x * 4, &v, 4);
            }
        }
    }
}

static int do_pattern(int bpp, int stride, const char *kind, int n,
                      int offset, int epd_mode, int do_update, int force)
{
    if (!force && surfaceflinger_running()) {
        fprintf(stderr, "surfaceflinger is running; stop the framework "
                        "first or pass --force\n");
        return 2;
    }
    int fd = open(EBC_DEVICE, O_RDWR);
    if (fd < 0) { perror("open " EBC_DEVICE); return 1; }

    struct ebc_buf_info info;
    memset(&info, 0, sizeof(info));
    ioctl(fd, EBC_GET_BUFFER_INFO, &info);
    int w = info.width > 0 ? info.width : 1200;
    int h = info.height > 0 ? info.height : 825;
    if (stride <= 0) stride = w * bpp / 8;
    size_t size = (size_t)offset + (size_t)stride * h;
    if (size > MAP_LEN) {
        fprintf(stderr, "bpp=%d stride=%d does not fit %d-byte mapping\n",
                bpp, stride, MAP_LEN);
        return 1;
    }

    unsigned char *map = mmap(NULL, MAP_LEN, PROT_READ | PROT_WRITE,
                              MAP_SHARED, fd, 0);
    if (map == MAP_FAILED) { perror("mmap"); return 1; }
    memset(map, 0xFF, MAP_LEN);
    fill_pattern(map + offset, w, h, bpp, kind, n);

    memset(&info, 0, sizeof(info));
    info.offset = offset;
    info.epd_mode = epd_mode;
    info.width = w;
    info.height = h;
    info.vir_width = w;
    info.vir_height = h;
    info.fb_width = w;
    info.fb_height = h;
    info.win_x2 = w - 1;
    info.win_y2 = h - 1;
    int rc = ioctl(fd, EBC_SEND_BUFFER, &info);
    printf("pattern kind=%s bpp=%d stride=%d offset=%d SEND_BUFFER rc=%d\n",
           kind, bpp, stride, offset, rc);

    if (do_update) {
        struct ebc_send_update upd;
        memset(&upd, 0, sizeof(upd));
        upd.rect[0] = 0;      /* y on rk29 */
        upd.rect[1] = 0;      /* x */
        upd.rect[2] = w;
        upd.rect[3] = h;
        upd.waveform_mode = 2;
        upd.update_mode = 1;
        upd.update_marker = 1;
        upd.unknown_1c = 0x1000;
        upd.flags = 0x21000;
        rc = ioctl(fd, EBC_SEND_UPDATE, &upd);
        printf("SEND_UPDATE rc=%d\n", rc);
    }
    printf("Observe the panel:\n"
           "  * full-screen pattern + correct orientation -> bpp/stride OK\n"
           "  * narrow strip / only one side -> try other bpp (8, 16, 32)\n"
           "  * pattern rotated -> calibrate with 'corner' and set touch_rotation\n");
    sleep(2);
    return 0;
}

static int do_test(void)
{
    printf("Calibration sequence (run each, observe the panel):\n"
           "  1. stop the framework:\n"
           "       setprop ctl.stop zygote; setprop ctl.stop surfaceflinger\n"
           "  2. rk-ebc-probe pattern 32 4800 black\n"
           "  3. rk-ebc-probe pattern 32 4800 white\n"
           "  4. rk-ebc-probe pattern 32 4800 stripes\n"
           "  5. rk-ebc-probe pattern 32 4800 corner 0\n"
           "  6. if not full-screen, repeat 2-5 with 16 2400, 8 1200, 4 600\n"
           "  7. record width/height/rotate from 'info', bpp/stride from the\n"
           "     first combination that fills the panel, and the corner map\n"
           "     from step 5 (portrait top-left/right/bottom-left/right).\n"
           "  8. reboot after the tests; a blocked GET_BUFFER means the EBC\n"
           "     thread is wedged and must be reset by reboot.\n");
    return 0;
}

int main(int argc, char **argv)
{
    const char *cmd = argc > 1 ? argv[1] : "info";
    int force = 0, do_update = 1, offset = 0, epd_mode = 1;
    int argi = 2;
    for (int i = 2; i < argc; i++) {
        if (!strcmp(argv[i], "--force")) { force = 1; argi = i + 1; }
        else if (!strcmp(argv[i], "--no-update")) { do_update = 0; argi = i + 1; }
        else if (!strcmp(argv[i], "--offset") && i + 1 < argc) {
            offset = atoi(argv[++i]); argi = i + 1;
        } else if (!strcmp(argv[i], "--epd-mode") && i + 1 < argc) {
            epd_mode = atoi(argv[++i]); argi = i + 1;
        } else {
            argi = i;
            break;
        }
    }

    if (!strcmp(cmd, "info")) return do_info();
    if (!strcmp(cmd, "hist")) return do_hist();
    if (!strcmp(cmd, "test")) return do_test();
    if (!strcmp(cmd, "pattern")) {
        int bpp = argi < argc ? atoi(argv[argi++]) : 32;
        int stride = argi < argc ? atoi(argv[argi++]) : 0;
        const char *kind = argi < argc ? argv[argi++] : "stripes";
        int n = argi < argc ? atoi(argv[argi++]) : 0;
        return do_pattern(bpp, stride, kind, n, offset, epd_mode,
                          do_update, force);
    }
    fprintf(stderr, "usage: %s [info|hist|test|pattern] [-h]\n", argv[0]);
    return 2;
}
