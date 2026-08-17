/*
* Copyright (c) 2026 Calvin Rose
*
* Permission is hereby granted, free of charge, to any person obtaining a copy
* of this software and associated documentation files (the "Software"), to
* deal in the Software without restriction, including without limitation the
* rights to use, copy, modify, merge, publish, distribute, sublicense, and/or
* sell copies of the Software, and to permit persons to whom the Software is
* furnished to do so, subject to the following conditions:
*
* The above copyright notice and this permission notice shall be included in
* all copies or substantial portions of the Software.
*
* THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
* IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
* FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
* AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
* LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING
* FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS
* IN THE SOFTWARE.
*/

#ifndef JANET_AMALG
#include "features.h"
#include <janet.h>
#include "util.h"
#endif

#ifdef JANET_EV
#ifdef JANET_FILEWATCH

#ifdef JANET_LINUX
#include <sys/inotify.h>
#include <unistd.h>
#endif

#ifdef JANET_WINDOWS
#include <windows.h>
#endif

#if defined(JANET_APPLE) || defined(JANET_BSD)
#include <sys/event.h>
#include <sys/stat.h>
#include <unistd.h>
#include <fcntl.h>
#endif

/* Which backend's keyword vocabulary a lookup refers to. Mirrored by the
 * `Platform` enumeration in `src/zig/subsystems/filewatch_flags.zig`; the
 * assertion below fails the build if either side is renumbered alone. */
#define JANET_WATCH_PLATFORM_LINUX 0u
#define JANET_WATCH_PLATFORM_WINDOWS 1u
#define JANET_WATCH_PLATFORM_KQUEUE 2u

typedef char janet_watch_platforms_are_mirrored[
             (JANET_WATCH_PLATFORM_LINUX == 0 &&
              JANET_WATCH_PLATFORM_WINDOWS == 1 &&
              JANET_WATCH_PLATFORM_KQUEUE == 2) ? 1 : -1];

/* The name tables live in the subsystem, which compiles all three on every
 * target; only the flag values below are host facts. Declared unconditionally
 * so the declaration is checked whichever implementation the build selects. */
extern int32_t janet_filewatch_flag_index(uint32_t platform, const uint8_t *name, int32_t len);
extern int32_t janet_filewatch_flag_count(uint32_t platform);
extern const char *janet_filewatch_flag_name(uint32_t platform, int32_t index);
extern const char *janet_filewatch_action_name(int32_t action);

#ifndef JANET_ZIG_FILEWATCH_FLAGS

/* The C half of the same split, selected by `-Dfilewatch-flags=c`.
 *
 * Only the names are here, which is why — unlike the tables this increment
 * replaced — all three compile on every host: a name is a string, not a host
 * constant. That is what lets either implementation answer for a backend the
 * build is not running on, and it is what makes the two comparable at all. */

static const char *const watcher_names_linux[] = {
    "access", "all", "attrib", "close-nowrite", "close-write", "create",
    "delete", "delete-self", "ignored", "modify", "move-self", "moved-from",
    "moved-to", "open", "q-overflow", "unmount",
};

static const char *const watcher_names_windows[] = {
    "all", "attributes", "creation", "dir-name", "file-name", "last-access",
    "last-write", "recursive", "security", "size",
};

static const char *const watcher_names_kqueue[] = {
    "all", "attrib", "close", "close-write", "delete", "extend", "funlock",
    "link", "open", "read", "rename", "revoke", "truncate", "write",
};

static const char *const watcher_action_names[] = {
    "unknown", "added", "removed", "modified", "renamed-old", "renamed-new",
};

static const char *const *janet_watch_names_for(uint32_t platform, int32_t *count) {
    switch (platform) {
        case JANET_WATCH_PLATFORM_LINUX:
            *count = (int32_t)(sizeof(watcher_names_linux) / sizeof(const char *));
            return watcher_names_linux;
        case JANET_WATCH_PLATFORM_WINDOWS:
            *count = (int32_t)(sizeof(watcher_names_windows) / sizeof(const char *));
            return watcher_names_windows;
        case JANET_WATCH_PLATFORM_KQUEUE:
            *count = (int32_t)(sizeof(watcher_names_kqueue) / sizeof(const char *));
            return watcher_names_kqueue;
        default:
            *count = 0;
            return NULL;
    }
}

/* Compared by length and bytes rather than with `janet_cstrcmp`, because a
 * Janet keyword is length-prefixed and may contain a zero byte. A keyword
 * holding one matches nothing, which is what the original binary search did
 * too — it just arrived there by comparing against the name's terminator. */
int32_t janet_filewatch_flag_index(uint32_t platform, const uint8_t *name, int32_t len) {
    int32_t count = 0;
    const char *const *names = janet_watch_names_for(platform, &count);
    if (NULL == names || len < 0) return -1;
    for (int32_t i = 0; i < count; i++) {
        size_t entry_len = strlen(names[i]);
        if (entry_len == (size_t) len && 0 == memcmp(names[i], name, entry_len)) {
            return i;
        }
    }
    return -1;
}

int32_t janet_filewatch_flag_count(uint32_t platform) {
    int32_t count = 0;
    return (NULL == janet_watch_names_for(platform, &count)) ? -1 : count;
}

const char *janet_filewatch_flag_name(uint32_t platform, int32_t index) {
    int32_t count = 0;
    const char *const *names = janet_watch_names_for(platform, &count);
    if (NULL == names || index < 0 || index >= count) return NULL;
    return names[index];
}

const char *janet_filewatch_action_name(int32_t action) {
    if (action < 0 || action >= (int32_t)(sizeof(watcher_action_names) / sizeof(const char *))) {
        return NULL;
    }
    return watcher_action_names[action];
}

#endif /* JANET_ZIG_FILEWATCH_FLAGS */

/* Turn a run of keyword options into a flag mask for one backend.
 *
 * `values` is the backend's flag values in the table's own order, so the index
 * the lookup reports selects one directly. A zero there means the host's
 * headers do not define that constant — the BSDs disagree about several — and
 * the name is refused exactly as it was when the entry was absent altogether.
 * `what` names the backend in the panic, which is the only part of the message
 * that ever differed between them. */
static uint32_t janet_watch_decode_flags(const Janet *options, int32_t n,
                                         uint32_t platform, const uint32_t *values,
                                         const char *what) {
    uint32_t flags = 0;
    for (int32_t i = 0; i < n; i++) {
        if (!(janet_checktype(options[i], JANET_KEYWORD))) {
            janet_panicf("expected keyword, got %v", options[i]);
        }
        JanetKeyword keyw = janet_unwrap_keyword(options[i]);
        int32_t index = janet_filewatch_flag_index(platform, keyw, janet_string_length(keyw));
        if (index < 0 || values[index] == 0) {
            janet_panicf("unknown %s flag %v", what, options[i]);
        }
        flags |= values[index];
    }
    return flags;
}

typedef struct {
#ifndef JANET_WINDOWS
    JanetStream *stream;
#endif
    JanetTable *watch_descriptors;
    JanetChannel *channel;
    uint32_t default_flags;
    int is_watching;
} JanetWatcher;

#ifdef JANET_LINUX

#include <sys/inotify.h>
#include <unistd.h>

/* inotify's flag values, in the order the subsystem's `linux_names` lists
 * them. The two arrays are one table split in half, so an edit to either has to
 * be an edit to both. The assertion below pins this half's length, and
 * `test/filewatch_flags.c` pins the other half's to the same number. */
static const uint32_t watcher_flag_values_linux[] = {
    IN_ACCESS,
    IN_ALL_EVENTS,
    IN_ATTRIB,
    IN_CLOSE_NOWRITE,
    IN_CLOSE_WRITE,
    IN_CREATE,
    IN_DELETE,
    IN_DELETE_SELF,
    IN_IGNORED,
    IN_MODIFY,
    IN_MOVE_SELF,
    IN_MOVED_FROM,
    IN_MOVED_TO,
    IN_OPEN,
    IN_Q_OVERFLOW,
    IN_UNMOUNT,
};

typedef char janet_watch_linux_table_is_whole[
             (sizeof(watcher_flag_values_linux) / sizeof(uint32_t) == 16) ? 1 : -1];

static uint32_t decode_watch_flags(const Janet *options, int32_t n) {
    return janet_watch_decode_flags(options, n, JANET_WATCH_PLATFORM_LINUX,
                                    watcher_flag_values_linux, "linux");
}

static void janet_watcher_init(JanetWatcher *watcher, JanetChannel *channel, uint32_t default_flags) {
    int fd;
    do {
        fd = inotify_init1(IN_NONBLOCK | IN_CLOEXEC);
    } while (fd == -1 && errno == EINTR);
    if (fd == -1) {
        janet_panicv(janet_ev_lasterr());
    }
    watcher->watch_descriptors = janet_table(0);
    watcher->channel = channel;
    watcher->default_flags = default_flags;
    watcher->is_watching = 0;
    watcher->stream = janet_stream(fd, JANET_STREAM_READABLE, NULL);
}

static void janet_watcher_add(JanetWatcher *watcher, const char *path, uint32_t flags) {
    if (watcher->stream == NULL) janet_panic("watcher closed");
    int result;
    do {
        result = inotify_add_watch(watcher->stream->handle, path, flags);
    } while (result == -1 && errno == EINTR);
    if (result == -1) {
        janet_panicv(janet_ev_lasterr());
    }
    Janet name = janet_cstringv(path);
    Janet wd = janet_wrap_integer(result);
    janet_table_put(watcher->watch_descriptors, name, wd);
    janet_table_put(watcher->watch_descriptors, wd, name);
}

static void janet_watcher_remove(JanetWatcher *watcher, const char *path) {
    if (watcher->stream == NULL) janet_panic("watcher closed");
    Janet pathv = janet_cstringv(path);
    Janet check = janet_table_get(watcher->watch_descriptors, pathv);
    if (!janet_checktype(check, JANET_NUMBER)) {
        janet_panic("bad watch descriptor");
    }
    int watch_handle = janet_unwrap_integer(check);
    int result;
    do {
        result = inotify_rm_watch(watcher->stream->handle, watch_handle);
    } while (result != -1 && errno == EINTR);
    if (result == -1) {
        janet_panicv(janet_ev_lasterr());
    }
    /*
    janet_table_put(watcher->watch_descriptors, pathv, janet_wrap_nil());
    janet_table_put(watcher->watch_descriptors, janet_wrap_integer(watch_handle), janet_wrap_nil());
    */
}

static void watcher_callback_read(JanetFiber *fiber, JanetAsyncEvent event) {
    JanetStream *stream = fiber->ev_stream;
    JanetWatcher *watcher = *((JanetWatcher **) fiber->ev_state);
    char buf[1024];
    switch (event) {
        default:
            break;
        case JANET_ASYNC_EVENT_MARK:
            janet_mark(janet_wrap_abstract(watcher));
            break;
        case JANET_ASYNC_EVENT_CLOSE:
            janet_schedule(fiber, janet_wrap_nil());
            janet_async_end(fiber);
            break;
        case JANET_ASYNC_EVENT_ERR: {
            janet_schedule(fiber, janet_wrap_nil());
            janet_async_end(fiber);
            break;
        }
    read_more:
        case JANET_ASYNC_EVENT_HUP:
        case JANET_ASYNC_EVENT_INIT:
        case JANET_ASYNC_EVENT_READ: {
            Janet name = janet_wrap_nil();

            /* Assumption - read will never return partial events *
             * From documentation:
             *
             * The behavior when the buffer given to read(2) is too small to
             * return information about the next event depends on the kernel
             * version: before Linux 2.6.21, read(2) returns 0; since Linux
             * 2.6.21, read(2) fails with the error EINVAL.  Specifying a buffer
             * of size
             *
             *     sizeof(struct inotify_event) + NAME_MAX + 1
             *
             * will be sufficient to read at least one event. */
            ssize_t nread;
            do {
                nread = read(stream->handle, buf, sizeof(buf));
            } while (nread == -1 && errno == EINTR);

            /* Check for errors - special case errors that can just be waited on to fix */
            if (nread == -1) {
                if (errno == EAGAIN || errno == EWOULDBLOCK) {
                    break;
                }
                janet_cancel(fiber, janet_ev_lasterr());
                fiber->ev_state = NULL;
                janet_async_end(fiber);
                break;
            }
            if (nread < (ssize_t) sizeof(struct inotify_event)) break;

            /* Iterate through all events read from the buffer */
            char *cursor = buf;
            while (cursor < buf + nread) {
                struct inotify_event inevent;
                memcpy(&inevent, cursor, sizeof(inevent));
                cursor += sizeof(inevent);
                /* Read path of inevent */
                if (inevent.len) {
                    name = janet_cstringv(cursor);
                    cursor += inevent.len;
                }

                /* Got an event */
                Janet path = janet_table_get(watcher->watch_descriptors, janet_wrap_integer(inevent.wd));
                JanetKV *event = janet_struct_begin(6);
                janet_struct_put(event, janet_ckeywordv("wd"), janet_wrap_integer(inevent.wd));
                janet_struct_put(event, janet_ckeywordv("wd-path"), path);
                if (janet_checktype(name, JANET_NIL)) {
                    /* We were watching a file directly, so path is the full path. Split into dirname / basename */
                    JanetString spath = janet_unwrap_string(path);
                    const uint8_t *cursor = spath + janet_string_length(spath);
                    const uint8_t *cursor_end = cursor;
                    while (cursor > spath && cursor[0] != '/') {
                        cursor--;
                    }
                    if (cursor == spath) {
                        janet_struct_put(event, janet_ckeywordv("dir-name"), path);
                        janet_struct_put(event, janet_ckeywordv("file-name"), name);
                    } else {
                        janet_struct_put(event, janet_ckeywordv("dir-name"), janet_wrap_string(janet_string(spath, (cursor - spath))));
                        janet_struct_put(event, janet_ckeywordv("file-name"), janet_wrap_string(janet_string(cursor + 1, (cursor_end - cursor - 1))));
                    }
                } else {
                    janet_struct_put(event, janet_ckeywordv("dir-name"), path);
                    janet_struct_put(event, janet_ckeywordv("file-name"), name);
                }
                janet_struct_put(event, janet_ckeywordv("cookie"), janet_wrap_integer(inevent.cookie));
                Janet etype = janet_ckeywordv("type");
                /* Reported in table order, and `janet_struct_put` overwrites,
                 * so the last matching name wins as it did before. The zero
                 * check is for the split's absent-constant convention; every
                 * inotify constant is defined, but without it a zero would
                 * match every mask rather than none. */
                int32_t flag_count = janet_filewatch_flag_count(JANET_WATCH_PLATFORM_LINUX);
                for (int32_t fi = 0; fi < flag_count; fi++) {
                    uint32_t flag = watcher_flag_values_linux[fi];
                    if (flag != 0 && (inevent.mask & flag) == flag) {
                        janet_struct_put(event, etype,
                                         janet_ckeywordv(janet_filewatch_flag_name(JANET_WATCH_PLATFORM_LINUX, fi)));
                    }
                }
                Janet eventv = janet_wrap_struct(janet_struct_end(event));

                janet_channel_give(watcher->channel, eventv);
            }

            /* Read some more if possible */
            goto read_more;
        }
        break;
    }
}

static void janet_watcher_listen(JanetWatcher *watcher) {
    if (watcher->is_watching) janet_panic("already watching");
    watcher->is_watching = 1;
    JanetFunction *thunk = janet_thunk_delay(janet_wrap_nil());
    JanetFiber *fiber = janet_fiber(thunk, 64, 0, NULL);
    JanetWatcher **state = janet_malloc(sizeof(JanetWatcher *)); /* Gross */
    *state = watcher;
    janet_async_start_fiber(fiber, watcher->stream, JANET_ASYNC_LISTEN_READ, watcher_callback_read, state);
    janet_gcroot(janet_wrap_abstract(watcher));
}

static void janet_watcher_unlisten(JanetWatcher *watcher) {
    if (!watcher->is_watching) return;
    watcher->is_watching = 0;
    janet_stream_close(watcher->stream);
    janet_gcunroot(janet_wrap_abstract(watcher));
}

#elif JANET_WINDOWS

#define WATCHFLAG_RECURSIVE 0x100000u

/* The `ReadDirectoryChangesW` filter values, in the order the subsystem's
 * `windows_names` lists them. See the note on the Linux half. */
static const uint32_t watcher_flag_values_windows[] = {
    FILE_NOTIFY_CHANGE_ATTRIBUTES |
    FILE_NOTIFY_CHANGE_CREATION |
    FILE_NOTIFY_CHANGE_DIR_NAME |
    FILE_NOTIFY_CHANGE_FILE_NAME |
    FILE_NOTIFY_CHANGE_LAST_ACCESS |
    FILE_NOTIFY_CHANGE_LAST_WRITE |
    FILE_NOTIFY_CHANGE_SECURITY |
    FILE_NOTIFY_CHANGE_SIZE |
    WATCHFLAG_RECURSIVE,
    FILE_NOTIFY_CHANGE_ATTRIBUTES,
    FILE_NOTIFY_CHANGE_CREATION,
    FILE_NOTIFY_CHANGE_DIR_NAME,
    FILE_NOTIFY_CHANGE_FILE_NAME,
    FILE_NOTIFY_CHANGE_LAST_ACCESS,
    FILE_NOTIFY_CHANGE_LAST_WRITE,
    WATCHFLAG_RECURSIVE,
    FILE_NOTIFY_CHANGE_SECURITY,
    FILE_NOTIFY_CHANGE_SIZE,
};

typedef char janet_watch_windows_table_is_whole[
             (sizeof(watcher_flag_values_windows) / sizeof(uint32_t) == 10) ? 1 : -1];

static uint32_t decode_watch_flags(const Janet *options, int32_t n) {
    return janet_watch_decode_flags(options, n, JANET_WATCH_PLATFORM_WINDOWS,
                                    watcher_flag_values_windows, "windows filewatch");
}

static void janet_watcher_init(JanetWatcher *watcher, JanetChannel *channel, uint32_t default_flags) {
    watcher->watch_descriptors = janet_table(0);
    watcher->channel = channel;
    watcher->default_flags = default_flags;
    watcher->is_watching = 0;
}

/* Since the file info padding includes embedded file names, we want to include more space for data.
 * We also need to handle manually calculating changes if path names are too long, but ideally just avoid
 * that scenario as much as possible */
#define FILE_INFO_PADDING (4096 * 4)

typedef struct {
    JanetOverlapped overlapped;
    JanetStream *stream;
    JanetWatcher *watcher;
    JanetFiber *fiber;
    JanetString dir_path;
    uint32_t flags;
    uint64_t buf[FILE_INFO_PADDING / sizeof(uint64_t)]; /* Ensure alignment */
} OverlappedWatch;

#define NotifyChange FILE_NOTIFY_INFORMATION

static void read_dir_changes(OverlappedWatch *ow) {
    BOOL result = ReadDirectoryChangesW(ow->stream->handle,
                                        (NotifyChange *) ow->buf,
                                        FILE_INFO_PADDING,
                                        (ow->flags & WATCHFLAG_RECURSIVE) ? TRUE : FALSE,
                                        ow->flags & ~WATCHFLAG_RECURSIVE,
                                        NULL,
                                        (OVERLAPPED *) ow,
                                        NULL);
    if (!result) {
        janet_panicv(janet_ev_lasterr());
    }
}

static void watcher_callback_read(JanetFiber *fiber, JanetAsyncEvent event) {
    OverlappedWatch *ow = (OverlappedWatch *) fiber->ev_state;
    JanetWatcher *watcher = ow->watcher;
    switch (event) {
        default:
            break;
        case JANET_ASYNC_EVENT_INIT:
            janet_async_in_flight(fiber);
            break;
        case JANET_ASYNC_EVENT_MARK:
            janet_mark(janet_wrap_abstract(ow->stream));
            janet_mark(janet_wrap_fiber(ow->fiber));
            janet_mark(janet_wrap_abstract(watcher));
            janet_mark(janet_wrap_string(ow->dir_path));
            break;
        case JANET_ASYNC_EVENT_CLOSE:
            janet_table_remove(ow->watcher->watch_descriptors, janet_wrap_string(ow->dir_path));
            break;
        case JANET_ASYNC_EVENT_ERR:
        case JANET_ASYNC_EVENT_FAILED:
            janet_stream_close(ow->stream);
            break;
        case JANET_ASYNC_EVENT_COMPLETE: {
            if (!watcher->is_watching) {
                janet_stream_close(ow->stream);
                break;
            }

            NotifyChange *fni = (NotifyChange *) ow->buf;

            while (1) {
                /* Got an event */

                /* Extract name */
                Janet filename;
                if (fni->FileNameLength) {
                    int32_t nbytes = (int32_t) WideCharToMultiByte(CP_UTF8, 0, fni->FileName, fni->FileNameLength / sizeof(wchar_t), NULL, 0, NULL, NULL);
                    janet_assert(nbytes, "bad utf8 path");
                    uint8_t *into = janet_string_begin(nbytes);
                    WideCharToMultiByte(CP_UTF8, 0, fni->FileName, fni->FileNameLength / sizeof(wchar_t), (char *) into, nbytes, NULL, NULL);
                    filename = janet_wrap_string(janet_string_end(into));
                } else {
                    filename = janet_cstringv("");
                }

                JanetKV *event = janet_struct_begin(3);
                /* The original indexed a six-entry array with the action code
                 * and had nothing to say about a code outside it. The lookup
                 * reports NULL there instead, so name the fallback explicitly
                 * rather than read past the end. */
                const char *action = janet_filewatch_action_name((int32_t) fni->Action);
                if (NULL == action) action = "unknown";
                janet_struct_put(event, janet_ckeywordv("type"), janet_ckeywordv(action));
                janet_struct_put(event, janet_ckeywordv("file-name"), filename);
                janet_struct_put(event, janet_ckeywordv("dir-name"), janet_wrap_string(ow->dir_path));
                Janet eventv = janet_wrap_struct(janet_struct_end(event));

                janet_channel_give(watcher->channel, eventv);

                /* Next event */
                if (!fni->NextEntryOffset) break;
                fni = (NotifyChange *)((char *)fni + fni->NextEntryOffset);
            }

            /* Make another call to read directory changes */
            read_dir_changes(ow);
            janet_async_in_flight(fiber);
        }
        break;
    }
}

static void start_listening_ow(OverlappedWatch *ow) {
    read_dir_changes(ow);
    JanetStream *stream = ow->stream;
    JanetFunction *thunk = janet_thunk_delay(janet_wrap_nil());
    JanetFiber *fiber = janet_fiber(thunk, 64, 0, NULL);
    fiber->supervisor_channel = janet_root_fiber()->supervisor_channel;
    ow->fiber = fiber;
    janet_async_start_fiber(fiber, stream, JANET_ASYNC_LISTEN_READ, watcher_callback_read, ow);
}

static void janet_watcher_add(JanetWatcher *watcher, const char *path, uint32_t flags) {
    HANDLE handle = CreateFileA(path,
                                FILE_LIST_DIRECTORY | GENERIC_READ,
                                FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE,
                                NULL,
                                OPEN_EXISTING,
                                FILE_FLAG_OVERLAPPED | FILE_FLAG_BACKUP_SEMANTICS,
                                NULL);
    if (handle == INVALID_HANDLE_VALUE) {
        janet_panicv(janet_ev_lasterr());
    }
    JanetStream *stream = janet_stream(handle, JANET_STREAM_READABLE, NULL);
    OverlappedWatch *ow = janet_malloc(sizeof(OverlappedWatch));
    memset(ow, 0, sizeof(OverlappedWatch));
    ow->stream = stream;
    ow->dir_path = janet_cstring(path);
    ow->fiber = NULL;
    Janet pathv = janet_wrap_string(ow->dir_path);
    ow->flags = flags | watcher->default_flags;
    ow->watcher = watcher;
    ow->overlapped.as.overlapped.hEvent = CreateEvent(NULL, FALSE, 0, NULL); /* Do we need this */
    Janet streamv = janet_wrap_pointer(ow);
    janet_table_put(watcher->watch_descriptors, pathv, streamv);
    if (watcher->is_watching) {
        start_listening_ow(ow);
    }
}

static void janet_watcher_remove(JanetWatcher *watcher, const char *path) {
    Janet pathv = janet_cstringv(path);
    Janet streamv = janet_table_get(watcher->watch_descriptors, pathv);
    if (janet_checktype(streamv, JANET_NIL)) {
        janet_panicf("path %v is not being watched", pathv);
    }
    janet_table_remove(watcher->watch_descriptors, pathv);
    OverlappedWatch *ow = janet_unwrap_pointer(streamv);
    janet_stream_close(ow->stream);
}

static void janet_watcher_listen(JanetWatcher *watcher) {
    if (watcher->is_watching) janet_panic("already watching");
    watcher->is_watching = 1;
    for (int32_t i = 0; i < watcher->watch_descriptors->capacity; i++) {
        const JanetKV *kv = watcher->watch_descriptors->data + i;
        if (!janet_checktype(kv->value, JANET_POINTER)) continue;
        OverlappedWatch *ow = janet_unwrap_pointer(kv->value);
        start_listening_ow(ow);
    }
    janet_gcroot(janet_wrap_abstract(watcher));
}

static void janet_watcher_unlisten(JanetWatcher *watcher) {
    if (!watcher->is_watching) return;
    watcher->is_watching = 0;
    for (int32_t i = 0; i < watcher->watch_descriptors->capacity; i++) {
        const JanetKV *kv = watcher->watch_descriptors->data + i;
        if (!janet_checktype(kv->value, JANET_POINTER)) continue;
        OverlappedWatch *ow = janet_unwrap_pointer(kv->value);
        janet_stream_close(ow->stream);
    }
    janet_table_clear(watcher->watch_descriptors);
    janet_gcunroot(janet_wrap_abstract(watcher));
}

#elif defined(JANET_APPLE) || defined(JANET_BSD)

/* kqueue implementation */

/* Cribbed from ev.c */
#define EV_SETx(ev, a, b, c, d, e, f) EV_SET((ev), (a), (b), (c), (d), (e), ((__typeof__((ev)->udata))(f)))

/* kqueue's `NOTE_*` values, in the order the subsystem's `kqueue_names` lists
 * them. The two arrays are one table split in half, so an edit to either has to
 * be an edit to both.
 *
 * Different BSDs define different NOTE_* constants for different kinds of
 * events. Use ifdef to determine when they are available (assuming they are
 * defines and not enums). A host that lacks one stores zero here, and
 * `janet_watch_decode_flags` refuses that name — the same answer the original
 * gave by leaving the entry out of the table altogether. */
static const uint32_t watcher_flag_values_kqueue[] = {
    NOTE_ATTRIB | NOTE_DELETE | NOTE_EXTEND | NOTE_RENAME | NOTE_REVOKE | NOTE_WRITE | NOTE_LINK
#ifdef NOTE_CLOSE
    | NOTE_CLOSE
#endif
#ifdef NOTE_CLOSE_WRITE
    | NOTE_CLOSE_WRITE
#endif
#ifdef NOTE_OPEN
    | NOTE_OPEN
#endif
#ifdef NOTE_READ
    | NOTE_READ
#endif
#ifdef NOTE_FUNLOCK
    | NOTE_FUNLOCK
#endif
#ifdef NOTE_TRUNCATE
    | NOTE_TRUNCATE
#endif
    ,
    NOTE_ATTRIB,
#ifdef NOTE_CLOSE
    NOTE_CLOSE,
#else
    0,
#endif
#ifdef NOTE_CLOSE_WRITE
    NOTE_CLOSE_WRITE,
#else
    0,
#endif
    NOTE_DELETE,
    NOTE_EXTEND,
#ifdef NOTE_FUNLOCK
    NOTE_FUNLOCK,
#else
    0,
#endif
    NOTE_LINK,
#ifdef NOTE_OPEN
    NOTE_OPEN,
#else
    0,
#endif
#ifdef NOTE_READ
    NOTE_READ,
#else
    0,
#endif
    NOTE_RENAME,
    NOTE_REVOKE,
#ifdef NOTE_TRUNCATE
    NOTE_TRUNCATE,
#else
    0,
#endif
    NOTE_WRITE,
};

typedef char janet_watch_kqueue_table_is_whole[
             (sizeof(watcher_flag_values_kqueue) / sizeof(uint32_t) == 14) ? 1 : -1];

static uint32_t decode_watch_flags(const Janet *options, int32_t n) {
    return janet_watch_decode_flags(options, n, JANET_WATCH_PLATFORM_KQUEUE,
                                    watcher_flag_values_kqueue, "bsd");
}

static void janet_watcher_init(JanetWatcher *watcher, JanetChannel *channel, uint32_t default_flags) {
    int kq = kqueue();
    watcher->watch_descriptors = janet_table(0);
    watcher->channel = channel;
    watcher->default_flags = default_flags;
    watcher->is_watching = 0;
    watcher->stream = janet_stream(kq, JANET_STREAM_READABLE, NULL);
    janet_stream_level_triggered(watcher->stream);
}

static void janet_watcher_add(JanetWatcher *watcher, const char *path, uint32_t flags) {
    if (watcher->stream == NULL) janet_panic("watcher closed");
    int kq = watcher->stream->handle;
    struct kevent kev = {0};
    /* Get file descriptor for path */
    int file_fd;
    do {
        file_fd = open(path, O_RDONLY);
    } while (file_fd == -1 && errno == EINTR);
    if (file_fd == -1) {
        janet_panicf("failed to open: %v", janet_ev_lasterr());
    }
    /* Watch for EVFILT_VNODE on the file descriptor */
    EV_SETx(&kev, file_fd, EVFILT_VNODE, EV_ADD | EV_ENABLE | EV_CLEAR, flags, 0, NULL);
    int status;
    do {
        status = kevent(kq, &kev, 1, NULL, 0, NULL);
    } while (status == -1 && errno == EINTR);
    if (status == -1) {
        close(file_fd);
        janet_panicf("failed to listen: %v", janet_ev_lasterr());
    }
    /* Bookkeeping */
    Janet name = janet_cstringv(path);
    Janet wd = janet_wrap_integer(file_fd);
    janet_table_put(watcher->watch_descriptors, name, wd);
    janet_table_put(watcher->watch_descriptors, wd, name);
}

static void janet_watcher_remove(JanetWatcher *watcher, const char *path) {
    if (watcher->stream == NULL) janet_panic("watcher closed");
    Janet pathv = janet_cstringv(path);
    Janet check = janet_table_get(watcher->watch_descriptors, pathv);
    if (!janet_checktype(check, JANET_NUMBER)) {
        janet_panic("bad watch descriptor");
    }
    /* Closing the file descriptor will also remove it from the kqueue */
    int wd = janet_unwrap_integer(check);
    int result;
    do {
        result = close(wd);
    } while (result != -1 && errno == EINTR);
    if (result == -1) {
        janet_panicv(janet_ev_lasterr());
    }
    janet_table_put(watcher->watch_descriptors, pathv, janet_wrap_nil());
    janet_table_put(watcher->watch_descriptors, janet_wrap_integer(wd), janet_wrap_nil());
}

typedef struct {
    JanetWatcher *watcher;
    uint32_t cookie;
} KqueueWatcherState;

static void watcher_callback_read(JanetFiber *fiber, JanetAsyncEvent event) {
    JanetStream *stream = fiber->ev_stream;
    KqueueWatcherState *state = fiber->ev_state;
    JanetWatcher *watcher = state->watcher;
    switch (event) {
        case JANET_ASYNC_EVENT_MARK:
            janet_mark(janet_wrap_abstract(watcher));
            break;
        case JANET_ASYNC_EVENT_CLOSE:
            janet_schedule(fiber, janet_wrap_nil());
            janet_async_end(fiber);
            break;
        case JANET_ASYNC_EVENT_ERR: {
            janet_schedule(fiber, janet_wrap_nil());
            janet_async_end(fiber);
            break;
        }
        case JANET_ASYNC_EVENT_HUP:
        case JANET_ASYNC_EVENT_INIT:
            break;
        case JANET_ASYNC_EVENT_READ: {
            /* Pump events from the sub kqueue */
            const int num_events = 512; /* Extra will be pumped after another event loop rotation. */
            struct kevent events[num_events];
            int kq = stream->handle;
            int status;
            do {
                status = kevent(kq, NULL, 0, events, num_events, NULL);
            } while (status == -1 && errno == EINTR);
            if (status == -1) {
                janet_schedule(fiber, janet_wrap_nil());
                janet_async_end(fiber);
                break;
            }
            for (int i = 0; i < status; i++) {
                state->cookie += 6700417;
                struct kevent kev = events[i];
                /* TODO - avoid stat call here, maybe just when adding listener? */
                struct stat stat_buf = {0};
                int status;
                do {
                    status = fstat(kev.ident, &stat_buf);
                } while (status == -1 && errno == EINTR);
                if (status == -1) continue;
                int is_dir = S_ISDIR(stat_buf.st_mode);
                Janet ident = janet_wrap_integer(kev.ident);
                Janet path = janet_table_get(watcher->watch_descriptors, ident);
                /* From one rather than zero: index zero is `all`, whose value
                 * is the union of the others and would match everything. A
                 * constant the host does not define is zero here, and `fflags &
                 * 0` is already false, so it is skipped without a guard. */
                int32_t flag_count = janet_filewatch_flag_count(JANET_WATCH_PLATFORM_KQUEUE);
                for (int32_t j = 1; j < flag_count; j++) {
                    uint32_t flagcheck = watcher_flag_values_kqueue[j];
                    if (kev.fflags & flagcheck) {
                        JanetKV *event = janet_struct_begin(6);
                        janet_struct_put(event, janet_ckeywordv("wd"), ident);
                        janet_struct_put(event, janet_ckeywordv("wd-path"), path);
                        janet_struct_put(event, janet_ckeywordv("cookie"), janet_wrap_number((double) state->cookie));
                        janet_struct_put(event, janet_ckeywordv("type"),
                                         janet_ckeywordv(janet_filewatch_flag_name(JANET_WATCH_PLATFORM_KQUEUE, j)));
                        if (is_dir) {
                            /* Pass in directly */
                            janet_struct_put(event, janet_ckeywordv("file-name"), janet_cstringv(""));
                            janet_struct_put(event, janet_ckeywordv("dir-name"), path);
                        } else {
                            /* Split path */
                            JanetString spath = janet_unwrap_string(path);
                            const uint8_t *cursor = spath + janet_string_length(spath);
                            const uint8_t *cursor_end = cursor;
                            while (cursor > spath && cursor[0] != '/') {
                                cursor--;
                            }
                            if (cursor == spath) {
                                /* No path separators */
                                janet_struct_put(event, janet_ckeywordv("dir-name"), janet_cstringv("."));
                                janet_struct_put(event, janet_ckeywordv("file-name"), janet_wrap_string(spath));
                            } else {
                                /* Found path separator */
                                janet_struct_put(event, janet_ckeywordv("dir-name"), janet_wrap_string(janet_string(spath, (cursor - spath))));
                                janet_struct_put(event, janet_ckeywordv("file-name"), janet_wrap_string(janet_string(cursor + 1, (cursor_end - cursor - 1))));
                            }
                        }
                        Janet eventv = janet_wrap_struct(janet_struct_end(event));
                        janet_channel_give(watcher->channel, eventv);
                    }
                }
            }
            break;
        }
        default:
            break;
    }
}

static void janet_watcher_listen(JanetWatcher *watcher) {
    if (watcher->is_watching) janet_panic("already watching");
    watcher->is_watching = 1;
    JanetFunction *thunk = janet_thunk_delay(janet_wrap_nil());
    JanetFiber *fiber = janet_fiber(thunk, 64, 0, NULL);
    KqueueWatcherState *state = janet_malloc(sizeof(KqueueWatcherState));
    state->watcher = watcher;
    janet_async_start_fiber(fiber, watcher->stream, JANET_ASYNC_LISTEN_READ, watcher_callback_read, state);
    janet_gcroot(janet_wrap_abstract(watcher));
}

static void janet_watcher_unlisten(JanetWatcher *watcher) {
    if (!watcher->is_watching) return;
    watcher->is_watching = 0;
    janet_stream_close(watcher->stream);
    janet_gcunroot(janet_wrap_abstract(watcher));
}

#else

/* Default implementation */

static uint32_t decode_watch_flags(const Janet *options, int32_t n) {
    (void) options;
    (void) n;
    return 0;
}

static void janet_watcher_init(JanetWatcher *watcher, JanetChannel *channel, uint32_t default_flags) {
    (void) watcher;
    (void) channel;
    (void) default_flags;
    janet_panic("filewatch not supported on this platform");
}

static void janet_watcher_add(JanetWatcher *watcher, const char *path, uint32_t flags) {
    (void) watcher;
    (void) flags;
    (void) path;
    janet_panic("filewatch not supported on this platform");
}

static void janet_watcher_remove(JanetWatcher *watcher, const char *path) {
    (void) watcher;
    (void) path;
    janet_panic("filewatch not supported on this platform");
}

static void janet_watcher_listen(JanetWatcher *watcher) {
    (void) watcher;
    janet_panic("filewatch not supported on this platform");
}

static void janet_watcher_unlisten(JanetWatcher *watcher) {
    (void) watcher;
    janet_panic("filewatch not supported on this platform");
}

#endif

/* C Functions */

static int janet_filewatch_mark(void *p, size_t s) {
    JanetWatcher *watcher = (JanetWatcher *) p;
    (void) s;
    if (watcher->channel == NULL) return 0; /* Incomplete initialization */
#ifdef JANET_WINDOWS
    for (int32_t i = 0; i < watcher->watch_descriptors->capacity; i++) {
        const JanetKV *kv = watcher->watch_descriptors->data + i;
        if (!janet_checktype(kv->value, JANET_POINTER)) continue;
        OverlappedWatch *ow = janet_unwrap_pointer(kv->value);
        janet_mark(janet_wrap_fiber(ow->fiber));
        janet_mark(janet_wrap_abstract(ow->stream));
        janet_mark(janet_wrap_string(ow->dir_path));
    }
#else
    janet_mark(janet_wrap_abstract(watcher->stream));
#endif
    janet_mark(janet_wrap_abstract(watcher->channel));
    janet_mark(janet_wrap_table(watcher->watch_descriptors));
    return 0;
}

static const JanetAbstractType janet_filewatch_at = {
    "filewatch/watcher",
    NULL,
    janet_filewatch_mark,
    JANET_ATEND_GCMARK
};

JANET_CORE_FN(cfun_filewatch_make,
              "(filewatch/new channel & default-flags)",
              "Create a new filewatcher that will give events to a channel channel. See `filewatch/add` for available flags.\n\n"
              "When an event is triggered by the filewatcher, a struct containing information will be given to channel as with `ev/give`. "
              "The contents of the channel depend on the OS, but will contain some common keys:\n\n"
              "* `:type` -- the type of the event that was raised.\n\n"
              "* `:file-name` -- the base file name of the file that triggered the event.\n\n"
              "* `:dir-name` -- the directory name of the file that triggered the event.\n\n"
              "Events also will contain keys specific to the host OS.\n\n"
              "Windows has no extra properties on events.\n\n"
              "Linux and the BSDs have the following extra properties on events:\n\n"
              "* `:wd` -- the integer key returned by `filewatch/add` for the path that triggered this. This is a file descriptor integer on BSD and macos.\n\n"
              "* `:wd-path` -- the string path for watched directory of file. For files, will be the same as `:file-name`, and for directories, will be the same as `:dir-name`.\n\n"
              "* `:cookie` -- a semi-randomized integer used to associate related events, such as :moved-from and :moved-to events.\n\n"
              "") {
    janet_sandbox_assert(JANET_SANDBOX_FS_READ);
    janet_arity(argc, 1, -1);
    JanetChannel *channel = janet_getchannel(argv, 0);
    JanetWatcher *watcher = janet_abstract(&janet_filewatch_at, sizeof(JanetWatcher));
    uint32_t default_flags = decode_watch_flags(argv + 1, argc - 1);
    janet_watcher_init(watcher, channel, default_flags);
    return janet_wrap_abstract(watcher);
}

JANET_CORE_FN(cfun_filewatch_add,
              "(filewatch/add watcher path flag & more-flags)",
              "Add a path to the watcher. Available flags depend on the current OS, and are as follows:\n\n"
              "Windows/MINGW (flags correspond to `FILE_NOTIFY_CHANGE_*` flags in win32 documentation):\n\n"
              "FLAGS\n\n"
              "* `:all` - trigger an event for all of the below triggers.\n\n"
              "* `:attributes` - `FILE_NOTIFY_CHANGE_ATTRIBUTES`\n\n"
              "* `:creation` - `FILE_NOTIFY_CHANGE_CREATION`\n\n"
              "* `:dir-name` - `FILE_NOTIFY_CHANGE_DIR_NAME`\n\n"
              "* `:last-access` - `FILE_NOTIFY_CHANGE_LAST_ACCESS`\n\n"
              "* `:last-write` - `FILE_NOTIFY_CHANGE_LAST_WRITE`\n\n"
              "* `:security` - `FILE_NOTIFY_CHANGE_SECURITY`\n\n"
              "* `:size` - `FILE_NOTIFY_CHANGE_SIZE`\n\n"
              "* `:recursive` - watch subdirectories recursively\n\n"
              "Linux (flags correspond to `IN_*` flags from <sys/inotify.h>):\n\n"
              "* `:access` - `IN_ACCESS`\n\n"
              "* `:all` - `IN_ALL_EVENTS`\n\n"
              "* `:attrib` - `IN_ATTRIB`\n\n"
              "* `:close-nowrite` - `IN_CLOSE_NOWRITE`\n\n"
              "* `:close-write` - `IN_CLOSE_WRITE`\n\n"
              "* `:create` - `IN_CREATE`\n\n"
              "* `:delete` - `IN_DELETE`\n\n"
              "* `:delete-self` - `IN_DELETE_SELF`\n\n"
              "* `:ignored` - `IN_IGNORED`\n\n"
              "* `:modify` - `IN_MODIFY`\n\n"
              "* `:move-self` - `IN_MOVE_SELF`\n\n"
              "* `:moved-from` - `IN_MOVED_FROM`\n\n"
              "* `:moved-to` - `IN_MOVED_TO`\n\n"
              "* `:open` - `IN_OPEN`\n\n"
              "* `:q-overflow` - `IN_Q_OVERFLOW`\n\n"
              "* `:unmount` - `IN_UNMOUNT`\n\n\n"
              "BSDs and macos (flags correspond to `NOTE_*` flags from <sys/event.h>). Not all flags are available on all systems:\n\n"
              "* `:all` - `All available NOTE_* flags on the current platform`\n\n"
              "* `:attrib` - `NOTE_ATTRIB`\n\n"
              "* `:close-write` - `NOTE_CLOSE_WRITE`\n\n"
              "* `:close` - `NOTE_CLOSE`\n\n"
              "* `:delete` - `NOTE_DELETE`\n\n"
              "* `:extend` - `NOTE_EXTEND`\n\n"
              "* `:funlock` - `NOTE_FUNLOCK`\n\n"
              "* `:link` - `NOTE_LINK`\n\n"
              "* `:open` - `NOTE_OPEN`\n\n"
              "* `:read` - `NOTE_READ`\n\n"
              "* `:rename` - `NOTE_RENAME`\n\n"
              "* `:revoke` - `NOTE_REVOKE`\n\n"
              "* `:truncate` - `NOTE_TRUNCATE`\n\n"
              "* `:write` - `NOTE_WRITE`\n\n\n"
              "EVENT TYPES\n\n"
              "On Windows, events will have the following possible types:\n\n"
              "* `:unknown`\n\n"
              "* `:added`\n\n"
              "* `:removed`\n\n"
              "* `:modified`\n\n"
              "* `:renamed-old`\n\n"
              "* `:renamed-new`\n\n"
              "On Linux and BSDs, events will have a `:type` corresponding to the possible flags, excluding `:all`.\n"
              "") {
    janet_arity(argc, 2, -1);
    JanetWatcher *watcher = janet_getabstract(argv, 0, &janet_filewatch_at);
    const char *path = janet_getcstring(argv, 1);
    uint32_t flags = watcher->default_flags | decode_watch_flags(argv + 2, argc - 2);
    janet_watcher_add(watcher, path, flags);
    return argv[0];
}

JANET_CORE_FN(cfun_filewatch_remove,
              "(filewatch/remove watcher path)",
              "Remove a path from the watcher.") {
    janet_fixarity(argc, 2);
    JanetWatcher *watcher = janet_getabstract(argv, 0, &janet_filewatch_at);
    /* TODO - pass string in directly to avoid extra allocation */
    const char *path = janet_getcstring(argv, 1);
    janet_watcher_remove(watcher, path);
    return argv[0];
}

JANET_CORE_FN(cfun_filewatch_listen,
              "(filewatch/listen watcher)",
              "Listen for changes in the watcher.") {
    janet_fixarity(argc, 1);
    JanetWatcher *watcher = janet_getabstract(argv, 0, &janet_filewatch_at);
    janet_watcher_listen(watcher);
    return janet_wrap_nil();
}

JANET_CORE_FN(cfun_filewatch_unlisten,
              "(filewatch/unlisten watcher)",
              "Stop listening for changes on a given watcher.") {
    janet_fixarity(argc, 1);
    JanetWatcher *watcher = janet_getabstract(argv, 0, &janet_filewatch_at);
    janet_watcher_unlisten(watcher);
    return janet_wrap_nil();
}

/* Module entry point */
void janet_lib_filewatch(JanetTable *env) {
    JanetRegExt cfuns[] = {
        JANET_CORE_REG("filewatch/new", cfun_filewatch_make),
        JANET_CORE_REG("filewatch/add", cfun_filewatch_add),
        JANET_CORE_REG("filewatch/remove", cfun_filewatch_remove),
        JANET_CORE_REG("filewatch/listen", cfun_filewatch_listen),
        JANET_CORE_REG("filewatch/unlisten", cfun_filewatch_unlisten),
        JANET_REG_END
    };
    janet_core_cfuns_ext(env, NULL, cfuns);
}

#endif
#endif
