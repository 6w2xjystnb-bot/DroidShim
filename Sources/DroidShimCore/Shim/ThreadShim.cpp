//
//  ThreadShim.cpp
//  DroidShimCore
//
//  Bionic TLS and pthread-internal helpers.  These symbols are exported so
//  Android native code that directly references Bionic internals can resolve
//  them through libbionic_shim.
//

#include <pthread.h>
#include <cstdint>
#include <cstdlib>
#include <cstring>
#include <mach/mach.h>

#define SHIM_EXPORT __attribute__((visibility("default")))

extern "C" {

// Bionic's TLS key.  We initialize it lazily on first use.
static pthread_once_t s_tls_once = PTHREAD_ONCE_INIT;
static pthread_key_t s_tls_key;

// Minimal Bionic pthread_internal_t layout.  Only the fields Android code
// is most likely to touch (e.g., tid) are mirrored here.
struct bionic_pthread_internal_t {
    uint32_t tid;
    uint32_t cached_pid_;
    void*    tls;
    char     padding[240];
};

static void init_tls_key() {
    pthread_key_create(&s_tls_key, nullptr);
}

static bionic_pthread_internal_t* ensure_bionic_internal() {
    pthread_once(&s_tls_once, init_tls_key);
    bionic_pthread_internal_t* internal = static_cast<bionic_pthread_internal_t*>(pthread_getspecific(s_tls_key));
    if (!internal) {
        internal = static_cast<bionic_pthread_internal_t*>(calloc(1, sizeof(bionic_pthread_internal_t)));
        internal->tid = static_cast<uint32_t>(pthread_mach_thread_np(pthread_self()) & 0xffffffffu);
        pthread_setspecific(s_tls_key, internal);
    }
    return internal;
}

// Bionic's __get_tls returns a pointer to the TLS area.
SHIM_EXPORT void* __get_tls(void) {
    return ensure_bionic_internal();
}

// Some Android code reads the pthread_internal_t via __pthread_internal_find.
SHIM_EXPORT void* __pthread_internal_find(pthread_t thread) {
    (void)thread;
    return ensure_bionic_internal();
}

// Thread-local cache of the current thread id.
SHIM_EXPORT __attribute__((weak)) int gettid(void) {
    return static_cast<int>(ensure_bionic_internal()->tid);
}

// set_tid_address is used by bionic clone emulation; iOS has no clone.
SHIM_EXPORT int* set_tid_address(int* tidptr) {
    static int s_dummy = 0;
    if (tidptr) *tidptr = gettid();
    return &s_dummy;
}

} // extern "C"
