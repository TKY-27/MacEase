// swift-tools-version: 6.2
import Foundation
import PackageDescription

let nativeFramework = "Native/CNative.xcframework"
let packageRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
guard FileManager.default.fileExists(atPath: packageRoot.appending(path: nativeFramework).path) else {
    fatalError("Native dependencies are missing. Run scripts/build-deps.sh from the repository root.")
}

let strict: [SwiftSetting] = [.treatAllWarnings(as: .error)]

let package = Package(
    name: "MacEaseKit",
    defaultLocalization: "en",
    platforms: [.macOS("26.0")],
    products: [
        .library(name: "MenuCatalog", targets: ["MenuCatalog"]),
        .library(name: "Engine", targets: ["Engine"]),
    ],
    dependencies: [
        .package(url: "https://github.com/swiftlang/swift-cmark.git", exact: "0.9.0"),
        .package(url: "https://github.com/jpsim/Yams.git", exact: "6.2.2"),
    ],
    targets: [
        .target(name: "MenuCatalog", swiftSettings: strict),
        .binaryTarget(name: "CNative", path: nativeFramework),
        .target(name: "NativeShims", dependencies: ["CNative"]),
        .target(name: "TOMLBridge", cxxSettings: [.unsafeFlags(["-Wall", "-Wextra", "-Werror"])]),
        .target(
            name: "Formats",
            dependencies: ["CNative", "NativeShims"],
            swiftSettings: strict + [.unsafeFlags(["-O"])],
            linkerSettings: [.linkedLibrary("c++"), .linkedLibrary("z"), .linkedLibrary("bz2")]
        ),
        .target(
            name: "Engine",
            dependencies: [
                "MenuCatalog", "Formats",
                .product(name: "cmark-gfm", package: "swift-cmark"),
                .product(name: "cmark-gfm-extensions", package: "swift-cmark"),
                .product(name: "Yams", package: "Yams"),
                "TOMLBridge",
            ],
            resources: [.process("Resources")],
            swiftSettings: strict
        ),
        .executableTarget(name: "Benchmarks", dependencies: ["Engine", "MenuCatalog"], swiftSettings: strict),
        .testTarget(name: "MenuCatalogTests", dependencies: ["MenuCatalog"], swiftSettings: strict),
        .testTarget(
            name: "FormatsTests", dependencies: ["Formats"], resources: [.copy("Resources")], swiftSettings: strict
        ),
        .testTarget(
            name: "EngineTests", dependencies: ["Engine"], resources: [.copy("Resources")], swiftSettings: strict
        ),
    ],
    cxxLanguageStandard: .cxx17
)
