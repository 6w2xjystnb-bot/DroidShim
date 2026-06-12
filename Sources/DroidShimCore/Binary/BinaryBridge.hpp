//
//  BinaryBridge.hpp
//  DroidShimCore
//
//  Internal C++ bridge declarations.  Swift does not import this directly;
//  use BinaryBridge.h / BinaryBridge.mm instead.
//

#pragma once

#include "ELFReader.hpp"
#include "MachOWriter.hpp"
#include "RelocationMapper.hpp"

namespace droidshim {

// Internal helpers can be added here as the binary pipeline matures.
// For Phase 1, the Objective-C++ DSBinaryBridge class is the public surface.

} // namespace droidshim
