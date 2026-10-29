#ifndef PROCESS_BRIDGE_H
#define PROCESS_BRIDGE_H
#include <stdint.h>
#include <stddef.h>

typedef struct {
    int32_t pid, parent_pid;
    uint32_t uid, real_uid, saved_uid, flags;
    uint64_t start_seconds, start_microseconds;
    uint64_t resident_bytes, cpu_nanoseconds;
    int has_metrics;
} PLProcessInfo;

int pl_process_info(int32_t pid, PLProcessInfo *result);
int pl_executable(int32_t pid, char *buffer, int capacity);
int pl_cwd(int32_t pid, char *buffer, int capacity);
// Only argv, never environment variables. Returns copied bytes, NUL-separated.
int pl_arguments(int32_t pid, char *buffer, int capacity);
// Positive PID only; validates ownership, start time and executable immediately before SIGTERM.
int pl_terminate_checked(int32_t pid, uint32_t uid, uint64_t seconds,
                         uint64_t microseconds, const char *executable);
#endif
