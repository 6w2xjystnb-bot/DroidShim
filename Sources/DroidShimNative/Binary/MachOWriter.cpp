//
//  MachOWriter.cpp
//  DroidShimCore
//
//  Generate a thin Mach-O 64 dylib from an ELF64 AArch64 shared object.
//  Output is suitable for `codesign -s - --force`.
//

#include "MachOWriter.hpp"
#include <cstring>
#include <algorithm>
#include <fstream>
#include <set>

namespace droidshim {

// Mach-O header structures (packed).
#pragma pack(push, 1)
struct mach_header_64 {
    uint32_t magic;
    uint32_t cputype;
    uint32_t cpusubtype;
    uint32_t filetype;
    uint32_t ncmds;
    uint32_t sizeofcmds;
    uint32_t flags;
    uint32_t reserved;
};

struct segment_command_64 {
    uint32_t cmd;
    uint32_t cmdsize;
    char     segname[16];
    uint64_t vmaddr;
    uint64_t vmsize;
    uint64_t fileoff;
    uint64_t filesize;
    uint32_t maxprot;
    uint32_t initprot;
    uint32_t nsects;
    uint32_t flags;
};

struct section_64 {
    char     sectname[16];
    char     segname[16];
    uint64_t addr;
    uint64_t size;
    uint32_t offset;
    uint32_t align;
    uint32_t reloff;
    uint32_t nreloc;
    uint32_t flags;
    uint32_t reserved1;
    uint32_t reserved2;
    uint32_t reserved3;
};

struct symtab_command {
    uint32_t cmd;
    uint32_t cmdsize;
    uint32_t symoff;
    uint32_t nsyms;
    uint32_t stroff;
    uint32_t strsize;
};

struct dysymtab_command {
    uint32_t cmd;
    uint32_t cmdsize;
    uint32_t ilocalsym;
    uint32_t nlocalsym;
    uint32_t iextdefsym;
    uint32_t nextdefsym;
    uint32_t iundefsym;
    uint32_t nundefsym;
    uint32_t tocoff;
    uint32_t ntoc;
    uint32_t modtaboff;
    uint32_t nmodtab;
    uint32_t extrefsymoff;
    uint32_t nextrefsyms;
    uint32_t indirectsymoff;
    uint32_t nindirectsyms;
    uint32_t extreloff;
    uint32_t nextrel;
    uint32_t locreloff;
    uint32_t nlocrel;
};

struct dyld_info_command {
    uint32_t cmd;
    uint32_t cmdsize;
    uint32_t rebase_off;
    uint32_t rebase_size;
    uint32_t bind_off;
    uint32_t bind_size;
    uint32_t weak_bind_off;
    uint32_t weak_bind_size;
    uint32_t lazy_bind_off;
    uint32_t lazy_bind_size;
    uint32_t export_off;
    uint32_t export_size;
};

struct dylib_command {
    uint32_t cmd;
    uint32_t cmdsize;
    uint32_t name_offset;
    uint32_t timestamp;
    uint32_t current_version;
    uint32_t compatibility_version;
};

struct build_version_command {
    uint32_t cmd;
    uint32_t cmdsize;
    uint32_t platform;
    uint32_t minos;
    uint32_t sdk;
    uint32_t ntools;
};

struct uuid_command {
    uint32_t cmd;
    uint32_t cmdsize;
    uint8_t  uuid[16];
};

struct nlist_64 {
    uint32_t n_strx;
    uint8_t  n_type;
    uint8_t  n_sect;
    uint16_t n_desc;
    uint64_t n_value;
};
#pragma pack(pop)

// Page size for arm64.
constexpr uint64_t PAGE_SIZE = 0x4000;
constexpr uint64_t SEGMENT_ALIGN = 0x4000;

static uint64_t alignUp(uint64_t value, uint64_t align) {
    if (align == 0) return value;
    return (value + align - 1) & ~(align - 1);
}

static void pad(std::vector<uint8_t>& buf, uint64_t toSize, uint8_t fill = 0) {
    if (buf.size() < toSize) {
        buf.resize(toSize, fill);
    }
}

static void copySectionName(char dst[16], const char* src) {
    std::memset(dst, 0, 16);
    std::strncpy(dst, src, 15);
}

void MachOWriter::encodeULEB128(uint64_t value, std::vector<uint8_t>& out) {
    do {
        uint8_t byte = value & 0x7f;
        value >>= 7;
        if (value != 0) byte |= 0x80;
        out.push_back(byte);
    } while (value != 0);
}

void MachOWriter::encodeSLEB128(int64_t value, std::vector<uint8_t>& out) {
    bool more = true;
    while (more) {
        uint8_t byte = value & 0x7f;
        value >>= 7;
        if ((value == 0 && (byte & 0x40) == 0) || (value == -1 && (byte & 0x40) != 0)) {
            more = false;
        } else {
            byte |= 0x80;
        }
        out.push_back(byte);
    }
}

MachOWriteResult MachOWriter::generate(const ELFReader& elf,
                                       const std::vector<std::string>& bindSymbols,
                                       const MachOWriterConfig& config) {
    MachOWriteResult result;
    buffer_.clear();
    symbols_.clear();

    // Gather ELF sections we care about.
    size_t textSize = 0, rodataSize = 0, dataSize = 0, bssSize = 0;
    const uint8_t* textData = elf.sectionData(".text", textSize);
    const uint8_t* rodataData = elf.sectionData(".rodata", rodataSize);
    const uint8_t* dataData = elf.sectionData(".data", dataSize);
    const uint8_t* bssData = elf.sectionData(".bss", bssSize); // returns nullptr, size only
    (void)bssData;

    // Base virtual address. dyld requires non-zero for r-x segments.
    uint64_t baseAddr = 0x100000000ULL;
    uint64_t fileOffset = sizeof(mach_header_64);

    // Reserve header space.
    buffer_.resize(fileOffset, 0);

    // --- LC_SEGMENT_64 __TEXT ---
    uint64_t textVmAddr = baseAddr;
    uint64_t textFileOffset = fileOffset;
    uint64_t textVmSize = alignUp(textSize + rodataSize, PAGE_SIZE);
    uint64_t textFileSize = textSize + rodataSize;

    // We build load commands first to know sizeofcmds, then append raw segment data.
    // For simplicity, we record command positions and fill them in after computing sizes.
    std::vector<uint8_t> loadCommands;

    // __TEXT segment command placeholder.
    size_t textCmdOff = loadCommands.size();
    segment_command_64 textSeg{};
    textSeg.cmd = LC_SEGMENT_64;
    textSeg.cmdsize = sizeof(segment_command_64) + 2 * sizeof(section_64);
    copySectionName(textSeg.segname, "__TEXT");
    textSeg.vmaddr = textVmAddr;
    textSeg.vmsize = textVmSize;
    textSeg.fileoff = textFileOffset;
    textSeg.filesize = textFileSize;
    textSeg.maxprot = 0x5; // r-x
    textSeg.initprot = 0x5;
    textSeg.nsects = 2;
    loadCommands.insert(loadCommands.end(),
                        reinterpret_cast<uint8_t*>(&textSeg),
                        reinterpret_cast<uint8_t*>(&textSeg) + sizeof(textSeg));

    // __text section
    section_64 textSect{};
    copySectionName(textSect.sectname, "__text");
    copySectionName(textSect.segname, "__TEXT");
    textSect.addr = textVmAddr;
    textSect.size = textSize;
    textSect.offset = static_cast<uint32_t>(textFileOffset);
    textSect.align = 12; // 2^12 = 4096
    textSect.flags = 0x80000400; // S_REGULAR | S_ATTR_PURE_INSTRUCTIONS
    loadCommands.insert(loadCommands.end(),
                        reinterpret_cast<uint8_t*>(&textSect),
                        reinterpret_cast<uint8_t*>(&textSect) + sizeof(textSect));

    // __const section
    section_64 constSect{};
    copySectionName(constSect.sectname, "__const");
    copySectionName(constSect.segname, "__TEXT");
    constSect.addr = textVmAddr + textSize;
    constSect.size = rodataSize;
    constSect.offset = static_cast<uint32_t>(textFileOffset + textSize);
    constSect.align = 12;
    constSect.flags = 0x00000000;
    loadCommands.insert(loadCommands.end(),
                        reinterpret_cast<uint8_t*>(&constSect),
                        reinterpret_cast<uint8_t*>(&constSect) + sizeof(constSect));

    // --- LC_SEGMENT_64 __DATA ---
    uint64_t dataVmAddr = alignUp(textVmAddr + textVmSize, SEGMENT_ALIGN);
    uint64_t dataFileOffset = alignUp(textFileOffset + textFileSize, SEGMENT_ALIGN);
    uint64_t dataVmSize = alignUp(dataSize + bssSize, PAGE_SIZE);
    uint64_t dataFileSize = dataSize;

    segment_command_64 dataSeg{};
    dataSeg.cmd = LC_SEGMENT_64;
    dataSeg.cmdsize = sizeof(segment_command_64) + 2 * sizeof(section_64);
    copySectionName(dataSeg.segname, "__DATA");
    dataSeg.vmaddr = dataVmAddr;
    dataSeg.vmsize = dataVmSize;
    dataSeg.fileoff = dataFileOffset;
    dataSeg.filesize = dataFileSize;
    dataSeg.maxprot = 0x3; // rw-
    dataSeg.initprot = 0x3;
    dataSeg.nsects = 2;
    loadCommands.insert(loadCommands.end(),
                        reinterpret_cast<uint8_t*>(&dataSeg),
                        reinterpret_cast<uint8_t*>(&dataSeg) + sizeof(dataSeg));

    section_64 dataSect{};
    copySectionName(dataSect.sectname, "__data");
    copySectionName(dataSect.segname, "__DATA");
    dataSect.addr = dataVmAddr;
    dataSect.size = dataSize;
    dataSect.offset = static_cast<uint32_t>(dataFileOffset);
    dataSect.align = 12;
    dataSect.flags = 0x00000000;
    loadCommands.insert(loadCommands.end(),
                        reinterpret_cast<uint8_t*>(&dataSect),
                        reinterpret_cast<uint8_t*>(&dataSect) + sizeof(dataSect));

    section_64 bssSect{};
    copySectionName(bssSect.sectname, "__bss");
    copySectionName(bssSect.segname, "__DATA");
    bssSect.addr = dataVmAddr + dataSize;
    bssSect.size = bssSize;
    bssSect.offset = 0; // no file data
    bssSect.align = 12;
    bssSect.flags = 0x00000001; // S_ZEROFILL
    loadCommands.insert(loadCommands.end(),
                        reinterpret_cast<uint8_t*>(&bssSect),
                        reinterpret_cast<uint8_t*>(&bssSect) + sizeof(bssSect));

    // --- LC_SEGMENT_64 __LINKEDIT placeholder ---
    size_t linkeditCmdOff = loadCommands.size();
    segment_command_64 linkeditSeg{};
    linkeditSeg.cmd = LC_SEGMENT_64;
    linkeditSeg.cmdsize = sizeof(segment_command_64);
    copySectionName(linkeditSeg.segname, "__LINKEDIT");
    linkeditSeg.maxprot = 0x1; // r--
    linkeditSeg.initprot = 0x1;
    linkeditSeg.nsects = 0;
    loadCommands.insert(loadCommands.end(),
                        reinterpret_cast<uint8_t*>(&linkeditSeg),
                        reinterpret_cast<uint8_t*>(&linkeditSeg) + sizeof(linkeditSeg));

    // --- LC_ID_DYLIB ---
    {
        dylib_command idCmd{};
        idCmd.cmd = LC_ID_DYLIB;
        idCmd.timestamp = 2;
        idCmd.current_version = 0x00010000;
        idCmd.compatibility_version = 0x00010000;
        idCmd.name_offset = sizeof(dylib_command);
        std::string name = config.identifier + ".dylib";
        idCmd.cmdsize = static_cast<uint32_t>(alignUp(sizeof(dylib_command) + name.size() + 1, 8));
        loadCommands.insert(loadCommands.end(),
                            reinterpret_cast<uint8_t*>(&idCmd),
                            reinterpret_cast<uint8_t*>(&idCmd) + sizeof(idCmd));
        loadCommands.insert(loadCommands.end(), name.begin(), name.end());
        loadCommands.push_back(0);
        pad(loadCommands, alignUp(loadCommands.size(), 8));
    }

    // --- LC_LOAD_DYLIB libbionic_shim ---
    {
        dylib_command loadCmd{};
        loadCmd.cmd = LC_LOAD_DYLIB;
        loadCmd.timestamp = 2;
        loadCmd.current_version = 0x00010000;
        loadCmd.compatibility_version = 0x00010000;
        loadCmd.name_offset = sizeof(dylib_command);
        loadCmd.cmdsize = static_cast<uint32_t>(alignUp(sizeof(dylib_command) + config.shimPath.size() + 1, 8));
        loadCommands.insert(loadCommands.end(),
                            reinterpret_cast<uint8_t*>(&loadCmd),
                            reinterpret_cast<uint8_t*>(&loadCmd) + sizeof(loadCmd));
        loadCommands.insert(loadCommands.end(), config.shimPath.begin(), config.shimPath.end());
        loadCommands.push_back(0);
        pad(loadCommands, alignUp(loadCommands.size(), 8));
    }

    // --- LC_SYMTAB placeholder ---
    size_t symtabCmdOff = loadCommands.size();
    symtab_command symtab{};
    symtab.cmd = LC_SYMTAB;
    symtab.cmdsize = sizeof(symtab_command);
    loadCommands.insert(loadCommands.end(),
                        reinterpret_cast<uint8_t*>(&symtab),
                        reinterpret_cast<uint8_t*>(&symtab) + sizeof(symtab));

    // --- LC_DYSYMTAB placeholder ---
    size_t dysymtabCmdOff = loadCommands.size();
    dysymtab_command dysymtab{};
    dysymtab.cmd = LC_DYSYMTAB;
    dysymtab.cmdsize = sizeof(dysymtab_command);
    loadCommands.insert(loadCommands.end(),
                        reinterpret_cast<uint8_t*>(&dysymtab),
                        reinterpret_cast<uint8_t*>(&dysymtab) + sizeof(dysymtab));

    // --- LC_DYLD_INFO_ONLY placeholder ---
    size_t dyldInfoCmdOff = loadCommands.size();
    dyld_info_command dyldInfo{};
    dyldInfo.cmd = LC_DYLD_INFO_ONLY;
    dyldInfo.cmdsize = sizeof(dyld_info_command);
    loadCommands.insert(loadCommands.end(),
                        reinterpret_cast<uint8_t*>(&dyldInfo),
                        reinterpret_cast<uint8_t*>(&dyldInfo) + sizeof(dyldInfo));

    // --- LC_BUILD_VERSION ---
    {
        build_version_command bv{};
        bv.cmd = LC_BUILD_VERSION;
        bv.cmdsize = sizeof(build_version_command);
        bv.platform = PLATFORM_IOS;
        bv.minos = packedVersion(config.minOSMajor, config.minOSMinor, config.minOSPatch);
        bv.sdk = packedVersion(config.sdkMajor, config.sdkMinor, config.sdkPatch);
        bv.ntools = 0;
        loadCommands.insert(loadCommands.end(),
                            reinterpret_cast<uint8_t*>(&bv),
                            reinterpret_cast<uint8_t*>(&bv) + sizeof(bv));
    }

    // --- LC_UUID ---
    {
        uuid_command uc{};
        uc.cmd = LC_UUID;
        uc.cmdsize = sizeof(uuid_command);
        std::memset(uc.uuid, 0xAB, 16);
        loadCommands.insert(loadCommands.end(),
                            reinterpret_cast<uint8_t*>(&uc),
                            reinterpret_cast<uint8_t*>(&uc) + sizeof(uc));
    }

    // Finalize header size and layout.
    uint32_t ncmds = static_cast<uint32_t>(
        3 + // segments
        1 + // LC_ID_DYLIB
        1 + // LC_LOAD_DYLIB
        1 + // LC_SYMTAB
        1 + // LC_DYSYMTAB
        1 + // LC_DYLD_INFO_ONLY
        1 + // LC_BUILD_VERSION
        1   // LC_UUID
    );
    uint32_t sizeofcmds = static_cast<uint32_t>(loadCommands.size());

    // Write header.
    mach_header_64 hdr{};
    hdr.magic = MH_MAGIC_64;
    hdr.cputype = DS_CPU_TYPE_ARM64;
    hdr.cpusubtype = DS_CPU_SUBTYPE_ARM64_ALL;
    hdr.filetype = MH_DYLIB;
    hdr.ncmds = ncmds;
    hdr.sizeofcmds = sizeofcmds;
    hdr.flags = 0x00000085; // MH_NOUNDEFS | MH_DYLDLINK | MH_TWOLEVEL
    hdr.reserved = 0;
    std::memcpy(buffer_.data(), &hdr, sizeof(hdr));

    // Append load commands.
    buffer_.insert(buffer_.end(), loadCommands.begin(), loadCommands.end());

    // Append __TEXT raw data.
    pad(buffer_, textFileOffset);
    if (textData && textSize) {
        buffer_.insert(buffer_.end(), textData, textData + textSize);
    }
    if (rodataData && rodataSize) {
        pad(buffer_, textFileOffset + textSize);
        buffer_.insert(buffer_.end(), rodataData, rodataData + rodataSize);
    }
    pad(buffer_, textFileOffset + textFileSize);

    // Append __DATA raw data.
    pad(buffer_, dataFileOffset);
    if (dataData && dataSize) {
        buffer_.insert(buffer_.end(), dataData, dataData + dataSize);
    }

    // --- Build __LINKEDIT ---
    linkeditFileOffset_ = alignUp(buffer_.size(), SEGMENT_ALIGN);
    linkeditVmAddr_ = alignUp(dataVmAddr + dataVmSize, SEGMENT_ALIGN);

    // Symbol table: one undefined symbol per bind target + any exported defined symbols.
    std::set<std::string> bindSet(bindSymbols.begin(), bindSymbols.end());
    for (const auto& symName : bindSymbols) {
        MachOSymbol sym;
        sym.name = symName;
        sym.type = N_EXT | N_UNDF;
        sym.section = 0;
        sym.external = true;
        symbols_.push_back(sym);
    }

    // Build string table.
    std::vector<uint8_t> stringTable;
    stringTable.push_back(0); // index 0 = empty string
    std::vector<nlist_64> nlists;
    for (auto& sym : symbols_) {
        nlist_64 nl{};
        nl.n_strx = static_cast<uint32_t>(stringTable.size());
        nl.n_type = sym.type;
        nl.n_sect = sym.section;
        nl.n_desc = sym.desc;
        nl.n_value = sym.value;
        nlists.push_back(nl);
        stringTable.insert(stringTable.end(), sym.name.begin(), sym.name.end());
        stringTable.push_back(0);
    }
    pad(stringTable, alignUp(stringTable.size(), 8));

    // Rebase info: simple table of pointer rebases in __DATA and __TEXT (if any).
    std::vector<uint8_t> rebaseInfo;
    {
        using namespace rebinding;
        rebaseInfo.push_back(REBASE_OPCODE_SET_TYPE_IMM | REBASE_TYPE_POINTER);
        rebaseInfo.push_back(REBASE_OPCODE_SET_SEGMENT_AND_OFFSET_ULEB | 1); // __DATA segment index 1
        encodeULEB128(0, rebaseInfo);
        rebaseInfo.push_back(REBASE_OPCODE_DO_REBASE_IMM_TIMES | 1); // at least one placeholder
        rebaseInfo.push_back(REBASE_OPCODE_DONE);
    }

    // Bind info: bind each external symbol to libbionic_shim (ordinal 1).
    std::vector<uint8_t> bindInfo;
    {
        using namespace rebinding;
        bindInfo.push_back(BIND_OPCODE_SET_DYLIB_ORDINAL_IMM | 1);
        bindInfo.push_back(BIND_OPCODE_SET_TYPE_IMM | BIND_TYPE_POINTER);

        uint64_t currentSegmentOffset = 0;
        bool segmentSet = false;
        for (const auto& sym : symbols_) {
            if (!sym.external || sym.section != 0) continue;
            if (!segmentSet) {
                bindInfo.push_back(BIND_OPCODE_SET_SEGMENT_AND_OFFSET_ULEB | 1); // __DATA
                encodeULEB128(0, bindInfo);
                segmentSet = true;
            } else {
                bindInfo.push_back(BIND_OPCODE_DO_BIND_ADD_ADDR_ULEB);
                encodeULEB128(sizeof(uint64_t), bindInfo);
            }
            bindInfo.push_back(BIND_OPCODE_SET_SYMBOL_TRAILING_FLAGS_IMM);
            bindInfo.insert(bindInfo.end(), sym.name.begin(), sym.name.end());
            bindInfo.push_back(0);
            bindInfo.push_back(BIND_OPCODE_DO_BIND);
            currentSegmentOffset += sizeof(uint64_t);
        }
        bindInfo.push_back(BIND_OPCODE_DONE);
    }

    // Lazy bind is empty.
    std::vector<uint8_t> weakBind;
    std::vector<uint8_t> lazyBind;
    std::vector<uint8_t> exportInfo;
    exportInfo.push_back(0); // empty export trie

    // Write linkedit sections.
    pad(buffer_, linkeditFileOffset_);
    rebaseInfoStart_ = buffer_.size();
    buffer_.insert(buffer_.end(), rebaseInfo.begin(), rebaseInfo.end());
    pad(buffer_, alignUp(buffer_.size(), 8));
    bindInfoStart_ = buffer_.size();
    buffer_.insert(buffer_.end(), bindInfo.begin(), bindInfo.end());
    pad(buffer_, alignUp(buffer_.size(), 8));
    // weak_bind / lazy_bind / export omitted for MVP (zero offsets).
    (void)weakBind;
    (void)lazyBind;
    (void)exportInfo;

    symbolTableStart_ = alignUp(buffer_.size(), 8);
    pad(buffer_, symbolTableStart_);
    buffer_.insert(buffer_.end(),
                   reinterpret_cast<uint8_t*>(nlists.data()),
                   reinterpret_cast<uint8_t*>(nlists.data()) + nlists.size() * sizeof(nlist_64));

    stringTableStart_ = alignUp(buffer_.size(), 8);
    pad(buffer_, stringTableStart_);
    buffer_.insert(buffer_.end(), stringTable.begin(), stringTable.end());

    uint64_t linkeditFileSize = buffer_.size() - linkeditFileOffset_;

    // Patch __LINKEDIT segment command.
    segment_command_64* leSeg = reinterpret_cast<segment_command_64*>(buffer_.data() + sizeof(mach_header_64) + linkeditCmdOff);
    leSeg->vmaddr = linkeditVmAddr_;
    leSeg->vmsize = alignUp(linkeditFileSize, PAGE_SIZE);
    leSeg->fileoff = linkeditFileOffset_;
    leSeg->filesize = linkeditFileSize;

    // Patch LC_SYMTAB.
    symtab_command* st = reinterpret_cast<symtab_command*>(buffer_.data() + sizeof(mach_header_64) + symtabCmdOff);
    st->symoff = static_cast<uint32_t>(symbolTableStart_);
    st->nsyms = static_cast<uint32_t>(nlists.size());
    st->stroff = static_cast<uint32_t>(stringTableStart_);
    st->strsize = static_cast<uint32_t>(stringTable.size());

    // Patch LC_DYSYMTAB.
    dysymtab_command* dst = reinterpret_cast<dysymtab_command*>(buffer_.data() + sizeof(mach_header_64) + dysymtabCmdOff);
    dst->ilocalsym = 0;
    dst->nlocalsym = 0;
    dst->iextdefsym = 0;
    dst->nextdefsym = 0;
    dst->iundefsym = 0;
    dst->nundefsym = static_cast<uint32_t>(nlists.size());

    // Patch LC_DYLD_INFO_ONLY.
    dyld_info_command* di = reinterpret_cast<dyld_info_command*>(buffer_.data() + sizeof(mach_header_64) + dyldInfoCmdOff);
    di->rebase_off = static_cast<uint32_t>(rebaseInfoStart_);
    di->rebase_size = static_cast<uint32_t>(rebaseInfo.size());
    di->bind_off = static_cast<uint32_t>(bindInfoStart_);
    di->bind_size = static_cast<uint32_t>(bindInfo.size());
    di->weak_bind_off = 0;
    di->weak_bind_size = 0;
    di->lazy_bind_off = 0;
    di->lazy_bind_size = 0;
    di->export_off = 0;
    di->export_size = 0;

    // Write file.
    std::ofstream out(config.outputPath, std::ios::binary);
    if (!out) {
        result.error = "Failed to open output file";
        return result;
    }
    out.write(reinterpret_cast<const char*>(buffer_.data()), buffer_.size());
    out.close();

    result.success = true;
    result.outputPath = config.outputPath;
    return result;
}

} // namespace droidshim
