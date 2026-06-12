//
//  MachOWriter.hpp
//  DroidShimCore
//
//  Thin Mach-O 64 generator. Converts a parsed ELF64 into a Mach-O dylib
//  linked against libbionic_shim.dylib.
//

#pragma once

#include "ELFReader.hpp"
#include <cstdint>
#include <string>
#include <vector>
#include <unordered_map>

namespace droidshim {

// Mach-O constants.
constexpr uint32_t MH_MAGIC_64     = 0xfeedfacf;
constexpr uint32_t DS_CPU_TYPE_ARM64  = 0x0100000c;
constexpr uint32_t DS_CPU_SUBTYPE_ARM64_ALL = 0x00000000;
constexpr uint32_t MH_DYLIB        = 6;

constexpr uint32_t LC_SEGMENT_64   = 0x19;
constexpr uint32_t LC_SYMTAB       = 0x02;
constexpr uint32_t LC_DYSYMTAB     = 0x0b;
constexpr uint32_t LC_LOAD_DYLIB   = 0x0c;
constexpr uint32_t LC_ID_DYLIB     = 0x0d;
constexpr uint32_t LC_DYLD_INFO_ONLY = 0x22;
constexpr uint32_t LC_BUILD_VERSION  = 0x32;
constexpr uint32_t LC_UUID           = 0x1b;

constexpr uint32_t PLATFORM_IOS = 2;

constexpr uint32_t N_STAB = 0xe0;
constexpr uint32_t N_PEXT = 0x10;
constexpr uint32_t N_TYPE = 0x0e;
constexpr uint32_t N_EXT  = 0x01;
constexpr uint8_t  N_SECT = 0x0e;
constexpr uint8_t  N_UNDF = 0x00;

// Build version command minos/sdk packed as (major << 16 | minor << 8 | patch).
inline uint32_t packedVersion(uint32_t major, uint32_t minor, uint32_t patch) {
    return (major << 16) | (minor << 8) | patch;
}

/// Rebase/bind opcode helpers for dyld_info_command.
namespace rebinding {
    constexpr uint8_t REBASE_TYPE_POINTER         = 1;
    constexpr uint8_t REBASE_TYPE_TEXT_ABSOLUTE32 = 2;
    constexpr uint8_t REBASE_TYPE_TEXT_PCREL32    = 3;

    constexpr uint8_t REBASE_OPCODE_DONE                               = 0x00;
    constexpr uint8_t REBASE_OPCODE_SET_TYPE_IMM                       = 0x10;
    constexpr uint8_t REBASE_OPCODE_SET_SEGMENT_AND_OFFSET_ULEB        = 0x20;
    constexpr uint8_t REBASE_OPCODE_ADD_ADDR_ULEB                      = 0x30;
    constexpr uint8_t REBASE_OPCODE_ADD_ADDR_IMM_SCALED                = 0x40;
    constexpr uint8_t REBASE_OPCODE_DO_REBASE_IMM_TIMES                = 0x50;
    constexpr uint8_t REBASE_OPCODE_DO_REBASE_ULEB_TIMES               = 0x60;
    constexpr uint8_t REBASE_OPCODE_DO_REBASE_ADD_ADDR_ULEB            = 0x70;
    constexpr uint8_t REBASE_OPCODE_DO_REBASE_ULEB_TIMES_SKIPPING_ULEB = 0x80;

    constexpr uint8_t BIND_TYPE_POINTER  = 1;
    constexpr uint8_t BIND_TYPE_TEXT_ABSOLUTE32 = 2;

    constexpr uint8_t BIND_OPCODE_DONE                                 = 0x00;
    constexpr uint8_t BIND_OPCODE_SET_DYLIB_ORDINAL_IMM                = 0x10;
    constexpr uint8_t BIND_OPCODE_SET_DYLIB_ORDINAL_ULEB               = 0x20;
    constexpr uint8_t BIND_OPCODE_SET_DYLIB_SPECIAL_IMM                = 0x30;
    constexpr uint8_t BIND_OPCODE_SET_SYMBOL_TRAILING_FLAGS_IMM        = 0x40;
    constexpr uint8_t BIND_OPCODE_SET_TYPE_IMM                         = 0x50;
    constexpr uint8_t BIND_OPCODE_SET_ADDEND_SLEB                      = 0x60;
    constexpr uint8_t BIND_OPCODE_SET_SEGMENT_AND_OFFSET_ULEB          = 0x70;
    constexpr uint8_t BIND_OPCODE_ADD_ADDR_ULEB                        = 0x80;
    constexpr uint8_t BIND_OPCODE_DO_BIND                              = 0x90;
    constexpr uint8_t BIND_OPCODE_DO_BIND_ADD_ADDR_ULEB                = 0xa0;
    constexpr uint8_t BIND_OPCODE_DO_BIND_ADD_ADDR_IMM_SCALED          = 0xb0;
    constexpr uint8_t BIND_OPCODE_DO_BIND_ULEB_TIMES_SKIPPING_ULEB     = 0xc0;
}

/// Minimal Mach-O symbol table entry.
struct MachOSymbol {
    std::string name;
    uint64_t value = 0;      // address
    uint8_t section = 0;     // 1-based section index
    uint16_t desc = 0;
    uint8_t type = 0;        // N_SECT | N_EXT etc.
    bool external = false;
};

struct MachOWriterConfig {
    std::string outputPath;
    std::string installName = "@rpath/libbionic_shim.dylib";
    std::string identifier  = "com.droidshim.generated";
    std::string shimPath    = "@rpath/libbionic_shim.dylib";
    uint32_t minOSMajor = 16, minOSMinor = 0, minOSPatch = 0;
    uint32_t sdkMajor   = 17, sdkMinor   = 0, sdkPatch   = 0;
};

/// Result of a Mach-O generation attempt.
struct MachOWriteResult {
    bool success = false;
    std::string error;
    std::string outputPath;
};

class MachOWriter {
public:
    /// Generate a Mach-O dylib from an already-parsed ELF64.
    /// The caller supplies a list of external symbol names that should be bound
    /// to libbionic_shim (everything else is rebased locally).
    MachOWriteResult generate(const ELFReader& elf,
                              const std::vector<std::string>& bindSymbols,
                              const MachOWriterConfig& config);

    const std::vector<uint8_t>& buffer() const { return buffer_; }

private:
    void appendLoadCommand(const void* data, size_t size);
    void appendSection(const char* segname, const char* sectname,
                       uint64_t vmaddr, uint64_t vmsize,
                       uint64_t fileoff, uint64_t filesize,
                       uint32_t prot, uint32_t maxprot,
                       uint32_t flags = 0);
    void encodeULEB128(uint64_t value, std::vector<uint8_t>& out);
    void encodeSLEB128(int64_t value, std::vector<uint8_t>& out);

    std::vector<uint8_t> buffer_;
    uint64_t linkeditFileOffset_ = 0;
    uint64_t linkeditVmAddr_ = 0;
    uint64_t stringTableStart_ = 0;
    uint64_t symbolTableStart_ = 0;
    uint64_t rebaseInfoStart_ = 0;
    uint64_t bindInfoStart_ = 0;
    uint64_t rebaseInfoSize_ = 0;
    uint64_t bindInfoSize_ = 0;
    std::vector<MachOSymbol> symbols_;
};

} // namespace droidshim
