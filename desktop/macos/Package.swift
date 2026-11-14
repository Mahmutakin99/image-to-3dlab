// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "AssetFurnaceDesktop",
    platforms: [.macOS(.v12)],
    products: [.library(name: "Core", targets: ["Core"]),
               .executable(name: "AssetFurnace", targets: ["App"])],
    dependencies: [.package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.10.1")],
    targets: [.target(name: "Core"),
              .executableTarget(name: "App", dependencies: ["Core", .product(name: "Sparkle", package: "Sparkle")],
                  linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])]),
              .testTarget(name: "CoreTests", dependencies: ["Core"])]
)
