import Foundation
import DroidShimNative

public enum DroidShimBootstrap {
    public static func initialize() {
        droidshim_initialize_shim()
    }
}

public enum DroidShimNativeConversionError: Error, CustomStringConvertible {
    case elfParseFailed
    case machOWriteFailed(String)

    public var description: String {
        switch self {
        case .elfParseFailed:
            return "ELF parse failed"
        case .machOWriteFailed(let message):
            return "Mach-O write failed: \(message)"
        }
    }
}

public enum DroidShimNativeConverter {
    public static func convertELFToMachO(data: Data, outputPath: String, installName: String) throws {
        let bridge = DSBinaryBridge()
        let count = bridge.parseELF(data)
        guard count >= 0 else {
            throw DroidShimNativeConversionError.elfParseFailed
        }

        var error: NSString?
        let ok = bridge.writeMachO(toPath: outputPath, installName: installName, error: &error)
        guard ok else {
            throw DroidShimNativeConversionError.machOWriteFailed(error as String? ?? "unknown")
        }
    }
}
