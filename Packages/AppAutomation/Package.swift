// swift-tools-version: 6.1
import PackageDescription

let package = Package(
    name: "AppAutomation",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [
        .library(name: "AutomationRuntime", targets: ["AutomationRuntime"]),
        .library(name: "AutomationCLI", targets: ["AutomationCLI"]),
        .executable(name: "app-interface", targets: ["InterfaceGenerator"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-openapi-generator", exact: "1.13.1"),
        .package(url: "https://github.com/apple/swift-openapi-runtime", exact: "1.12.1"),
        .package(url: "https://github.com/apple/swift-argument-parser", exact: "1.8.2"),
        .package(url: "https://github.com/jpsim/Yams", exact: "6.2.2"),
    ],
    targets: [
        .target(name: "AutomationRuntime", dependencies: [
            .product(name: "OpenAPIRuntime", package: "swift-openapi-runtime")
        ]),
        .target(name: "AutomationCLI", dependencies: ["AutomationRuntime",
            .product(name: "ArgumentParser", package: "swift-argument-parser")]),
        .executableTarget(name: "InterfaceGenerator", dependencies: [
            .product(name: "Yams", package: "Yams")]),
        .testTarget(name: "AutomationTests", dependencies: ["AutomationRuntime", "AutomationCLI"]),
    ],
    swiftLanguageModes: [.v5]
)
