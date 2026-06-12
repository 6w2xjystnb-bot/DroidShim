//
//  RelocationMapper.hpp
//  DroidShimCore
//
//  Maps ELF64 AArch64 relocations to Mach-O dyld rebase/bind actions.
//

#pragma once

#include "ELFReader.hpp"
#include <string>
#include <vector>
#include <cstdint>

namespace droidshim {

/// A single fixup action.
struct FixupAction {
    uint64_t address = 0;        // Virtual address in output Mach-O.
    uint64_t addend = 0;
    bool isBind = false;
    std::string symbol;          // Empty for rebase.
    uint32_t relocationType = 0;
};

struct RelocationResult {
    std::vector<FixupAction> rebases;
    std::vector<FixupAction> binds;
    std::vector<std::string> warnings;
    bool success = false;
    std::string error;
};

class RelocationMapper {
public:
    /// Map all relocations from `elf` into a list of Mach-O fixups.
    /// `textBase` / `dataBase` are the Mach-O segment virtual addresses.
    RelocationResult map(const ELFReader& elf,
                         uint64_t textBase,
                         uint64_t dataBase);
};

} // namespace droidshim
