// swift-tools-version: 6.1
import PackageDescription

let package = Package(
    name: "Threadline",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "ConversationCore", targets: ["ConversationCore"]),
        .library(name: "ProviderKit", targets: ["ProviderKit"]),
        .library(name: "ThreadlineRuntime", targets: ["ThreadlineRuntime"]),
        .executable(name: "Threadline", targets: ["Threadline"]),
        .executable(name: "ThreadlineAgent", targets: ["ThreadlineAgent"]),
    ],
    targets: [
        .systemLibrary(
            name: "CSQLite",
            pkgConfig: "sqlite3",
            providers: [.brew(["sqlite3"])]
        ),
        .target(
            name: "ConversationCore",
            dependencies: ["CSQLite"],
            path: "Sources/ConversationCore"
        ),
        .target(
            name: "ProviderKit",
            dependencies: ["ConversationCore"],
            path: "Sources/ProviderKit"
        ),
        .target(
            name: "ThreadlineRuntime",
            dependencies: ["ConversationCore", "ProviderKit"],
            path: "Sources/ThreadlineRuntime"
        ),
        .executableTarget(
            name: "Threadline",
            dependencies: ["ConversationCore", "ProviderKit", "ThreadlineRuntime"],
            path: "Sources/Threadline",
            // The app packager installs these brand assets directly into the
            // native application bundle. Development builds load the same
            // files from the source tree, so SwiftPM should not synthesize a
            // separate resource bundle.
            exclude: ["Resources"]
        ),
        .executableTarget(
            name: "ThreadlineAgent",
            dependencies: ["ConversationCore", "ProviderKit", "ThreadlineRuntime"],
            path: "Sources/ThreadlineAgent"
        ),
        .testTarget(
            name: "ConversationCoreTests",
            dependencies: ["ConversationCore"],
            path: "Tests/ConversationCoreTests"
        ),
        .testTarget(
            name: "ProviderKitTests",
            dependencies: ["ProviderKit", "ConversationCore"],
            path: "Tests/ProviderKitTests"
        ),
        .testTarget(
            name: "ThreadlineRuntimeTests",
            dependencies: ["ThreadlineRuntime", "ProviderKit", "ConversationCore"],
            path: "Tests/ThreadlineRuntimeTests"
        ),
    ],
    swiftLanguageModes: [.v6]
)
