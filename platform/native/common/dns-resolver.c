/*
 * nativeko-dns: a tiny getaddrinfo() shim for native KOReader sessions.
 *
 * Android's bionic resolver normally talks to netd's dnsproxyd.  With the
 * framework stopped there is no resolver configuration, so hostname lookups
 * fail even though the interface has an IP and default route.  This shim is
 * loaded with LD_PRELOAD and resolves A/AAAA records directly over UDP DNS,
 * using KO_NATIVE_DNS (or net.dns1, or a public fallback).  It is plain POSIX
 * socket code, not an Android API.
 */

#define _GNU_SOURCE
#include <arpa/inet.h>
#include <errno.h>
#include <netdb.h>
#include <netinet/in.h>
#include <dlfcn.h>
#include <stddef.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/select.h>
#include <sys/socket.h>
#include <sys/time.h>
#include <unistd.h>

#ifndef EAI_NODATA
#define EAI_NODATA EAI_NONAME
#endif

#define MAX_ADDRS 8
#define DNS_TIMEOUT_SEC 2
#define DNS_MAX_SERVERS 4
#define DNS_DEBUG (getenv("KO_NATIVE_DNS_DEBUG") != NULL)

struct dns_addr {
    int family;
    unsigned char addr[16];
};

#if defined(__ANDROID__)
extern int __system_property_get(const char *name, char *value);
#endif

#define OUR_AI_MAGIC 0x4e4b444eu  /* NK DN */

struct our_ai {
    uint32_t magic;
    struct addrinfo ai;
};

/*
 * The shim is 32-bit (matching the KOReader ABI), but this is a 64-bit ROM:
 * child processes such as /system/bin/sh must NOT inherit LD_PRELOAD, or the
 * linker rejects the 32-bit library.  The dynamic linker has already loaded
 * us by the time this constructor runs, so the main process keeps the
 * interposed getaddrinfo while children see a clean environment.
 */
__attribute__((constructor))
static void nativeko_dns_drop_preload(void)
{
    unsetenv("LD_PRELOAD");
}

static unsigned short next_id(void)
{
    static unsigned short id = 0x4e4b;
    return ++id;
}

static int parse_servers(char servers[DNS_MAX_SERVERS][64])
{
    char buf[256] = "";
    const char *src = getenv("KO_NATIVE_DNS");
    if (!src || !*src) {
#if defined(__ANDROID__)
        if (__system_property_get("net.dns1", buf) <= 0) {
            buf[0] = 0;
        }
#endif
        src = buf;
    }
    if (!src || !*src) src = "223.5.5.5";

    int n = 0;
    const char *p = src;
    while (*p && n < DNS_MAX_SERVERS) {
        while (*p == ' ' || *p == ',' || *p == ';') p++;
        if (!*p) break;
        const char *start = p;
        while (*p && *p != ' ' && *p != ',' && *p != ';') p++;
        size_t len = (size_t)(p - start);
        if (len > 0 && len < 64) {
            memcpy(servers[n], start, len);
            servers[n][len] = 0;
            n++;
        }
    }
    if (n == 0) {
        strcpy(servers[0], "223.5.5.5");
        n = 1;
    }
    return n;
}

static int skip_name(const unsigned char *buf, int len, int off)
{
    while (off < len) {
        unsigned char c = buf[off];
        if (c == 0) return off + 1;
        if ((c & 0xc0) == 0xc0) return off + 2;
        if ((c & 0xc0) != 0 || off + c + 1 > len) return -1;
        off += c + 1;
    }
    return -1;
}

static int build_query(unsigned char *q, int qsize, const char *name, int qtype)
{
    if (qsize < 64) return -1;
    int n = 0;
    unsigned short id = next_id();
    q[n++] = (unsigned char)(id >> 8);
    q[n++] = (unsigned char)(id & 0xff);
    q[n++] = 0x01; q[n++] = 0x00;      /* RD */
    q[n++] = 0x00; q[n++] = 0x01;      /* qdcount */
    q[n++] = 0; q[n++] = 0;
    q[n++] = 0; q[n++] = 0;
    q[n++] = 0; q[n++] = 1;            /* one OPT record (EDNS) */
    const char *p = name;
    while (*p) {
        const char *dot = strchr(p, '.');
        size_t len = dot ? (size_t)(dot - p) : strlen(p);
        if (len == 0) { p = dot ? dot + 1 : p + strlen(p); continue; }
        if (len > 63 || n + (int)len + 1 >= qsize) return -1;
        q[n++] = (unsigned char)len;
        memcpy(q + n, p, len);
        n += (int)len;
        if (!dot) break;
        p = dot + 1;
    }
    q[n++] = 0;
    q[n++] = (unsigned char)(qtype >> 8);
    q[n++] = (unsigned char)(qtype & 0xff);
    q[n++] = 0;
    q[n++] = 1;                        /* IN */
    /* EDNS0 OPT: root, type 41, class 4096, ttl 0, rdlen 0 */
    q[n++] = 0;
    q[n++] = 0; q[n++] = 41;
    q[n++] = 0x10; q[n++] = 0x00;
    q[n++] = 0; q[n++] = 0; q[n++] = 0; q[n++] = 0;
    q[n++] = 0; q[n++] = 0;
    return n;
}

static int udp_query(const char *server, const unsigned char *q, int qlen,
                     unsigned char *ans, int anslen)
{
    struct sockaddr_in sa;
    memset(&sa, 0, sizeof(sa));
    sa.sin_family = AF_INET;
    sa.sin_port = htons(53);
    if (inet_pton(AF_INET, server, &sa.sin_addr) != 1) return -1;

    int fd = socket(AF_INET, SOCK_DGRAM, 0);
    if (fd < 0) return -1;
    struct timeval tv = { DNS_TIMEOUT_SEC, 0 };
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv));

    int rc = -1;
    for (int attempt = 0; attempt < 2 && rc < 0; attempt++) {
        if (sendto(fd, q, qlen, 0, (struct sockaddr *)&sa, sizeof(sa)) < 0) {
            continue;
        }
        int n = (int)recv(fd, ans, anslen, 0);
        if (n >= 12) rc = n;
    }
    close(fd);
    return rc;
}

/* Returns number of addresses collected (0..max), or -1 on query failure. */
static int resolve_type(const char *name, int qtype, struct dns_addr *out,
                        int max)
{
    char servers[DNS_MAX_SERVERS][64];
    int ns = parse_servers(servers);
    unsigned char q[512];
    int qlen = build_query(q, sizeof(q), name, qtype);
    if (qlen < 0) return -1;

    for (int s = 0; s < ns; s++) {
        unsigned char ans[2048];
        int n = udp_query(servers[s], q, qlen, ans, sizeof(ans));
        if (n < 12) continue;
        if (ans[0] != q[0] || ans[1] != q[1]) continue;
        if (DNS_DEBUG) {
            fprintf(stderr, "[nativeko-dns] %s via %s: %d bytes rcode=%d\n",
                    name, servers[s], n, ans[3] & 0x0f);
        }
        if ((ans[3] & 0x0f) != 0) continue;
        int qd = (ans[4] << 8) | ans[5];
        int an = (ans[6] << 8) | ans[7];
        int off = 12;
        int ok = 1;
        for (int i = 0; i < qd; i++) {
            off = skip_name(ans, n, off);
            if (off < 0 || off + 4 > n) { ok = 0; break; }
            off += 4;
        }
        if (!ok) continue;
        int count = 0;
        for (int i = 0; i < an && off >= 0 && off < n; i++) {
            off = skip_name(ans, n, off);
            if (off < 0 || off + 10 > n) break;
            int type = (ans[off] << 8) | ans[off + 1];
            int klass = (ans[off + 2] << 8) | ans[off + 3];
            int rdlen = (ans[off + 8] << 8) | ans[off + 9];
            off += 10;
            if (off + rdlen > n) break;
            if (klass == 1 && qtype == 1 && type == 1 && rdlen == 4 &&
                count < max) {
                out[count].family = AF_INET;
                memcpy(out[count].addr, ans + off, 4);
                count++;
            } else if (klass == 1 && qtype == 28 && type == 28 &&
                       rdlen == 16 && count < max) {
                out[count].family = AF_INET6;
                memcpy(out[count].addr, ans + off, 16);
                count++;
            }
            off += rdlen;
        }
        if (count > 0) return count;
    }
    return 0;
}

static int service_port(const char *service, int socktype)
{
    if (!service || !*service) return 0;
    char *end = NULL;
    long p = strtol(service, &end, 10);
    if (end && *end == 0 && p >= 0 && p <= 65535) {
        return (int)htons((unsigned short)p);
    }
    struct servent *se = getservbyname(service,
        socktype == SOCK_DGRAM ? "udp" : "tcp");
    return se ? se->s_port : 0;
}

static struct addrinfo *make_result(const char *node, const char *service,
                                    const struct addrinfo *hints,
                                    const struct dns_addr *addrs, int count)
{
    struct addrinfo *head = NULL, **tail = &head;
    int ai_flags = hints ? hints->ai_flags : 0;
    int socktype = hints ? hints->ai_socktype : 0;
    int protocol = hints ? hints->ai_protocol : 0;

    for (int i = 0; i < count; i++) {
        int types[2];
        int nt = 0;
        if (socktype) {
            types[nt++] = socktype;
        } else {
            types[nt++] = SOCK_STREAM;
            types[nt++] = SOCK_DGRAM;
        }
        for (int t = 0; t < nt; t++) {
            struct our_ai *w = calloc(1, sizeof(*w));
            if (!w) {
                freeaddrinfo(head);
                return NULL;
            }
            w->magic = OUR_AI_MAGIC;
            struct addrinfo *ai = &w->ai;
            ai->ai_family = addrs[i].family;
            ai->ai_socktype = types[t];
            ai->ai_protocol = protocol ? protocol :
                (types[t] == SOCK_STREAM ? IPPROTO_TCP : IPPROTO_UDP);
            ai->ai_flags = ai_flags;
            if (addrs[i].family == AF_INET) {
                struct sockaddr_in *sin = calloc(1, sizeof(*sin));
                if (!sin) { free(w); freeaddrinfo(head); return NULL; }
                sin->sin_family = AF_INET;
                sin->sin_port = (unsigned short)service_port(service, types[t]);
                memcpy(&sin->sin_addr, addrs[i].addr, 4);
                ai->ai_addr = (struct sockaddr *)sin;
                ai->ai_addrlen = sizeof(*sin);
            } else {
                struct sockaddr_in6 *sin6 = calloc(1, sizeof(*sin6));
                if (!sin6) { free(w); freeaddrinfo(head); return NULL; }
                sin6->sin6_family = AF_INET6;
                sin6->sin6_port = (unsigned short)service_port(service, types[t]);
                memcpy(&sin6->sin6_addr, addrs[i].addr, 16);
                ai->ai_addr = (struct sockaddr *)sin6;
                ai->ai_addrlen = sizeof(*sin6);
            }
            if (!head && (ai_flags & AI_CANONNAME) && node) {
                ai->ai_canonname = strdup(node);
            }
            *tail = ai;
            tail = &ai->ai_next;
        }
    }
    return head;
}

static int numeric_result(const char *node, const char *service,
                          const struct addrinfo *hints, struct addrinfo **res)
{
    struct dns_addr addr;
    memset(&addr, 0, sizeof(addr));
    if (inet_pton(AF_INET, node, addr.addr) == 1) {
        addr.family = AF_INET;
    } else if (inet_pton(AF_INET6, node, addr.addr) == 1) {
        addr.family = AF_INET6;
    } else {
        return -1;
    }
    *res = make_result(node, service, hints, &addr, 1);
    return *res ? 0 : EAI_MEMORY;
}

int getaddrinfo(const char *node, const char *service,
                const struct addrinfo *hints, struct addrinfo **res)
{
    if (!res) return EAI_FAIL;
    *res = NULL;
    int family = hints ? hints->ai_family : AF_UNSPEC;

    if (node && *node) {
        int nr = numeric_result(node, service, hints, res);
        if (nr != -1) return nr;
        if (hints && (hints->ai_flags & AI_NUMERICHOST)) return EAI_NONAME;

        struct dns_addr addrs[MAX_ADDRS];
        int count = 0;
        if (family == AF_UNSPEC || family == AF_INET) {
            int n = resolve_type(node, 1, addrs, MAX_ADDRS);
            if (n > 0) count = n;
        }
        if (count == 0 && (family == AF_UNSPEC || family == AF_INET6)) {
            int n = resolve_type(node, 28, addrs, MAX_ADDRS);
            if (n > 0) count = n;
        }
        if (count == 0) return EAI_NONAME;
        *res = make_result(node, service, hints, addrs, count);
        return *res ? 0 : EAI_MEMORY;
    }

    /* NULL node: loopback, or INADDR_ANY for a passive socket. */
    struct dns_addr addr;
    memset(&addr, 0, sizeof(addr));
    int passive = hints && (hints->ai_flags & AI_PASSIVE);
    if (family == AF_INET6) {
        addr.family = AF_INET6;
        if (passive) {
            /* in6addr_any */
        } else {
            addr.addr[15] = 1; /* ::1 */
        }
    } else {
        addr.family = AF_INET;
        if (!passive) addr.addr[0] = 127;
        addr.addr[3] = passive ? 0 : 1;
    }
    *res = make_result(NULL, service, hints, &addr, 1);
    return *res ? 0 : EAI_MEMORY;
}

void freeaddrinfo(struct addrinfo *res)
{
    static void (*real_freeaddrinfo)(struct addrinfo *);
    while (res) {
        struct our_ai *w = (struct our_ai *)
            ((char *)res - offsetof(struct our_ai, ai));
        if (w->magic != OUR_AI_MAGIC) {
            if (!real_freeaddrinfo) {
                real_freeaddrinfo = dlsym(RTLD_NEXT, "freeaddrinfo");
            }
            if (real_freeaddrinfo) real_freeaddrinfo(res);
            return;
        }
        struct addrinfo *next = res->ai_next;
        free(res->ai_addr);
        free(res->ai_canonname);
        free(w);
        res = next;
    }
}
