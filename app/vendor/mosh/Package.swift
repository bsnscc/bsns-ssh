// swift-tools-version:5.9
import PackageDescription

// Vendored mosh client + protobuf-lite as a C++ target with a plain-C public
// interface (moshclient.h). Run fetch-mosh.sh to populate protobuf/ and
// mosh-src/ (both gitignored, regenerable).
let package = Package(
    name: "CMosh",
    platforms: [.iOS(.v17), .macOS(.v13)],
    products: [
        .library(name: "CMosh", targets: ["CMosh"]),
    ],
    targets: [
        .target(
            name: "CMosh",
            path: ".",
            exclude: [
                "fetch-mosh.sh",
                "config-ios.h",
                "display-ansi.cc",
                "hostinput.pb.cc", "hostinput.pb.h",
                "transportinstruction.pb.cc", "transportinstruction.pb.h",
                "userinput.pb.cc", "userinput.pb.h",
            ],
            sources: [
                "moshclient.cpp",
                "protobuf",
                "mosh-src/src",
            ],
            publicHeadersPath: "include",
            cxxSettings: [
                .headerSearchPath("include"),
                .headerSearchPath("mosh-src"),                 // full "src/..." includes
                .headerSearchPath("mosh-src/src/include"),
                // mosh 1.4.0 sources use bare includes ("crypto.h"); its autotools
                // build puts each source subdir on the include path. Mirror that.
                .headerSearchPath("mosh-src/src/crypto"),
                .headerSearchPath("mosh-src/src/network"),
                .headerSearchPath("mosh-src/src/terminal"),
                .headerSearchPath("mosh-src/src/statesync"),
                .headerSearchPath("mosh-src/src/util"),
                .headerSearchPath("mosh-src/src/protobufs"),
                .headerSearchPath("protobuf"),
                .define("HAVE_PTHREAD", to: "1"),
                .define("_DARWIN_C_SOURCE", to: "1"),
            ],
            linkerSettings: [
                .linkedLibrary("z"),
            ]
        ),
    ],
    cxxLanguageStandard: .cxx17
)
