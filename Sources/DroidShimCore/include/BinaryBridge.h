//
//  BinaryBridge.h
//  DroidShimCore
//
//  Objective-C++ wrapper exposing ELF→Mach-O conversion to Swift.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface DSBinaryBridge : NSObject

/// Parse an ELF64 from NSData and return the number of dynamic symbols.
- (NSInteger)parseELF:(NSData *)data;

/// List undefined dynamic symbols that must be bound to libbionic_shim.
- (NSArray<NSString *> *)externalSymbols;

/// Convert the previously-parsed ELF to a Mach-O dylib at `outputPath`.
/// `installName` is used as the LC_ID_DYLIB identifier.
- (BOOL)writeMachOToPath:(NSString *)outputPath
            installName:(NSString *)installName
                  error:(NSString * _Nullable * _Nullable)error;

@end

NS_ASSUME_NONNULL_END
