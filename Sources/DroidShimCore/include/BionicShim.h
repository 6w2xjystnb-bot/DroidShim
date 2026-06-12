//
//  BionicShim.h
//  DroidShimCore
//
//  Public C/ObjC interface to the Bionic→Darwin shim.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// One-time initialization for shim-internal state (TLS keys, fd table, etc.).
void droidshim_initialize_shim(void);

/// Register an fd-to-path mapping for debugging.
void droidshim_fd_register(int fd, const char* path);
void droidshim_fd_unregister(int fd);
const char* _Nullable droidshim_fd_path(int fd);

NS_ASSUME_NONNULL_END
