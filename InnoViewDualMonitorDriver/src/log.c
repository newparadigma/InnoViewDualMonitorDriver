#include "log.h"

#include <dirent.h>
#include <pthread.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/time.h>
#include <time.h>
#include <unistd.h>

#define KEEP_LOGS 20

static pthread_mutex_t g_lock = PTHREAD_MUTEX_INITIALIZER;
static FILE *g_file;
static char g_path[1024];
static char g_dir[1024];

static int cmp_names(const void *a, const void *b) { return strcmp(*(char *const *)a, *(char *const *)b); }

static void prune_old_logs(void) {
    DIR *d = opendir(g_dir);
    if (!d) return;
    char *names[512];
    int n = 0;
    struct dirent *e;
    while ((e = readdir(d)) && n < 512)
        if (strncmp(e->d_name, "driver_", 7) == 0) names[n++] = strdup(e->d_name);
    closedir(d);
    qsort(names, n, sizeof names[0], cmp_names);
    for (int i = 0; i < n; i++) {
        if (i < n - KEEP_LOGS) {
            char p[2048];
            snprintf(p, sizeof p, "%s/%s", g_dir, names[i]);
            unlink(p);
        }
        free(names[i]);
    }
}

void msx_log_open(int to_file) {
    const char *home = getenv("HOME");
    snprintf(g_dir, sizeof g_dir, "%s/Library/Logs/InnoViewDualMonitorDriver", home ? home : "/tmp");
    if (!to_file) return;
    mkdir(g_dir, 0755);
    prune_old_logs();
    time_t t = time(NULL);
    struct tm tm;
    localtime_r(&t, &tm);
    char stamp[32];
    strftime(stamp, sizeof stamp, "%Y%m%d_%H%M%S", &tm);
    snprintf(g_path, sizeof g_path, "%s/driver_%s.log", g_dir, stamp);
    g_file = fopen(g_path, "a");
    if (!g_file) g_path[0] = 0;
}

const char *msx_log_path(void) { return g_path[0] ? g_path : NULL; }
const char *msx_log_dir(void) { return g_dir; }

void msx_log_line(const char *line) {
    struct timeval tv;
    gettimeofday(&tv, NULL);
    struct tm tm;
    localtime_r(&tv.tv_sec, &tm);
    char stamp[32];
    strftime(stamp, sizeof stamp, "%m-%d %H:%M:%S", &tm);
    pthread_mutex_lock(&g_lock);
    fprintf(stderr, "[%s.%03d] %s\n", stamp, (int)(tv.tv_usec / 1000), line);
    if (g_file) {
        fprintf(g_file, "[%s.%03d] %s\n", stamp, (int)(tv.tv_usec / 1000), line);
        fflush(g_file);
    }
    pthread_mutex_unlock(&g_lock);
}

void msx_log(const char *fmt, ...) {
    char line[1024];
    va_list ap;
    va_start(ap, fmt);
    vsnprintf(line, sizeof line, fmt, ap);
    va_end(ap);
    msx_log_line(line);
}

void msx_log_hex(const char *title, const uint8_t *data, size_t len) {
    msx_log("%s", title);
    for (size_t off = 0; off < len; off += 16) {
        char line[80];
        int n = snprintf(line, sizeof line, "%04zx ", off);
        for (size_t i = off; i < off + 16 && i < len; i++)
            n += snprintf(line + n, sizeof line - n, i == off + 8 ? "-%02x" : " %02x", data[i]);
        msx_log_line(line);
    }
}
