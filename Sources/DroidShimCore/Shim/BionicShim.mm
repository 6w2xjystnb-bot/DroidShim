//
//  BionicShim.cpp
//  DroidShimCore
//
//  Bionic libc symbol re-implementation on top of Darwin/POSIX.
//  All exported symbols use default visibility so the converted Mach-O
//  can bind against them as if they lived in libbionic_shim.dylib.
//

#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <cstdarg>
#include <cstdint>
#include <cerrno>
#include <cmath>

#include <fcntl.h>
#include <unistd.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <pthread.h>
#include <dlfcn.h>
#include <errno.h>

#if defined(__APPLE__)
#include <sys/event.h>
#include <sys/shm.h>
#include <mach/mach.h>
#include <malloc/malloc.h>
#endif

#import <Foundation/Foundation.h>

#define SHIM_EXPORT __attribute__((visibility("default")))

#ifndef O_LARGEFILE
#define O_LARGEFILE 0
#endif

#if defined(__APPLE__) && !defined(__off64_t_defined)
using off64_t = off_t;
#endif

extern "C" {

SHIM_EXPORT void droidshim_initialize_shim(void) {
    // No-op for Phase 1; state is initialized lazily.
}

// MARK: - Memory

SHIM_EXPORT void* malloc(size_t size) {
    return ::malloc(size);
}

SHIM_EXPORT void free(void* ptr) {
    ::free(ptr);
}

SHIM_EXPORT void* calloc(size_t nmemb, size_t size) {
    return ::calloc(nmemb, size);
}

SHIM_EXPORT void* realloc(void* ptr, size_t size) {
    return ::realloc(ptr, size);
}

SHIM_EXPORT int posix_memalign(void** memptr, size_t alignment, size_t size) {
    return ::posix_memalign(memptr, alignment, size);
}

SHIM_EXPORT void* memalign(size_t alignment, size_t size) {
    void* ptr = nullptr;
    if (::posix_memalign(&ptr, alignment, size) != 0) return nullptr;
    return ptr;
}

SHIM_EXPORT void* pvalloc(size_t size) {
    long pagesize = sysconf(_SC_PAGESIZE);
    size_t aligned = (size + pagesize - 1) & ~(pagesize - 1);
    return ::malloc(aligned);
}

SHIM_EXPORT int mallopt(int param, int value) {
    (void)param; (void)value;
    return 0; // stub
}

// MARK: - String / byte operations

SHIM_EXPORT size_t strlen(const char* s) { return ::strlen(s); }
SHIM_EXPORT char* strcpy(char* dst, const char* src) { return ::strcpy(dst, src); }
SHIM_EXPORT char* strncpy(char* dst, const char* src, size_t n) { return ::strncpy(dst, src, n); }
SHIM_EXPORT int strcmp(const char* a, const char* b) { return ::strcmp(a, b); }
SHIM_EXPORT int strncmp(const char* a, const char* b, size_t n) { return ::strncmp(a, b, n); }
SHIM_EXPORT char* strcat(char* dst, const char* src) { return ::strcat(dst, src); }
SHIM_EXPORT char* strchr(const char* s, int c) { return ::strchr(s, c); }
SHIM_EXPORT char* strrchr(const char* s, int c) { return ::strrchr(s, c); }
SHIM_EXPORT char* strdup(const char* s) { return ::strdup(s); }
SHIM_EXPORT char* strndup(const char* s, size_t n) { return ::strndup(s, n); }
SHIM_EXPORT void* memset(void* s, int c, size_t n) { return ::memset(s, c, n); }
SHIM_EXPORT void* memcpy(void* dst, const void* src, size_t n) { return ::memcpy(dst, src, n); }
SHIM_EXPORT void* memmove(void* dst, const void* src, size_t n) { return ::memmove(dst, src, n); }
SHIM_EXPORT void* memchr(const void* s, int c, size_t n) { return ::memchr(s, c, n); }
SHIM_EXPORT int memcmp(const void* a, const void* b, size_t n) { return ::memcmp(a, b, n); }

// MARK: - Stdio

SHIM_EXPORT FILE* fopen(const char* path, const char* mode) { return ::fopen(path, mode); }
SHIM_EXPORT FILE* fopen64(const char* path, const char* mode) { return ::fopen(path, mode); }
SHIM_EXPORT int fclose(FILE* fp) { return ::fclose(fp); }
SHIM_EXPORT size_t fread(void* ptr, size_t size, size_t n, FILE* fp) { return ::fread(ptr, size, n, fp); }
SHIM_EXPORT size_t fwrite(const void* ptr, size_t size, size_t n, FILE* fp) { return ::fwrite(ptr, size, n, fp); }
SHIM_EXPORT int fseek(FILE* fp, long off, int whence) { return ::fseek(fp, off, whence); }
SHIM_EXPORT int fseeko(FILE* fp, off_t off, int whence) { return ::fseeko(fp, off, whence); }
SHIM_EXPORT long ftell(FILE* fp) { return ::ftell(fp); }
SHIM_EXPORT off_t ftello(FILE* fp) { return ::ftello(fp); }
SHIM_EXPORT int fflush(FILE* fp) { return ::fflush(fp); }
SHIM_EXPORT int fgetc(FILE* fp) { return ::fgetc(fp); }
SHIM_EXPORT int fputc(int c, FILE* fp) { return ::fputc(c, fp); }
SHIM_EXPORT int fputs(const char* s, FILE* fp) { return ::fputs(s, fp); }
SHIM_EXPORT int ungetc(int c, FILE* fp) { return ::ungetc(c, fp); }
SHIM_EXPORT int feof(FILE* fp) { return ::feof(fp); }
SHIM_EXPORT int ferror(FILE* fp) { return ::ferror(fp); }
SHIM_EXPORT void clearerr(FILE* fp) { ::clearerr(fp); }

SHIM_EXPORT int fprintf(FILE* fp, const char* fmt, ...) {
    va_list ap;
    va_start(ap, fmt);
    int r = ::vfprintf(fp, fmt, ap);
    va_end(ap);
    return r;
}

SHIM_EXPORT int printf(const char* fmt, ...) {
    va_list ap;
    va_start(ap, fmt);
    int r = ::vprintf(fmt, ap);
    va_end(ap);
    return r;
}

SHIM_EXPORT int sprintf(char* dst, const char* fmt, ...) {
    va_list ap;
    va_start(ap, fmt);
    int r = ::vsprintf(dst, fmt, ap);
    va_end(ap);
    return r;
}

SHIM_EXPORT int snprintf(char* dst, size_t n, const char* fmt, ...) {
    va_list ap;
    va_start(ap, fmt);
    int r = ::vsnprintf(dst, n, fmt, ap);
    va_end(ap);
    return r;
}

SHIM_EXPORT int vsnprintf(char* dst, size_t n, const char* fmt, va_list ap) {
    return ::vsnprintf(dst, n, fmt, ap);
}

// Android's __sF is the stdin/stdout/stderr table; return Darwin's equivalents.
SHIM_EXPORT FILE* __sF(int idx) {
    if (idx == 0) return stdin;
    if (idx == 1) return stdout;
    if (idx == 2) return stderr;
    return nullptr;
}

// MARK: - File descriptors

SHIM_EXPORT int open(const char* path, int flags, ...) {
    mode_t mode = 0;
    if (flags & O_CREAT) {
        va_list ap;
        va_start(ap, flags);
        mode = va_arg(ap, int);
        va_end(ap);
    }
    return ::open(path, flags, mode);
}

SHIM_EXPORT int open64(const char* path, int flags, ...) {
    mode_t mode = 0;
    if (flags & O_CREAT) {
        va_list ap;
        va_start(ap, flags);
        mode = va_arg(ap, int);
        va_end(ap);
    }
    int f = flags & ~O_LARGEFILE;
    return ::open(path, f, mode);
}

SHIM_EXPORT int close(int fd) { return ::close(fd); }
SHIM_EXPORT ssize_t read(int fd, void* buf, size_t n) { return ::read(fd, buf, n); }
SHIM_EXPORT ssize_t write(int fd, const void* buf, size_t n) { return ::write(fd, buf, n); }
SHIM_EXPORT off_t lseek(int fd, off_t off, int whence) { return ::lseek(fd, off, whence); }
SHIM_EXPORT off64_t lseek64(int fd, off64_t off, int whence) { return ::lseek(fd, off, whence); }
SHIM_EXPORT ssize_t pread(int fd, void* buf, size_t n, off_t off) { return ::pread(fd, buf, n, off); }
SHIM_EXPORT ssize_t pwrite(int fd, const void* buf, size_t n, off_t off) { return ::pwrite(fd, buf, n, off); }
SHIM_EXPORT ssize_t pread64(int fd, void* buf, size_t n, off64_t off) { return ::pread(fd, buf, n, off); }
SHIM_EXPORT ssize_t pwrite64(int fd, const void* buf, size_t n, off64_t off) { return ::pwrite(fd, buf, n, off); }
SHIM_EXPORT int dup(int fd) { return ::dup(fd); }
SHIM_EXPORT int dup2(int fd, int fd2) { return ::dup2(fd, fd2); }
SHIM_EXPORT int fcntl(int fd, int cmd, ...) {
    va_list ap;
    va_start(ap, cmd);
    int r = ::fcntl(fd, cmd, va_arg(ap, void*));
    va_end(ap);
    return r;
}
SHIM_EXPORT int fsync(int fd) { return ::fsync(fd); }
SHIM_EXPORT int fdatasync(int fd) { return ::fcntl(fd, F_FULLFSYNC); }
SHIM_EXPORT int access(const char* path, int mode) { return ::access(path, mode); }
SHIM_EXPORT int chmod(const char* path, mode_t mode) { return ::chmod(path, mode); }
SHIM_EXPORT int unlink(const char* path) { return ::unlink(path); }
SHIM_EXPORT int mkdir(const char* path, mode_t mode) { return ::mkdir(path, mode); }
SHIM_EXPORT int rmdir(const char* path) { return ::rmdir(path); }
SHIM_EXPORT int rename(const char* oldpath, const char* newpath) { return ::rename(oldpath, newpath); }
SHIM_EXPORT int stat(const char* path, struct stat* sb) { return ::stat(path, sb); }
SHIM_EXPORT int fstat(int fd, struct stat* sb) { return ::fstat(fd, sb); }
SHIM_EXPORT int lstat(const char* path, struct stat* sb) { return ::lstat(path, sb); }
SHIM_EXPORT int stat64(const char* path, struct stat* sb) { return ::stat(path, sb); }
SHIM_EXPORT int fstat64(int fd, struct stat* sb) { return ::fstat(fd, sb); }
SHIM_EXPORT int lstat64(const char* path, struct stat* sb) { return ::lstat(path, sb); }
SHIM_EXPORT int ioctl(int fd, unsigned long request, ...) {
    (void)fd; (void)request;
    errno = ENOTTY;
    return -1;
}

// MARK: - mmap

SHIM_EXPORT void* mmap(void* addr, size_t len, int prot, int flags, int fd, off_t off) {
    return ::mmap(addr, len, prot, flags, fd, off);
}

SHIM_EXPORT void* mmap64(void* addr, size_t len, int prot, int flags, int fd, off64_t off) {
    return ::mmap(addr, len, prot, flags, fd, off);
}

SHIM_EXPORT int munmap(void* addr, size_t len) { return ::munmap(addr, len); }
SHIM_EXPORT int mprotect(void* addr, size_t len, int prot) { return ::mprotect(addr, len, prot); }
SHIM_EXPORT int msync(void* addr, size_t len, int flags) { return ::msync(addr, len, flags); }
SHIM_EXPORT int madvise(void* addr, size_t len, int advice) {
    (void)addr; (void)len; (void)advice;
    return 0; // stub
}

// MARK: - pthread

SHIM_EXPORT int pthread_create(pthread_t* thread, const pthread_attr_t* attr,
                               void* (*start)(void*), void* arg) {
    return ::pthread_create(thread, attr, start, arg);
}

SHIM_EXPORT void pthread_exit(void* value) { ::pthread_exit(value); }
SHIM_EXPORT int pthread_join(pthread_t thread, void** value) { return ::pthread_join(thread, value); }
SHIM_EXPORT int pthread_detach(pthread_t thread) { return ::pthread_detach(thread); }
SHIM_EXPORT pthread_t pthread_self(void) { return ::pthread_self(); }
SHIM_EXPORT int pthread_equal(pthread_t a, pthread_t b) { return ::pthread_equal(a, b); }

SHIM_EXPORT int pthread_mutex_init(pthread_mutex_t* m, const pthread_mutexattr_t* a) { return ::pthread_mutex_init(m, a); }
SHIM_EXPORT int pthread_mutex_lock(pthread_mutex_t* m) { return ::pthread_mutex_lock(m); }
SHIM_EXPORT int pthread_mutex_trylock(pthread_mutex_t* m) { return ::pthread_mutex_trylock(m); }
SHIM_EXPORT int pthread_mutex_unlock(pthread_mutex_t* m) { return ::pthread_mutex_unlock(m); }
SHIM_EXPORT int pthread_mutex_destroy(pthread_mutex_t* m) { return ::pthread_mutex_destroy(m); }

SHIM_EXPORT int pthread_cond_init(pthread_cond_t* c, const pthread_condattr_t* a) { return ::pthread_cond_init(c, a); }
SHIM_EXPORT int pthread_cond_wait(pthread_cond_t* c, pthread_mutex_t* m) { return ::pthread_cond_wait(c, m); }
SHIM_EXPORT int pthread_cond_timedwait(pthread_cond_t* c, pthread_mutex_t* m, const struct timespec* t) {
    return ::pthread_cond_timedwait(c, m, t);
}
SHIM_EXPORT int pthread_cond_signal(pthread_cond_t* c) { return ::pthread_cond_signal(c); }
SHIM_EXPORT int pthread_cond_broadcast(pthread_cond_t* c) { return ::pthread_cond_broadcast(c); }
SHIM_EXPORT int pthread_cond_destroy(pthread_cond_t* c) { return ::pthread_cond_destroy(c); }

SHIM_EXPORT int pthread_key_create(pthread_key_t* key, void (*destructor)(void*)) {
    return ::pthread_key_create(key, destructor);
}
SHIM_EXPORT int pthread_key_delete(pthread_key_t key) { return ::pthread_key_delete(key); }
SHIM_EXPORT void* pthread_getspecific(pthread_key_t key) { return ::pthread_getspecific(key); }
SHIM_EXPORT int pthread_setspecific(pthread_key_t key, const void* value) { return ::pthread_setspecific(key, value); }

SHIM_EXPORT int pthread_attr_init(pthread_attr_t* attr) { return ::pthread_attr_init(attr); }
SHIM_EXPORT int pthread_attr_destroy(pthread_attr_t* attr) { return ::pthread_attr_destroy(attr); }
SHIM_EXPORT int pthread_attr_setstacksize(pthread_attr_t* attr, size_t size) {
    return ::pthread_attr_setstacksize(attr, size);
}
SHIM_EXPORT int pthread_attr_getstacksize(const pthread_attr_t* attr, size_t* size) {
    return ::pthread_attr_getstacksize(attr, size);
}
SHIM_EXPORT int pthread_attr_setdetachstate(pthread_attr_t* attr, int state) {
    return ::pthread_attr_setdetachstate(attr, state);
}

// MARK: - epoll -> kqueue shim

struct epoll_event {
    uint32_t events;
    union {
        void* ptr;
        int fd;
        uint32_t u32;
        uint64_t u64;
    } data;
};

#define EPOLLIN  0x001
#define EPOLLOUT 0x004
#define EPOLLERR 0x008
#define EPOLLHUP 0x010
#define EPOLL_CTL_ADD 1
#define EPOLL_CTL_DEL 2
#define EPOLL_CTL_MOD 3

SHIM_EXPORT int epoll_create1(int flags) {
    (void)flags;
    return ::kqueue();
}

SHIM_EXPORT int epoll_ctl(int epfd, int op, int fd, struct epoll_event* event) {
    struct kevent changes[2];
    int nchanges = 0;

    auto add = [&](int filter, int flags) {
        EV_SET(&changes[nchanges], fd, filter, flags, 0, 0, reinterpret_cast<void*>(static_cast<uintptr_t>(event ? event->data.u32 : 0)));
        nchanges++;
    };

    if (op == EPOLL_CTL_ADD || op == EPOLL_CTL_MOD) {
        if (!event) { errno = EINVAL; return -1; }
        int kflags = EV_ADD;
        if (op == EPOLL_CTL_MOD) kflags |= EV_DELETE; // naive: delete then re-add
        if (event->events & EPOLLIN) add(EVFILT_READ, kflags | EV_ENABLE);
        if (event->events & EPOLLOUT) add(EVFILT_WRITE, kflags | EV_ENABLE);
    } else if (op == EPOLL_CTL_DEL) {
        add(EVFILT_READ, EV_DELETE);
        add(EVFILT_WRITE, EV_DELETE);
    } else {
        errno = EINVAL;
        return -1;
    }

    return ::kevent(epfd, changes, nchanges, nullptr, 0, nullptr);
}

SHIM_EXPORT int epoll_wait(int epfd, struct epoll_event* events, int maxevents, int timeout) {
    if (maxevents <= 0) { errno = EINVAL; return -1; }
    struct kevent* kev = new struct kevent[maxevents];
    struct timespec ts;
    struct timespec* tsp = nullptr;
    if (timeout >= 0) {
        ts.tv_sec = timeout / 1000;
        ts.tv_nsec = (timeout % 1000) * 1000000;
        tsp = &ts;
    }
    int n = ::kevent(epfd, nullptr, 0, kev, maxevents, tsp);
    if (n > 0 && events) {
        for (int i = 0; i < n; ++i) {
            events[i].events = 0;
            if (kev[i].filter == EVFILT_READ) events[i].events |= EPOLLIN;
            if (kev[i].filter == EVFILT_WRITE) events[i].events |= EPOLLOUT;
            if (kev[i].flags & EV_ERROR) events[i].events |= EPOLLERR;
            if (kev[i].flags & EV_EOF) events[i].events |= EPOLLHUP;
            events[i].data.u32 = static_cast<uint32_t>(reinterpret_cast<uintptr_t>(kev[i].udata));
        }
    }
    delete[] kev;
    return n;
}

// MARK: - ashmem -> shm_open

SHIM_EXPORT int ashmem_create_region(const char* name, size_t size) {
    char path[256];
    ::snprintf(path, sizeof(path), "/%s", name ? name : "droidshim_ashmem");
    int fd = ::shm_open(path, O_RDWR | O_CREAT, 0666);
    if (fd >= 0) {
        ::ftruncate(fd, static_cast<off_t>(size));
    }
    return fd;
}

SHIM_EXPORT int ashmem_set_prot_mask(int fd, int prot) {
    (void)fd; (void)prot;
    return 0;
}

SHIM_EXPORT int ashmem_pin(int fd) { (void)fd; return 0; }
SHIM_EXPORT int ashmem_unpin(int fd) { (void)fd; return 0; }

// MARK: - dlfcn

SHIM_EXPORT void* dlopen(const char* path, int flags) { return ::dlopen(path, flags); }
SHIM_EXPORT int dlclose(void* handle) { return ::dlclose(handle); }
SHIM_EXPORT void* dlsym(void* handle, const char* symbol) { return ::dlsym(handle, symbol); }
SHIM_EXPORT const char* dlerror(void) { return ::dlerror(); }
SHIM_EXPORT int dladdr(const void* addr, Dl_info* info) { return ::dladdr(addr, info); }

// MARK: - logging

SHIM_EXPORT int __android_log_print(int prio, const char* tag, const char* fmt, ...) {
    (void)prio;
    char buf[1024];
    va_list ap;
    va_start(ap, fmt);
    ::vsnprintf(buf, sizeof(buf), fmt, ap);
    va_end(ap);
    NSLog(@"%s: %s", tag ?: "DroidShim", buf);
    return 0;
}

SHIM_EXPORT int __android_log_write(int prio, const char* tag, const char* msg) {
    (void)prio;
    NSLog(@"%s: %s", tag ?: "DroidShim", msg ?: "");
    return 0;
}

// MARK: - errno / stack / abort

SHIM_EXPORT int* __errno(void) { return __error(); }
SHIM_EXPORT int* __android_get_tls(void) { return __error(); }

SHIM_EXPORT void __stack_chk_fail(void) {
    __builtin_trap();
}

SHIM_EXPORT void abort(void) {
    // Directly trap to avoid recursion through the exported abort symbol.
    __builtin_trap();
}

} // extern "C"
