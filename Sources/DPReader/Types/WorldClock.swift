import Foundation

/// A data-driven world clock. In formats 97 through 107.1 the definition is
/// intentionally an empty object; the clock's mutable time belongs to a world.
public struct WorldClock: Codable, Equatable, Sendable {
    public init() {}

    public init(from decoder: Decoder) throws {
        try decoder.requirePackVersions(.atLeast(.init(major: 97, minor: 0)), for: "world_clock registry entries")
        let container = try decoder.container(keyedBy: WorldClockCodingKey.self)
        guard container.allKeys.isEmpty else {
            throw DecodingError.dataCorrupted(
                .init(codingPath: decoder.codingPath, debugDescription: "A world_clock definition must be an empty object")
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        _ = encoder.container(keyedBy: WorldClockCodingKey.self)
    }
}

private struct WorldClockCodingKey: CodingKey {
    let stringValue: String
    let intValue: Int? = nil
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { return nil }
}
