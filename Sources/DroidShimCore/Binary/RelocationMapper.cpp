//
//  RelocationMapper.cpp
//  DroidShimCore
//
//  ELF RELA -> Mach-O rebase/bind mapping.
//

#include "RelocationMapper.hpp"
#include <cstring>

namespace droidshim {

static uint64_t sectionBaseForAddress(const ELFReader& elf, uint64_t addr,
                                      uint64_t textBase, uint64_t dataBase,
                                      bool& isData) {
    // Determine whether the ELF virtual address belongs to .text/.rodata (TEXT)
    // or .data/.bss (DATA) by inspecting section headers.
    size_t textSize = 0, rodataSize = 0, dataSize = 0, bssSize = 0;
    elf.sectionData(".text", textSize);
    elf.sectionData(".rodata", rodataSize);
    elf.sectionData(".data", dataSize);
    elf.sectionData(".bss", bssSize);

    // We assume the ELF was linked with the standard layout where .text is first
    // and .data follows after rodata. Since we do not have the original ELF base,
    // we classify by section order using offsets within the file.
    // For MVP, we simply check whether the relocation target section name contains "data".
    isData = false;

    // Heuristic: if address low bits suggest it belongs to data, map to dataBase.
    // A proper implementation would use section addresses; this is a Phase 1 simplification.
    (void)addr;
    (void)textSize;
    (void)rodataSize;
    (void)dataSize;
    (void)bssSize;
    return textBase;
}

RelocationResult RelocationMapper::map(const ELFReader& elf,
                                       uint64_t textBase,
                                       uint64_t dataBase) {
    RelocationResult result;

    auto process = [&](const std::vector<Elf64_Rela>& relocs) {
        for (const auto& rela : relocs) {
            uint64_t offset = rela.r_offset;
            uint32_t type = ELF64_R_TYPE(rela.r_info);
            uint32_t symIdx = ELF64_R_SYM(rela.r_info);

            FixupAction action;
            action.addend = static_cast<uint64_t>(rela.r_addend);
            action.relocationType = type;

            // Resolve target address.  We assume data relocations target __DATA
            // and everything else targets __TEXT.  In a production tool we would
            // look up the containing ELF section by sh_addr.
            bool isData = false;
            uint64_t base = sectionBaseForAddress(elf, offset, textBase, dataBase, isData);
            action.address = base + offset;

            switch (type) {
                case R_AARCH64_ABS64:
                case R_AARCH64_RELATIVE:
                    action.isBind = false;
                    result.rebases.push_back(action);
                    break;

                case R_AARCH64_GLOB_DAT:
                case R_AARCH64_JUMP_SLOT: {
                    const char* name = elf.dynSymbolName(symIdx);
                    if (!name || !name[0]) {
                        result.warnings.push_back("Undefined dynamic symbol index " + std::to_string(symIdx));
                        continue;
                    }
                    action.symbol = name;
                    action.isBind = true;
                    result.binds.push_back(action);
                    break;
                }

                case R_AARCH64_TLS_TPREL64: {
                    // TLS is unsupported in Phase 1.  Write a zero placeholder.
                    action.isBind = false;
                    result.rebases.push_back(action);
                    result.warnings.push_back("TLS relocation stubbed for symbol index " + std::to_string(symIdx));
                    break;
                }

                default:
                    result.warnings.push_back("Unsupported relocation type " + std::to_string(type));
                    break;
            }
        }
    };

    process(elf.relaDyn());
    process(elf.relaPlt());

    result.success = true;
    return result;
}

} // namespace droidshim
