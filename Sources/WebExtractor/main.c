/* A single-threaded, fixed-path guardian for mpv's extractor subprocess. */
#define _DARWIN_C_SOURCE 1
#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <mach-o/dyld.h>
#include <poll.h>
#include <signal.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/proc.h>
#include <sys/sysctl.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

#if !defined(__APPLE__) || (!defined(__arm64__) && !defined(__aarch64__))
#error WebExtractor requires an Apple Silicon macOS target.
#endif

enum { FAILURE = 126, MISSING_HELPER = 127 };
struct job_result { int exit_code; };

static void diagnostic(const char *message) {
    (void)dprintf(STDERR_FILENO, "web-extractor: %s\n", message);
}

static double monotonic_seconds(void) {
    struct timespec value;
    if (clock_gettime(CLOCK_MONOTONIC, &value) != 0) return -1;
    return (double)value.tv_sec + (double)value.tv_nsec / 1e9;
}

static bool make_pipe(int descriptors[2]) {
    if (pipe(descriptors) != 0) return false;
    if (fcntl(descriptors[0], F_SETFD, FD_CLOEXEC) < 0 ||
        fcntl(descriptors[1], F_SETFD, FD_CLOEXEC) < 0) {
        close(descriptors[0]); close(descriptors[1]); return false;
    }
    return true;
}

/* The guardian owns only this descriptor-anchored tree. No symlink is followed. */
static bool empty_directory(int directory, unsigned depth) {
    if (depth > 64) return false;
    int duplicate = dup(directory);
    if (duplicate < 0) return false;
    DIR *entries = fdopendir(duplicate);
    if (!entries) { close(duplicate); return false; }
    bool success = true;
    struct dirent *entry;
    errno = 0;
    while ((entry = readdir(entries))) {
        if (!strcmp(entry->d_name, ".") || !strcmp(entry->d_name, "..")) continue;
        struct stat metadata;
        if (fstatat(directory, entry->d_name, &metadata, AT_SYMLINK_NOFOLLOW) != 0) {
            if (errno != ENOENT) success = false;
            errno = 0; continue;
        }
        if (S_ISDIR(metadata.st_mode)) {
            int child = openat(directory, entry->d_name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
            if (child < 0) success = false;
            else {
                if (!empty_directory(child, depth + 1)) success = false;
                close(child);
                if (unlinkat(directory, entry->d_name, AT_REMOVEDIR) != 0 && errno != ENOENT) success = false;
            }
        } else if (unlinkat(directory, entry->d_name, 0) != 0 && errno != ENOENT) success = false;
        errno = 0;
    }
    if (errno) success = false;
    closedir(entries);
    return success;
}

static bool remove_temporary(int descriptor, const char *path) {
    struct stat held, named;
    bool identity = fstat(descriptor, &held) == 0 && lstat(path, &named) == 0 &&
        S_ISDIR(named.st_mode) && held.st_dev == named.st_dev && held.st_ino == named.st_ino;
    bool emptied = empty_directory(descriptor, 0);
    close(descriptor);
    return identity && emptied && rmdir(path) == 0;
}

static bool parent_closed(int lifeline, pid_t expected_parent) {
    if (getppid() != expected_parent) return true;
    struct pollfd descriptor = { .fd = lifeline, .events = POLLIN | POLLHUP | POLLERR };
    int result;
    do { result = poll(&descriptor, 1, 0); } while (result < 0 && errno == EINTR);
    return result < 0 || (result > 0 && descriptor.revents != 0);
}

static void write_result(int descriptor, int code) {
    struct job_result result = { .exit_code = code };
    const unsigned char *bytes = (const unsigned char *)&result;
    size_t written = 0;
    while (written < sizeof(result)) {
        ssize_t count = write(descriptor, bytes + written, sizeof(result) - written);
        if (count < 0 && errno == EINTR) continue;
        if (count <= 0) break; /* Parent cancellation may have closed its reader. */
        written += (size_t)count;
    }
}

/* Darwin may return EPERM when a process group contains only zombies. The
   unreaped worker reserves the PGID while this kernel snapshot proves that
   no live group member still needs a signal. Any uncertainty fails closed. */
static bool group_is_zombie_only(pid_t worker) {
    int request[] = { CTL_KERN, KERN_PROC, KERN_PROC_PGRP, worker };
    size_t length = 0;
    if (sysctl(request, 4, NULL, &length, NULL, 0) != 0 ||
        length == 0 || length > SIZE_MAX - sizeof(struct kinfo_proc)) return false;
    size_t capacity = length + sizeof(struct kinfo_proc);
    struct kinfo_proc *members = malloc(capacity);
    if (!members) return false;
    length = capacity;
    bool success = sysctl(request, 4, members, &length, NULL, 0) == 0 &&
        length > 0 && length % sizeof(struct kinfo_proc) == 0;
    bool leader_present = false;
    if (success) {
        size_t count = length / sizeof(struct kinfo_proc);
        for (size_t index = 0; index < count; index++) {
            if (members[index].kp_eproc.e_pgid != worker ||
                members[index].kp_proc.p_stat != SZOMB) success = false;
            if (members[index].kp_proc.p_pid == worker) leader_present = true;
        }
    }
    free(members);
    return success && leader_present;
}

static bool signal_worker(pid_t worker, bool owns_group, int requested_signal) {
    if (kill(owns_group ? -worker : worker, requested_signal) == 0) return true;
    int signal_error = errno;
    if (signal_error == ESRCH) return true;
    if (signal_error == EPERM && owns_group && group_is_zombie_only(worker)) return true;
    (void)dprintf(STDERR_FILENO, "web-extractor: cleanup signal failed (%d)\n", signal_error);
    return false;
}

/* Keep the worker leader waitable until all cleanup signals have been sent.
   Its PID/PGID cannot be reused during the TERM grace period. */
static bool clean_worker(pid_t worker, bool owns_group, int *status) {
    bool success = signal_worker(worker, owns_group, SIGTERM);
    double started = monotonic_seconds();
    if (started < 0) success = false;
    else {
        for (;;) {
            double now = monotonic_seconds();
            if (now < 0) { success = false; break; }
            if (now - started >= 1.0) break;
            struct timespec interval = { .tv_sec = 0, .tv_nsec = 20000000 };
            while (nanosleep(&interval, &interval) < 0 && errno == EINTR) {}
        }
    }
    if (!signal_worker(worker, owns_group, SIGKILL)) success = false;
    pid_t waited;
    do { waited = waitpid(worker, status, 0); } while (waited < 0 && errno == EINTR);
    if (waited != worker) (void)dprintf(STDERR_FILENO, "web-extractor: worker reap failed (%d)\n", errno);
    return success && waited == worker;
}

static void guardian(pid_t wrapper, int lifeline, int result_pipe, int temporary_fd,
                     const char *temporary, const char *helper, char **arguments) {
    struct sigaction ignore = { .sa_handler = SIG_IGN };
    sigemptyset(&ignore.sa_mask);
    (void)sigaction(SIGPIPE, &ignore, NULL);
    if (parent_closed(lifeline, wrapper)) {
        (void)remove_temporary(temporary_fd, temporary);
        _exit(0);
    }
    pid_t worker = fork();
    if (worker < 0) {
        diagnostic("unable to fork extractor");
        (void)remove_temporary(temporary_fd, temporary);
        write_result(result_pipe, FAILURE); _exit(0);
    }
    if (!worker) {
        close(lifeline); close(result_pipe); close(temporary_fd);
        if (setpgid(0, 0) != 0) { diagnostic("unable to isolate extractor group"); _exit(FAILURE); }
        char temporary_env[PATH_MAX + 16], deno_env[PATH_MAX + 24];
        if (snprintf(temporary_env, sizeof temporary_env, "TMPDIR=%s", temporary) >= (int)sizeof temporary_env ||
            snprintf(deno_env, sizeof deno_env, "DENO_DIR=%s/deno", temporary) >= (int)sizeof deno_env) _exit(FAILURE);
        char *environment[] = {
            "PATH=/usr/bin:/bin:/usr/sbin:/sbin", "LANG=en_US.UTF-8", "LC_ALL=en_US.UTF-8",
            temporary_env, deno_env, "DENO_NO_UPDATE_CHECK=1", NULL
        };
        execve(helper, arguments, environment);
        int execution_error = errno;
        diagnostic("unable to execute bundled extractor");
        _exit(execution_error == ENOENT ? MISSING_HELPER : FAILURE);
    }
    int group_result = setpgid(worker, worker);
    bool owns_group = group_result == 0 || getpgid(worker) == worker;
    bool cancelled = false, observed_exit = false;
    if (!owns_group) diagnostic("unable to verify extractor group");
    while (owns_group) {
        if (parent_closed(lifeline, wrapper)) { cancelled = true; break; }
        siginfo_t information;
        memset(&information, 0, sizeof information);
        if (waitid(P_PID, (id_t)worker, &information, WEXITED | WNOHANG | WNOWAIT) != 0) {
            if (errno == EINTR) continue;
            diagnostic("unable to observe extractor completion"); break;
        }
        if (information.si_pid == worker) { observed_exit = true; break; }
        struct pollfd descriptor = { .fd = lifeline, .events = POLLIN | POLLHUP | POLLERR };
        int result = poll(&descriptor, 1, 50);
        if (result < 0 && errno != EINTR) { cancelled = true; break; }
    }
    int status = 0;
    bool cleaned = clean_worker(worker, owns_group, &status);
    bool removed = remove_temporary(temporary_fd, temporary);
    int code = FAILURE;
    if (observed_exit && cleaned && removed) {
        if (WIFEXITED(status)) code = WEXITSTATUS(status);
        else if (WIFSIGNALED(status)) code = 128 + WTERMSIG(status);
    }
    if (!removed) diagnostic("unable to remove private extractor directory");
    if (!cancelled && !parent_closed(lifeline, wrapper)) write_result(result_pipe, code);
    close(lifeline); close(result_pipe);
    _exit(0);
}

static bool helper_path(char output[PATH_MAX]) {
    char executable[PATH_MAX], resolved[PATH_MAX];
    uint32_t length = sizeof executable;
    if (_NSGetExecutablePath(executable, &length) != 0 || !realpath(executable, resolved)) return false;
    char *last = strrchr(resolved, '/');
    if (!last) return false;
    *last = '\0';
    return snprintf(output, PATH_MAX, "%s/yt-dlp/yt-dlp_macos", resolved) < PATH_MAX;
}

int main(int argc, char **argv) {
    struct sigaction normal = { .sa_handler = SIG_DFL };
    sigemptyset(&normal.sa_mask);
    for (int signal_number = 1; signal_number < NSIG; signal_number++) {
        if (signal_number != SIGKILL && signal_number != SIGSTOP) (void)sigaction(signal_number, &normal, NULL);
    }
    sigset_t unblocked;
    sigemptyset(&unblocked);
    if (sigprocmask(SIG_SETMASK, &unblocked, NULL) != 0) return FAILURE;
    char helper[PATH_MAX];
    if (!helper_path(helper) || access(helper, X_OK) != 0) {
        diagnostic("bundled extractor is missing or not executable"); return MISSING_HELPER;
    }
    char **arguments = calloc((size_t)argc + 1, sizeof *arguments);
    if (!arguments) return FAILURE;
    arguments[0] = helper;
    for (int index = 1; index < argc; index++) arguments[index] = argv[index];
    char temporary[] = "/tmp/SiliconPlayer-WebExtractor-XXXXXX";
    if (!mkdtemp(temporary)) { free(arguments); return FAILURE; }
    int temporary_fd = open(temporary, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
    if (temporary_fd < 0 || mkdirat(temporary_fd, "deno", 0700) != 0) {
        if (temporary_fd >= 0) (void)remove_temporary(temporary_fd, temporary);
        else (void)rmdir(temporary);
        free(arguments); return FAILURE;
    }
    int lifeline[2], results[2];
    if (!make_pipe(lifeline)) { (void)remove_temporary(temporary_fd, temporary); free(arguments); return FAILURE; }
    if (!make_pipe(results)) {
        close(lifeline[0]); close(lifeline[1]); (void)remove_temporary(temporary_fd, temporary); free(arguments); return FAILURE;
    }
    pid_t wrapper = getpid(), guard = fork();
    if (guard < 0) {
        close(lifeline[0]); close(lifeline[1]); close(results[0]); close(results[1]);
        (void)remove_temporary(temporary_fd, temporary); free(arguments); return FAILURE;
    }
    if (!guard) {
        close(lifeline[1]); close(results[0]);
        guardian(wrapper, lifeline[0], results[1], temporary_fd, temporary, helper, arguments);
    }
    close(lifeline[0]); close(results[1]); close(temporary_fd); free(arguments);
    struct job_result result;
    unsigned char *bytes = (unsigned char *)&result;
    size_t received = 0;
    while (received < sizeof result) {
        ssize_t count = read(results[0], bytes + received, sizeof result - received);
        if (count < 0 && errno == EINTR) continue;
        if (count <= 0) break;
        received += (size_t)count;
    }
    close(results[0]); close(lifeline[1]);
    int guardian_status = 0;
    pid_t waited;
    do { waited = waitpid(guard, &guardian_status, 0); } while (waited < 0 && errno == EINTR);
    if (received != sizeof result || waited != guard || !WIFEXITED(guardian_status) || WEXITSTATUS(guardian_status) != 0) return FAILURE;
    return result.exit_code >= 0 && result.exit_code <= 255 ? result.exit_code : FAILURE;
}
