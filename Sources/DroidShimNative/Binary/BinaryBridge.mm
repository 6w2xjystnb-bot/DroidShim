//
//  BinaryBridge.mm
//  DroidShimCore
//
//  Objective-C++ wrapper around the C++ ELF/Mach-O pipeline.
//

#import "BinaryBridge.h"
#include "BinaryBridge.hpp"
#include <string>

@interface DSBinaryBridge () {
    droidshim::ELFReader _reader;
    BOOL _hasParsedELF;
}
@end

@implementation DSBinaryBridge

- (NSInteger)parseELF:(NSData *)data {
    if (!data || data.length == 0) { return -1; }
    const uint8_t* bytes = reinterpret_cast<const uint8_t*>(data.bytes);
    bool ok = _reader.parse(bytes, data.length);
    _hasParsedELF = ok ? YES : NO;
    if (!ok) { return -1; }
    return static_cast<NSInteger>(_reader.externalSymbols().size());
}

- (NSArray<NSString *> *)externalSymbols {
    auto symbols = _reader.externalSymbols();
    NSMutableArray<NSString *>* array = [NSMutableArray arrayWithCapacity:symbols.size()];
    for (const auto& s : symbols) {
        [array addObject:[NSString stringWithUTF8String:s.c_str()]];
    }
    return array;
}

- (BOOL)writeMachOToPath:(NSString *)outputPath
            installName:(NSString *)installName
                  error:(NSString * _Nullable * _Nullable)error {
    if (!_hasParsedELF) {
        if (error) {
            *error = @"No valid ELF has been parsed";
        }
        return NO;
    }

    std::string out = [outputPath UTF8String];
    std::string name = installName ? [installName UTF8String] : "com.droidshim.generated";

    std::vector<std::string> bindSymbols = _reader.externalSymbols();

    droidshim::MachOWriterConfig config;
    config.outputPath = out;
    config.identifier = name;
    config.shimPath = "@rpath/libbionic_shim.dylib";

    droidshim::MachOWriter writer;
    auto result = writer.generate(_reader, bindSymbols, config);

    if (!result.success && error) {
        *error = [NSString stringWithUTF8String:result.error.c_str()];
    }
    return result.success;
}

@end
