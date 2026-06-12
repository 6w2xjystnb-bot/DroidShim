# DroidShim

**DroidShim** is a Phase 1 MVP userspace Android-to-iOS compatibility layer.
It lets you sideload a simple Android APK via AltStore / SideStore and run it
on a jailed iOS device with no JIT, no QEMU, no cloud, and no Android SDK.

The project rehosts Android ARM64 `.so` libraries as Mach-O dylibs, links them
against a Bionic→Darwin shim, interprets Dalvik bytecode directly, and maps
Android Views to UIKit in real time.

> ⚠️ Phase 1 is intentionally limited. It targets simple Java-only APKs such as
> a "Hello World" with a `TextView` and a `Button`. Games, WebViews, JNI-heavy
> libraries, and apps requiring Google Play Services are out of scope.

---

## Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│                        DroidShimApp (SwiftUI)                   │
│  ContainerGridView ──► ImportSheet ──► ContainerEngine          │
└───────────────────────────┬─────────────────────────────────────┘
                            │
┌───────────────────────────▼─────────────────────────────────────┐
│                        DroidShimCore                              │
│  ┌─────────────┐  ┌─────────────┐  ┌─────────────────────────┐  │
│  │ APK Parser  │  │ Binary XML  │  │ ResourceExtractor/arsc  │  │
│  └──────┬──────┘  └──────┬──────┘  └───────────┬─────────────┘  │
│         │                │                      │                │
│  ┌──────▼────────────────▼──────────────────────▼────────────┐  │
│  │                  ContainerEngine                           │  │
│  │   unzip → parse manifest → convert .so → codesign → launch │  │
│  └──────┬─────────────────────────────────────────────────────┘  │
│         │                                                         │
│  ┌──────▼──────┐  ┌──────────────┐  ┌──────────┐  ┌───────────┐ │
│  │ ELFReader   │──► Relocation   │──► MachO    │──► codesign   │ │
│  │  (C++17)    │  │ Mapper       │  │ Writer   │    -s -       │ │
│  └─────────────┘  └──────────────┘  └────┬─────┘  └───────────┘ │
│                                          │                       │
│  ┌───────────────────────────────────────▼───────────────────┐  │
│  │                    Bionic Shim (C++17)                      │  │
│  │ malloc/free/calloc │ pthread │ mmap │ epoll→kqueue │ dlopen │  │
│  └───────────────────────────────────────────────────────────┘  │
│                                                                  │
│  ┌──────────────────┐  ┌─────────────────┐  ┌────────────────┐ │
│  │ DexLoader (Swift)│  │ ARTInterpreter  │  │ JNIRegistry    │ │
│  │                  │──► (switch, no JIT)│──► dlsym / invoke │ │
│  └──────────────────┘  └─────────────────┘  └────────────────┘ │
│                                                                  │
│  ┌────────────────────────────────────────────────────────────┐ │
│  │  UI Bridge: Activity→UIViewController, ViewMapper, Canvas,  │ │
│  │  ResourceResolver, Looper→DispatchQueue                     │ │
│  └────────────────────────────────────────────────────────────┘ │
└─────────────────────────────────────────────────────────────────┘
```

---

## Samples

See `Samples/README.md` for a Phase 1 text-layout fallback example and
instructions on building a real test APK.

## Build Instructions

### Requirements

- macOS 14+ with Xcode 15.2+
- Swift 5.9+ with C++ interoperability enabled
- iOS 16+ deployment target
- Optional: `codesign` for ad-hoc signing converted `.dylib` files on macOS

### Swift Package Manager

```bash
swift build -Xswiftc -target -Xswiftc arm64-apple-ios16.0
swift test
```

### Xcode

Open `Package.swift` directly in Xcode 15.2+ or generate a project:

```bash
swift package generate-xcodeproj   # deprecated but usable for exploration
```

Then build the dynamic library and the host app:

```bash
xcodebuild -scheme DroidShimCore \
  -destination 'generic/platform=iOS' \
  -derivedDataPath ./build \
  BUILD_LIBRARY_FOR_DISTRIBUTION=YES

xcodebuild -scheme DroidShimApp \
  -destination 'generic/platform=iOS' \
  -derivedDataPath ./build \
  CODE_SIGN_IDENTITY="" \
  CODE_SIGNING_REQUIRED=NO \
  CODE_SIGNING_ALLOWED=NO
```

`DroidShimCore` is configured as a dynamic library so the converted Mach-O
`.dylib` files can bind against the Bionic shim symbols at runtime without
conflicting with the host iOS libc.

> Note: `DroidShimApp` is modeled as an SPM executable target for the host
> SwiftUI code. To produce a real `.app` bundle for an iOS device you should
> open `Package.swift` in Xcode or generate an Xcode project and build the
> `DroidShimApp` scheme from there.

### Package unsigned IPA

```bash
mkdir -p Payload
cp -R build/Build/Products/Debug-iphoneos/DroidShimApp.app Payload/
zip -r DroidShim.ipa Payload
rm -rf Payload
```

---

## How It Works

1. **Import**: The user picks an `.apk`. `APKParser` unzips it using the
   `Compression` framework and extracts `AndroidManifest.xml`, `classes.dex`,
   `resources.arsc`, native libraries, and the launcher icon.
2. **Manifest parsing**: `BinaryXMLParser` decodes the binary XML chunk format
   (StringPool, resource map, start/end elements) to find the package name,
   version code, and MAIN/LAUNCHER activity.
3. **Native library conversion**: For each `lib/arm64-v8a/*.so`, `ELFReader`
   parses the ELF64 AArch64 structure, `RelocationMapper` converts RELA
   relocations to Mach-O rebase/bind actions, and `MachOWriter` emits a thin
   Mach-O 64 dylib linked against `@rpath/libbionic_shim.dylib`.
4. **Code signing**: `ContainerEngine` runs `codesign -s - --force` on the
   generated dylib so iOS will load it.
5. **Runtime launch**: `DexLoader` parses the DEX file into Swift structures.
   `ARTInterpreter` executes Dalvik bytecode with a register-based switch loop.
   Java objects are allocated on the `JavaHeap` mark-and-sweep collector.
6. **UI mapping**: `ActivityBridge` creates a `UIViewController`. `ViewMapper`
   turns `LinearLayout` into `UIStackView`, `TextView` into `UILabel`,
   `Button` into `UIButton`, etc. A button tap resolves the `onClick` method
   through `JNIRegistry` and updates the UI on the main thread.

---

## Limitations

- **Phase 1 scaffold**: Several subsystems (binary XML layout decoding, complete
  Dalvik opcode coverage, R.java static-value decoding) are simplified or
  stubbed. The project builds and the core parsers pass unit tests, but running
  a real APK requires additional hardening.
- **No JIT**: Dalvik bytecode is interpreted; performance is suitable only for
  trivial apps.
- **No native x86 / ARM32**: Only `arm64-v8a` `.so` files are converted.
- **No full ART runtime**: Reflection, class loading, exceptions, and the JNI
  type system are stubbed or partially implemented.
- **No binary XML layouts**: Phase 1 cannot decode binary layout XML to UIKit.
  A text-layout fallback is provided for debugging.
- **No Binder / Ashmem fully**: Binder mmap returns `ENOMEM`; ashmem uses
  `shm_open` where applicable.
- **No PROT_EXEC on custom mmap**: iOS rejects executable memory for non-Apple
  signed pages; the shim downgrades such requests.
- **TLS / pthread internals**: Bionic-specific TLS layouts are approximated.
- **No fork/exec/popen/system**: iOS forbids these; none are used.

---

## Phase 2 Roadmap

- [ ] **ART AOT cache**: Pre-compile hot methods to a small threaded-code
  representation while still avoiding full JIT.
- [ ] **Binary XML layout decoder**: Decode `res/layout/*.xml` (binary XML) and
  build complete UIKit hierarchies including nested weights and margins.
- [ ] **RecyclerView adapter bridge**: Wire Android adapter callbacks to
  `UICollectionViewDataSource` / `Delegate`.
- [ ] **SurfaceView Metal backend**: Render `SurfaceView` content through
  `CAMetalLayer` and translate basic OpenGL ES draw calls to Metal.
- [ ] **More Dalvik opcodes**: floats, longs, doubles, `filled-new-array`,
  `throw`, `move-exception`, packed switches.
- [ ] **Concurrent GC**: Replace the stop-the-world collector with a simple
  mark-sweep supporting interpreter roots.
- [ ] **App Store cleanliness audit**: Ensure no private APIs are used.

---

## Security Note

The bundled `.github/workflows/build.yml` uses the short-lived
`${{ secrets.GITHUB_TOKEN }}` provided by GitHub Actions. Do not commit personal
access tokens or embed them in Git remotes.

---

## License

MIT License — DroidShim is an experimental research project.
