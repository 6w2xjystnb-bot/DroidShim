//
//  FileShim.cpp
//  DroidShimCore
//
//  File-descriptor tracking and Android-specific fd helpers.
//

#include <cstdint>
#include <cstring>
#include <string>
#include <unordered_map>
#include <mutex>
#include <fcntl.h>
#include <unistd.h>

#define SHIM_EXPORT __attribute__((visibility("default")))

namespace {

std::mutex& fd_table_mutex() {
    static std::mutex m;
    return m;
}

std::unordered_map<int, std::string>& fd_table() {
    static std::unordered_map<int, std::string> table;
    return table;
}

} // anonymous namespace

extern "C" {

// Record a mapping from fd to path for debugging / diagnostics.
SHIM_EXPORT void droidshim_fd_register(int fd, const char* path) {
    if (fd < 0 || !path) return;
    std::lock_guard<std::mutex> lock(fd_table_mutex());
    fd_table()[fd] = path;
}

SHIM_EXPORT void droidshim_fd_unregister(int fd) {
    std::lock_guard<std::mutex> lock(fd_table_mutex());
    fd_table().erase(fd);
}

SHIM_EXPORT const char* droidshim_fd_path(int fd) {
    std::lock_guard<std::mutex> lock(fd_table_mutex());
    auto it = fd_table().find(fd);
    if (it == fd_table().end()) return nullptr;
    return it->second.c_str();
}

// Android's lseek64 is identical to Darwin off_t lseek on 64-bit platforms.
SHIM_EXPORT off64_t droidshim_lseek64(int fd, off64_t offset, int whence) {
    return ::lseek(fd, static_cast<off_t>(offset), whence);
}

// Normalize Android open flags to Darwin flags.
SHIM_EXPORT int droidshim_normalize_open_flags(int flags) {
    // O_LARGEFILE is a no-op on Darwin.
    return flags & ~O_LARGEFILE;
}

} // extern "C"
