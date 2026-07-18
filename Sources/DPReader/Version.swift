import Foundation

/// Versioning support.
///
/// Versions are based on the data pack format, which is supplied by datapacks.
/// A list of all valid formats along with corresponding Minecraft versions is
/// provided at https://minecraft.wiki/w/Pack_format#List_of_pack_formats.
/// For formats before 82.0, the minor version will always be 0.
public struct Version: Codable, Comparable, CustomStringConvertible, Hashable, Sendable {
    public static let assumedCurrent = Version(major: 92, minor: 0)

    public let major: Int
    public let minor: Int

    public init(major: Int, minor: Int) {
        self.major = major
        self.minor = minor
    }

    public var description: String {
        "\(major).\(minor)"
    }

    public static func < (lhs: Version, rhs: Version) -> Bool {
        (lhs.major, lhs.minor) < (rhs.major, rhs.minor)
    }

    public init(from decoder: Decoder) throws {
        if var unkeyed = try? decoder.unkeyedContainer() {
            let major = try unkeyed.decode(Int.self)
            let minor = try unkeyed.decodeIfPresent(Int.self) ?? 0
            self = Version(major: major, minor: minor)
            return
        }

        if let singleValue = try? decoder.singleValueContainer() {
            if let integer = try? singleValue.decode(Int.self) {
                self = Version(major: integer, minor: 0)
                return
            }
            if let decimal = try? singleValue.decode(Decimal.self) {
                self = try Version(parsing: NSDecimalNumber(decimal: decimal).stringValue)
                return
            }
            if let string = try? singleValue.decode(String.self) {
                self = try Version(parsing: string)
                return
            }
        }

        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.major = try container.decode(Int.self, forKey: .major)
        self.minor = try container.decodeIfPresent(Int.self, forKey: .minor) ?? 0
    }

    public func encode(to encoder: Encoder) throws {
        var singleValue = encoder.singleValueContainer()
        if minor == 0 {
            try singleValue.encode(major)
        } else {
            try singleValue.encode(description)
        }
    }

    private init(parsing rawValue: String) throws {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let components = trimmed.split(separator: ".", maxSplits: 1, omittingEmptySubsequences: false)

        guard
            let major = Int(components[0]),
            let minor = components.count == 2 ? Int(components[1]) : 0
        else {
            throw DecodingError.dataCorrupted(
                DecodingError.Context(codingPath: [], debugDescription: "Invalid version string: \(rawValue)")
            )
        }

        self.init(major: major, minor: minor)
    }

    private enum CodingKeys: String, CodingKey {
        case major
        case minor
    }
}

/// A supported range of data-pack formats.
public struct VersionRange: Hashable, Sendable, CustomStringConvertible {
    public let minimum: Version?
    public let maximum: Version?

    public init(minimum: Version? = nil, maximum: Version? = nil) {
        precondition(minimum == nil || maximum == nil || minimum! <= maximum!, "Invalid version range")
        self.minimum = minimum
        self.maximum = maximum
    }

    public static func exactly(_ version: Version) -> VersionRange {
        VersionRange(minimum: version, maximum: version)
    }

    public static func atLeast(_ version: Version) -> VersionRange {
        VersionRange(minimum: version, maximum: nil)
    }

    public static func atMost(_ version: Version) -> VersionRange {
        VersionRange(minimum: nil, maximum: version)
    }

    public static func between(_ minimum: Version, _ maximum: Version) -> VersionRange {
        VersionRange(minimum: minimum, maximum: maximum)
    }

    public func contains(_ version: Version) -> Bool {
        if let minimum, version < minimum {
            return false
        }
        if let maximum, version > maximum {
            return false
        }
        return true
    }

    public var description: String {
        switch (minimum, maximum) {
        case let (minimum?, maximum?) where minimum == maximum:
            return minimum.description
        case let (minimum?, maximum?):
            return "\(minimum)...\(maximum)"
        case let (minimum?, nil):
            return "\(minimum)+"
        case let (nil, maximum?):
            return "...\(maximum)"
        case (nil, nil):
            return "all versions"
        }
    }
}

/// The declared and selected pack format used during decoding.
public struct PackVersioning: Hashable, Sendable {
    public let supportedVersions: VersionRange
    public let selectedVersion: Version

    public static let assumedCurrent = PackVersioning(
        supportedVersions: .exactly(.assumedCurrent),
        selectedVersion: .assumedCurrent
    )

    public init(supportedVersions: VersionRange, selectedVersion: Version) {
        precondition(
            supportedVersions.contains(selectedVersion),
            "Selected version \(selectedVersion) is outside supported range \(supportedVersions)"
        )
        self.supportedVersions = supportedVersions
        self.selectedVersion = selectedVersion
    }
}

/// A named schema feature whose availability depends on the pack format.
public struct VersionedSchemaFeature: Hashable, Sendable {
    public let name: String
    public let supportedVersions: VersionRange

    public init(_ name: String, supportedVersions: VersionRange) {
        self.name = name
        self.supportedVersions = supportedVersions
    }
}

extension CodingUserInfoKey {
    static let dpReaderVersioning = CodingUserInfoKey(rawValue: "net.picawawa.dpreader.versioning")!
    static let dpReaderPackFormat = CodingUserInfoKey(rawValue: "net.picawawa.dpreader.packFormat")!
}

extension JSONDecoder {
    func setDPReaderVersioning(_ versioning: PackVersioning) {
        userInfo[.dpReaderVersioning] = versioning
        userInfo[.dpReaderPackFormat] = versioning.selectedVersion
    }
}

extension Decoder {
    var dpReaderVersioning: PackVersioning {
        if let versioning = userInfo[.dpReaderVersioning] as? PackVersioning {
            return versioning
        }
        if let packFormat = userInfo[.dpReaderPackFormat] as? Version {
            return PackVersioning(supportedVersions: .exactly(packFormat), selectedVersion: packFormat)
        }
        return .assumedCurrent
    }

    var dpReaderPackFormat: Version {
        dpReaderVersioning.selectedVersion
    }

    func requirePackVersions(_ supportedVersions: VersionRange, for feature: String) throws {
        let packFormat = dpReaderPackFormat
        guard supportedVersions.contains(packFormat) else {
            throw DecodingError.dataCorrupted(
                DecodingError.Context(
                    codingPath: codingPath,
                    debugDescription: "\(feature) is unavailable in pack format \(packFormat); supported versions: \(supportedVersions)"
                )
            )
        }
    }

    func require(_ feature: VersionedSchemaFeature) throws {
        try requirePackVersions(feature.supportedVersions, for: feature.name)
    }
}
