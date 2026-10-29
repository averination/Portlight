#include "ProcessBridge.h"
#include <libproc.h>
#include <sys/proc_info.h>
#include <sys/sysctl.h>
#include <signal.h>
#include <unistd.h>
#include <errno.h>
#include <stdlib.h>
#include <string.h>

int pl_process_info(int32_t pid, PLProcessInfo *result) {
    struct proc_bsdinfo info = {0};
    if (pid <= 1 || proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, sizeof(info)) != sizeof(info)) return 0;
    memset(result, 0, sizeof(*result));
    result->pid = pid;
    result->parent_pid = info.pbi_ppid;
    result->uid = info.pbi_uid;
    result->real_uid = info.pbi_ruid;
    result->saved_uid = info.pbi_svuid;
    result->flags = info.pbi_flags;
    result->start_seconds = info.pbi_start_tvsec;
    result->start_microseconds = info.pbi_start_tvusec;
    struct proc_taskinfo task = {0};
    if (proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &task, sizeof(task)) == sizeof(task)) {
        result->has_metrics = 1;
        result->resident_bytes = task.pti_resident_size;
        result->cpu_nanoseconds = task.pti_total_user + task.pti_total_system;
    }
    return 1;
}

int pl_executable(int32_t pid, char *buffer, int capacity) {
    return proc_pidpath(pid, buffer, (uint32_t)capacity);
}

int pl_cwd(int32_t pid, char *buffer, int capacity) {
    struct proc_vnodepathinfo paths = {0};
    if (proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &paths, sizeof(paths)) != sizeof(paths)) return 0;
    size_t n = strnlen(paths.pvi_cdir.vip_path, sizeof(paths.pvi_cdir.vip_path));
    if (n == 0 || n >= (size_t)capacity) return 0;
    memcpy(buffer, paths.pvi_cdir.vip_path, n);
    buffer[n] = 0;
    return (int)n;
}

int pl_arguments(int32_t pid, char *buffer, int capacity) {
    int mib[] = { CTL_KERN, KERN_PROCARGS2, pid };
    size_t size = 0;
    if (sysctl(mib, 3, NULL, &size, NULL, 0) != 0 || size < sizeof(int) || size > 4 * 1024 * 1024) return 0;
    char *data = calloc(1, size);
    if (!data) return 0;
    if (sysctl(mib, 3, data, &size, NULL, 0) != 0) { free(data); return 0; }
    int argc = 0;
    memcpy(&argc, data, sizeof(argc));
    char *cursor = data + sizeof(argc), *end = data + size;
    // Skip executable path and padding before argv[0].
    while (cursor < end && *cursor) cursor++;
    while (cursor < end && !*cursor) cursor++;
    int copied = 0;
    for (int i = 0; i < argc && cursor < end; i++) {
        size_t len = strnlen(cursor, (size_t)(end - cursor));
        if (cursor + len >= end || copied + len + 1 > (size_t)capacity) { copied = 0; break; }
        memcpy(buffer + copied, cursor, len + 1);
        copied += (int)len + 1;
        cursor += len + 1;
    }
    free(data);
    return copied;
}

int pl_terminate_checked(int32_t pid, uint32_t uid, uint64_t seconds,
                         uint64_t microseconds, const char *executable) {
    if (uid == 0 || uid != getuid() || uid != geteuid() || pid <= 1 || pid == getpid()) return EPERM;
    // Never terminate this utility's ancestor chain.
    int32_t ancestor = getppid();
    for (int depth = 0; ancestor > 1 && depth < 128; depth++) {
        if (pid == ancestor) return EPERM;
        PLProcessInfo parent;
        if (!pl_process_info(ancestor, &parent)) return EPERM; // fail closed
        if (parent.parent_pid == ancestor) return EPERM;
        ancestor = parent.parent_pid;
    }
    PLProcessInfo info;
    if (!pl_process_info(pid, &info)) return ESRCH;
    if (info.uid != uid || info.real_uid != uid || info.saved_uid != uid ||
        (info.flags & (PROC_FLAG_SYSTEM | PROC_FLAG_PSUGID)) ||
        info.start_seconds != seconds || info.start_microseconds != microseconds) return EPERM;
    char path[PROC_PIDPATHINFO_MAXSIZE] = {0};
    if (pl_executable(pid, path, sizeof(path)) <= 0 || strcmp(path, executable) != 0) return EPERM;
    // macOS has no pidfd: keep the unavoidable check-to-signal window very small.
    return kill(pid, SIGTERM) == 0 ? 0 : errno;
}
