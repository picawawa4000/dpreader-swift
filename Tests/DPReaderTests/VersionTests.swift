import Foundation
import Testing
@testable import DPReader

private func makePackRoot(withPackMetadata metadata: String) throws -> URL {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: root.appendingPathComponent("data"), withIntermediateDirectories: true)
    try metadata.data(using: .utf8)!.write(to: root.appendingPathComponent("pack.mcmeta"))
    return root
}

@Test func testVersionRangeContainsExpectedFormats() {
    let exact = VersionRange.exactly(Version(major: 92, minor: 0))
    #expect(exact.contains(Version(major: 92, minor: 0)))
    #expect(!exact.contains(Version(major: 95, minor: 0)))

    let range = VersionRange.between(Version(major: 94, minor: 1), Version(major: 95, minor: 0))
    #expect(!range.contains(Version(major: 94, minor: 0)))
    #expect(range.contains(Version(major: 94, minor: 1)))
    #expect(range.contains(Version(major: 95, minor: 0)))
    #expect(!range.contains(Version(major: 95, minor: 1)))
}

@Test func testDataPackUsesHighestDeclaredVersionByDefault() throws {
    let root = try makePackRoot(withPackMetadata: """
    {
        "pack": {
            "min_format": [94, 1],
            "max_format": 95,
            "description": "Test pack"
        }
    }
    """)
    defer { try? FileManager.default.removeItem(at: root) }

    let pack = try DataPack(fromRootPath: root, loadingOptions: [.noDensityFunctions, .noNoises, .noNoiseSettings, .noDimensions, .noBiomes, .noStructures, .noStructureSets, .noEnchantments])

    #expect(pack.packFormat == Version(major: 95, minor: 0))
    #expect(pack.versioning.supportedVersions == VersionRange.between(Version(major: 94, minor: 1), Version(major: 95, minor: 0)))
}

@Test func testDataPackAllowsExplicitSupportedDecodingVersion() throws {
    let root = try makePackRoot(withPackMetadata: """
    {
        "pack": {
            "min_format": [94, 1],
            "max_format": 95,
            "description": "Test pack"
        }
    }
    """)
    defer { try? FileManager.default.removeItem(at: root) }

    let pack = try DataPack(
        fromRootPath: root,
        loadingOptions: [.noDensityFunctions, .noNoises, .noNoiseSettings, .noDimensions, .noBiomes, .noStructures, .noStructureSets, .noEnchantments],
        decodingVersion: Version(major: 94, minor: 1)
    )

    #expect(pack.packFormat == Version(major: 94, minor: 1))
    #expect(pack.versioning.supportedVersions.contains(pack.packFormat))
}

@Test func testDataPackRejectsUnsupportedDecodingVersion() throws {
    let root = try makePackRoot(withPackMetadata: """
    {
        "pack": {
            "pack_format": 92,
            "description": "Test pack"
        }
    }
    """)
    defer { try? FileManager.default.removeItem(at: root) }

    do {
        _ = try DataPack(
            fromRootPath: root,
            loadingOptions: [.noDensityFunctions, .noNoises, .noNoiseSettings, .noDimensions, .noBiomes, .noStructures, .noStructureSets, .noEnchantments],
            decodingVersion: Version(major: 95, minor: 0)
        )
        Issue.record("Expected unsupported decoding version to be rejected")
    } catch let error as DataPack.LoadingErrors {
        guard case let .unsupportedPackVersion(selected, supported) = error else {
            Issue.record("Expected unsupportedPackVersion, got \(error)")
            return
        }
        #expect(selected == Version(major: 95, minor: 0))
        #expect(supported == VersionRange.exactly(Version(major: 92, minor: 0)))
    }
}
