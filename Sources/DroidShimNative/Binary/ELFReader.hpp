//
//  ELFReader.hpp
//  DroidShimCore
//
//  Internal C++ ELF64 parser for AArch64 shared objects extracted from APKs.
//

#pragma once

#include <cstdint>
#include <cstddef>
#include <vector>
#include <string>
#include <unordered_map>

// Minimal ELF64 constants used by the parser.
namespace droidshim {

constexpr uint8_t ELFMAG0 = 0x7f;
constexpr uint8_t ELFMAG1 = 'E';
constexpr uint8_t ELFMAG2 = 'L';
constexpr uint8_t ELFMAG3 = 'F';

constexpr uint8_t ELFCLASS64 = 2;
constexpr uint8_t ELFDATA2LSB = 1;
constexpr uint16_t EM_AARCH64 = 183;

constexpr uint16_t ET_DYN = 3;

constexpr uint32_t PT_LOAD    = 1;
constexpr uint32_t PT_DYNAMIC = 2;

constexpr uint32_t SHT_NULL     = 0;
constexpr uint32_t SHT_PROGBITS = 1;
constexpr uint32_t SHT_SYMTAB   = 2;
constexpr uint32_t SHT_STRTAB   = 3;
constexpr uint32_t SHT_RELA     = 4;
constexpr uint32_t SHT_NOBITS   = 8;
constexpr uint32_t SHT_DYNSYM   = 11;

constexpr uint32_t SHN_UNDEF = 0;

constexpr uint32_t STB_GLOBAL = 1;
constexpr uint32_t STB_WEAK   = 2;
constexpr uint32_t STT_OBJECT = 1;
constexpr uint32_t STT_FUNC   = 2;
constexpr uint32_t STT_COMMON = 5;

// Dynamic tag constants.
constexpr uint64_t DT_NULL        = 0;
constexpr uint64_t DT_NEEDED      = 1;
constexpr uint64_t DT_STRTAB      = 5;
constexpr uint64_t DT_SYMTAB      = 6;
constexpr uint64_t DT_RELA        = 7;
constexpr uint64_t DT_RELASZ      = 8;
constexpr uint64_t DT_RELAENT     = 9;
constexpr uint64_t DT_STRSZ       = 10;
constexpr uint64_t DT_JMPREL      = 23;
constexpr uint64_t DT_PLTRELSZ    = 2;
constexpr uint64_t DT_PLTREL      = 20;

// AArch64 relocation types.
constexpr uint32_t R_AARCH64_ABS64      = 257;
constexpr uint32_t R_AARCH64_GLOB_DAT   = 1025;
constexpr uint32_t R_AARCH64_JUMP_SLOT  = 1026;
constexpr uint32_t R_AARCH64_RELATIVE   = 1027;
constexpr uint32_t R_AARCH64_TLS_TPREL64 = 1030;

#pragma pack(push, 1)
struct Elf64_Ehdr {
    uint8_t  e_ident[16];
    uint16_t e_type;
    uint16_t e_machine;
    uint32_t e_version;
    uint64_t e_entry;
    uint64_t e_phoff;
    uint64_t e_shoff;
    uint32_t e_flags;
    uint16_t e_ehsize;
    uint16_t e_phentsize;
    uint16_t e_phnum;
    uint16_t e_shentsize;
    uint16_t e_shnum;
    uint16_t e_shstrndx;
};

struct Elf64_Phdr {
    uint32_t p_type;
    uint32_t p_flags;
    uint64_t p_offset;
    uint64_t p_vaddr;
    uint64_t p_paddr;
    uint64_t p_filesz;
    uint64_t p_memsz;
    uint64_t p_align;
};

struct Elf64_Shdr {
    uint32_t sh_name;
    uint32_t sh_type;
    uint64_t sh_flags;
    uint64_t sh_addr;
    uint64_t sh_offset;
    uint64_t sh_size;
    uint32_t sh_link;
    uint32_t sh_info;
    uint64_t sh_addralign;
    uint64_t sh_entsize;
};

struct Elf64_Sym {
    uint32_t st_name;
    uint8_t  st_info;
    uint8_t  st_other;
    uint16_t st_shndx;
    uint64_t st_value;
    uint64_t st_size;
};

struct Elf64_Rela {
    uint64_t r_offset;
    uint64_t r_info;
    int64_t  r_addend;
};

struct Elf64_Dyn {
    int64_t  d_tag;
    uint64_t d_un;
};
#pragma pack(pop)

inline uint32_t ELF64_R_TYPE(uint64_t info) { return static_cast<uint32_t>(info & 0xffffffffu); }
inline uint32_t ELF64_R_SYM(uint64_t info)  { return static_cast<uint32_t>(info >> 32); }

/// Parsed view of an ELF64 shared object.
class ELFReader {
public:
    ELFReader() = default;

    /// Parse a raw ELF64 file already loaded into memory.
    bool parse(const uint8_t* data, size_t size);

    const Elf64_Ehdr* header() const { return reinterpret_cast<const Elf64_Ehdr*>(data_.data()); }
    const std::vector<uint8_t>& raw() const { return data_; }

    const std::vector<Elf64_Phdr>& programHeaders() const { return phdrs_; }
    const std::vector<Elf64_Shdr>& sectionHeaders() const { return shdrs_; }

    /// All dynamic relocations (RELA).
    const std::vector<Elf64_Rela>& relaDyn() const { return relaDyn_; }
    const std::vector<Elf64_Rela>& relaPlt() const { return relaPlt_; }

    /// Symbol name lookup by string table index.
    const char* stringFromDynstr(uint32_t offset) const;
    const char* stringFromSectionName(uint32_t offset) const;

    /// Resolve a dynamic symbol index to its name and entry.
    const Elf64_Sym* dynSymbol(uint32_t index) const;
    const char* dynSymbolName(uint32_t index) const;

    /// All externally-visible dynamic symbols (undefined + global defined).
    std::vector<std::string> externalSymbols() const;
    std::vector<std::string> neededLibraries() const { return needed_; }

    /// Locate section contents by name.
    const uint8_t* sectionData(const std::string& name, size_t& outSize) const;

private:
    bool readDynamicSegment();

    std::vector<uint8_t> data_;
    std::vector<Elf64_Phdr> phdrs_;
    std::vector<Elf64_Shdr> shdrs_;

    // Dynamic segment derived pointers (offsets into data_).
    uint64_t dynstrOffset_ = 0;
    uint64_t dynstrSize_ = 0;
    uint64_t dynsymOffset_ = 0;
    uint64_t dynsymCount_ = 0;
    uint64_t relaDynOffset_ = 0;
    uint64_t relaDynSize_ = 0;
    uint64_t relaPltOffset_ = 0;
    uint64_t relaPltSize_ = 0;

    std::vector<Elf64_Rela> relaDyn_;
    std::vector<Elf64_Rela> relaPlt_;
    std::vector<std::string> needed_;
    mutable std::unordered_map<std::string, const Elf64_Sym*> symbolMap_;
};

} // namespace droidshim
