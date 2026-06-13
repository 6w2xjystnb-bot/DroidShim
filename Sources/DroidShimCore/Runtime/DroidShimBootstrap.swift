import DroidShimNative

public enum DroidShimBootstrap {
    public static func initialize() {
        droidshim_initialize_shim()
    }
}
