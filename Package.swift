// swift-tools-version: 6.1
// The swift-tools-version declares the minimum version of Swift required to build this package.

import Foundation
import PackageDescription

let fileManager = FileManager.default
let llvmPrefixes = [
    "/opt/homebrew/opt/llvm",
    "/usr/local/opt/llvm"
]
// LLVM is opt-in because otherwise builds without it will fail during linking
let llvmPrefix = ProcessInfo.processInfo.environment["DPREADER_ENABLE_LLVM"] == "1"
    ? llvmPrefixes.first { prefix in
        fileManager.fileExists(atPath: "\(prefix)/include/llvm-c/Analysis.h") &&
        fileManager.fileExists(atPath: "\(prefix)/include/llvm-c/Core.h") &&
        fileManager.fileExists(atPath: "\(prefix)/include/llvm-c/ExecutionEngine.h") &&
        fileManager.fileExists(atPath: "\(prefix)/lib/libLLVM-C.dylib")
    }
    : nil

var dpReaderDependencies: [Target.Dependency] = ["CryptoSwift", "TestVisible"]
var dpReaderSwiftSettings: [SwiftSetting] = []
var dpReaderLinkerSettings: [LinkerSetting] = []
var dpReaderTestsSwiftSettings: [SwiftSetting] = []
var targets: [Target] = []

if let llvmPrefix {
    targets.append(
        .target(
            name: "CLLVM",
            path: "Sources/CLLVM",
            publicHeadersPath: "include",
            cSettings: [
                .unsafeFlags(["-I\(llvmPrefix)/include"])
            ]
        )
    )
    dpReaderDependencies.append("CLLVM")
    dpReaderSwiftSettings.append(.unsafeFlags(["-Xcc", "-I\(llvmPrefix)/include"]))
    dpReaderTestsSwiftSettings.append(.unsafeFlags(["-Xcc", "-I\(llvmPrefix)/include"]))
    dpReaderLinkerSettings.append(contentsOf: [
        .unsafeFlags([
            "-L\(llvmPrefix)/lib",
            "-Xlinker", "-rpath",
            "-Xlinker", "\(llvmPrefix)/lib"
        ]),
        .linkedLibrary("LLVM-C"),
        .linkedLibrary("LLVM")
    ])
}

targets.append(
    .target(
        name: "DPReader",
        dependencies: dpReaderDependencies,
        swiftSettings: dpReaderSwiftSettings,
        linkerSettings: dpReaderLinkerSettings
    )
)
targets.append(
    .testTarget(
        name: "DPReaderTests",
        dependencies: ["DPReader"],
        swiftSettings: dpReaderTestsSwiftSettings
    )
)

let package = Package(
    name: "DPReader",
    platforms: [
        .macOS(.v10_15)
    ],
    products: [
        // Products define the executables and libraries a package produces, making them visible to other packages.
        .library(
            name: "DPReader",
            targets: ["DPReader"]),
    ],
    dependencies: [
        .package(url: "https://github.com/krzyzanowskim/CryptoSwift.git", from: "1.9.0"),
        .package(url: "https://github.com/watanabetoshinori/TestVisible.git", from: "1.0.0"),
        .package(url: "https://github.com/apple/swift-docc-plugin", from: "1.0.0")
    ],
    targets: targets,
)
