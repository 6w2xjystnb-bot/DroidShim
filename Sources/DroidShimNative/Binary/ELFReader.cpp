//
//  ELFReader.cpp
//  DroidShimCore
//
//  ELF64 AArch64 parser used before rehosting an Android .so as Mach-O.
//

#include "ELFReader.hpp"
#include <cstring>
#include <algorithm>

namespace droidshim {

bool ELFReader::parse(const uint8_t* data, size_t size) {
    if (!data || size < sizeof(Elf64_Ehdr)) {
        return false;
    }

    data_.assign(data, data + size);
    const Elf64_Ehdr* ehdr = header();

    // Magic / class / data / machine validation.
    if (ehdr->e_ident[0] != ELFMAG0 ||
        ehdr->e_ident[1] != ELFMAG1 ||
        ehdr->e_ident[2] != ELFMAG2 ||
        ehdr->e_ident[3] != ELFMAG3) {
        return false;
    }
    if (ehdr->e_ident[4] != ELFCLASS64) { return false; }
    if (ehdr->e_ident[5] != ELFDATA2LSB) { return false; }
    if (ehdr->e_machine != EM_AARCH64) { return false; }
    if (ehdr->e_type != ET_DYN) { return false; }

    // Program headers.
    if (ehdr->e_phoff && ehdr->e_phnum) {
        size_t phBytes = static_cast<size_t>(ehdr->e_phnum) * sizeof(Elf64_Phdr);
        if (ehdr->e_phoff + phBytes > size) { return false; }
        phdrs_.resize(ehdr->e_phnum);
        std::memcpy(phdrs_.data(), data_.data() + ehdr->e_phoff, phBytes);
    }

    // Section headers.
    if (ehdr->e_shoff && ehdr->e_shnum) {
        size_t shBytes = static_cast<size_t>(ehdr->e_shnum) * sizeof(Elf64_Shdr);
        if (ehdr->e_shoff + shBytes > size) { return false; }
        shdrs_.resize(ehdr->e_shnum);
        std::memcpy(shdrs_.data(), data_.data() + ehdr->e_shoff, shBytes);
    }

    // Prefer section-based dynamic info if available; otherwise use PT_DYNAMIC.
    bool foundDynamicSections = false;
    for (const auto& sh : shdrs_) {
        if (sh.sh_type == SHT_DYNSYM) {
            dynsymOffset_ = sh.sh_offset;
            dynsymCount_ = sh.sh_size / sizeof(Elf64_Sym);
        } else if (sh.sh_type == SHT_STRTAB && dynsymOffset_) {
            // The first STRTAB after DYNSYM is usually .dynstr.
            if (dynstrOffset_ == 0) {
                dynstrOffset_ = sh.sh_offset;
                dynstrSize_ = sh.sh_size;
            }
        } else if (sh.sh_type == SHT_RELA) {
            const char* name = stringFromSectionName(sh.sh_name);
            if (std::strcmp(name, ".rela.dyn") == 0) {
                relaDynOffset_ = sh.sh_offset;
                relaDynSize_ = sh.sh_size;
            } else if (std::strcmp(name, ".rela.plt") == 0) {
                relaPltOffset_ = sh.sh_offset;
                relaPltSize_ = sh.sh_size;
            }
        }
    }

    foundDynamicSections = (dynsymOffset_ && dynstrOffset_);
    if (!foundDynamicSections) {
        if (!readDynamicSegment()) {
            // Minimal test fixtures and stripped shared objects can still be
            // structurally valid even if they have no dynamic symbols.
            dynsymCount_ = 0;
        }
    }

    // Load RELA tables.
    if (relaDynSize_) {
        size_t count = relaDynSize_ / sizeof(Elf64_Rela);
        relaDyn_.resize(count);
        std::memcpy(relaDyn_.data(), data_.data() + relaDynOffset_, relaDynSize_);
    }
    if (relaPltSize_) {
        size_t count = relaPltSize_ / sizeof(Elf64_Rela);
        relaPlt_.resize(count);
        std::memcpy(relaPlt_.data(), data_.data() + relaPltOffset_, relaPltSize_);
    }

    return true;
}

bool ELFReader::readDynamicSegment() {
    for (const auto& ph : phdrs_) {
        if (ph.p_type != PT_DYNAMIC) { continue; }
        if (ph.p_offset + ph.p_filesz > data_.size()) { return false; }

        const Elf64_Dyn* dyn = reinterpret_cast<const Elf64_Dyn*>(data_.data() + ph.p_offset);
        size_t count = ph.p_filesz / sizeof(Elf64_Dyn);

        for (size_t i = 0; i < count; ++i) {
            switch (dyn[i].d_tag) {
                case DT_SYMTAB:
                    dynsymOffset_ = dyn[i].d_un;
                    break;
                case DT_STRTAB:
                    dynstrOffset_ = dyn[i].d_un;
                    break;
                case DT_STRSZ:
                    dynstrSize_ = dyn[i].d_un;
                    break;
                case DT_RELA:
                    relaDynOffset_ = dyn[i].d_un;
                    break;
                case DT_RELASZ:
                    relaDynSize_ = dyn[i].d_un;
                    break;
                case DT_JMPREL:
                    relaPltOffset_ = dyn[i].d_un;
                    break;
                case DT_PLTRELSZ:
                    relaPltSize_ = dyn[i].d_un;
                    break;
                case DT_NEEDED:
                    if (dynstrOffset_ && dyn[i].d_un < dynstrSize_) {
                        needed_.push_back(reinterpret_cast<const char*>(data_.data() + dynstrOffset_ + dyn[i].d_un));
                    }
                    break;
                default:
                    break;
            }
        }

        // Derive symbol count from available metadata if not already known.
        if (dynsymOffset_ && dynstrOffset_) {
            // Heuristic: assume symbols are contiguous up to DT_HASH or end of segment.
            if (dynsymCount_ == 0 && relaDynOffset_ > dynsymOffset_) {
                dynsymCount_ = (relaDynOffset_ - dynsymOffset_) / sizeof(Elf64_Sym);
            }
        }
        return true;
    }
    return false;
}

const char* ELFReader::stringFromDynstr(uint32_t offset) const {
    if (!dynstrOffset_ || offset >= dynstrSize_) { return ""; }
    return reinterpret_cast<const char*>(data_.data() + dynstrOffset_ + offset);
}

const char* ELFReader::stringFromSectionName(uint32_t offset) const {
    const Elf64_Ehdr* ehdr = header();
    if (ehdr->e_shstrndx == SHN_UNDEF || ehdr->e_shstrndx >= shdrs_.size()) { return ""; }
    const Elf64_Shdr& strsh = shdrs_[ehdr->e_shstrndx];
    if (strsh.sh_offset + offset >= data_.size()) { return ""; }
    return reinterpret_cast<const char*>(data_.data() + strsh.sh_offset + offset);
}

const Elf64_Sym* ELFReader::dynSymbol(uint32_t index) const {
    if (index >= dynsymCount_) { return nullptr; }
    return reinterpret_cast<const Elf64_Sym*>(data_.data() + dynsymOffset_) + index;
}

const char* ELFReader::dynSymbolName(uint32_t index) const {
    const Elf64_Sym* sym = dynSymbol(index);
    if (!sym) { return nullptr; }
    return stringFromDynstr(sym->st_name);
}

std::vector<std::string> ELFReader::externalSymbols() const {
    std::vector<std::string> out;
    for (uint32_t i = 0; i < dynsymCount_; ++i) {
        const Elf64_Sym* sym = dynSymbol(i);
        if (!sym) { continue; }
        uint8_t bind = sym->st_info >> 4;
        if (bind != STB_GLOBAL && bind != STB_WEAK) { continue; }
        const char* name = dynSymbolName(i);
        if (!name || !name[0]) { continue; }
        out.emplace_back(name);
    }
    return out;
}

const uint8_t* ELFReader::sectionData(const std::string& name, size_t& outSize) const {
    for (const auto& sh : shdrs_) {
        const char* sname = stringFromSectionName(sh.sh_name);
        if (name == sname) {
            outSize = sh.sh_size;
            if (sh.sh_type == SHT_NOBITS) { return nullptr; }
            return data_.data() + sh.sh_offset;
        }
    }
    outSize = 0;
    return nullptr;
}

} // namespace droidshim
