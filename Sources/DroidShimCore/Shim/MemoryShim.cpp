//
//  MemoryShim.cpp
//  DroidShimCore
//
//  Additional memory-mapping helpers for Android-specific behaviours that
//  Darwin does not provide natively (binder mmap, PROT_EXEC handling, etc.).
//

#include <cerrno>
#include <cstdint>
#include <cstdio>
#include <sys/mman.h>

#define SHIM_EXPORT __attribute__((visibility("default")))

// Android binder driver mmap.  There is no binder on iOS, so this stub
// returns ENOMEM as required by the constraints.
extern "C" SHIM_EXPORT void* binder_mmap(void* addr, size_t len, int prot, int flags, int fd, off_t off) {
    (void)addr; (void)len; (void)prot; (void)flags; (void)fd; (void)off;
    errno = ENOMEM;
    return MAP_FAILED;
}

// Utility used by the Bionic mmap shim to translate Android MAP_ flags
// to Darwin MAP_ flags.  Exported for testing / diagnostics.
extern "C" SHIM_EXPORT int droidshim_translate_mmap_flags(int androidFlags) {
    int flags = 0;
    if (androidFlags & 0x01) flags |= MAP_SHARED;    // MAP_SHARED
    if (androidFlags & 0x02) flags |= MAP_PRIVATE;   // MAP_PRIVATE
    if (androidFlags & 0x20) flags |= MAP_ANONYMOUS; // MAP_ANONYMOUS
    if (androidFlags & 0x10) flags |= MAP_FIXED;     // MAP_FIXED
    return flags;
}

// Wrap mprotect so that PROT_EXEC on a non-jit region fails gracefully
// instead of killing the app with SIGKILL.
extern "C" SHIM_EXPORT int droidshim_mprotect(void* addr, size_t len, int prot) {
    if (prot & PROT_EXEC) {
        // iOS rejects PROT_EXEC on application-allocated memory.
        // Log and downgrade to PROT_READ so the app can continue.
        fprintf(stderr, "[DroidShim] mprotect PROT_EXEC denied at %p, downgrading to PROT_READ\n", addr);
        prot &= ~PROT_EXEC;
        prot |= PROT_READ;
    }
    return ::mprotect(addr, len, prot);
}
