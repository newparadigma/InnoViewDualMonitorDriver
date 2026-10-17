// Thread-safe log: ~/Library/Logs/InnoViewDualMonitorDriver/driver_YYYYMMDD_HHMMSS.log + stderr.
#ifndef LOG_H
#define LOG_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

// to_file 0: stderr only (CLI tools).
void msx_log_open(int to_file);
void msx_log(const char *fmt, ...) __attribute__((format(printf, 1, 2)));
void msx_log_line(const char *line);  // ms_log_fn compatible
void msx_log_hex(const char *title, const uint8_t *data, size_t len);
const char *msx_log_path(void);       // NULL if not logging to file
const char *msx_log_dir(void);

#ifdef __cplusplus
}
#endif
#endif
