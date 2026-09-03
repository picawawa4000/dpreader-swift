import Foundation

/// A decoded `worldgen/template_pool` entry used by jigsaw structures.
public struct StructureTemplatePool: Decodable {
    public let fallback: String
    public let elements: [WeightedStructurePoolElement]

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.fallback = addDefaultNamespace(try container.decode(String.self, forKey: .fallback))
        self.elements = try container.decode([WeightedStructurePoolElement].self, forKey: .elements)
    }

    private enum CodingKeys: String, CodingKey { case fallback, elements }
}

public struct WeightedStructurePoolElement: Decodable {
    public let element: StructurePoolElement
    public let weight: Int

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.element = try container.decode(StructurePoolElement.self, forKey: .element)
        self.weight = try container.decode(Int.self, forKey: .weight)
        guard (1...150).contains(self.weight) else {
            throw DecodingError.dataCorruptedError(forKey: .weight, in: container, debugDescription: "Structure-pool weights must be in 1...150")
        }
    }

    private enum CodingKeys: String, CodingKey { case element, weight }
}

public enum StructurePoolProjection: String, Decodable {
    case rigid
    case terrainMatching = "terrain_matching"
}

/// Data-driven pool elements understood by vanilla's jigsaw assembler.
public indirect enum StructurePoolElement: Decodable {
    case single(
        location: String,
        processors: StructureProcessorListReference?,
        projection: StructurePoolProjection,
        legacy: Bool,
        overrideLiquidSettings: String? = nil
    )
    case list(elements: [StructurePoolElement], projection: StructurePoolProjection)
    case feature(projection: StructurePoolProjection)
    case empty

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let type = addDefaultNamespace(try c.decode(String.self, forKey: .elementType))
        switch type {
        case "minecraft:single_pool_element", "minecraft:legacy_single_pool_element":
            let overrideLiquidSettings = try c.decodeIfPresent(String.self, forKey: .overrideLiquidSettings)
            if c.contains(.overrideLiquidSettings) {
                try decoder.requirePackVersions(.atLeast(.init(major: 46, minor: 0)), for: "single pool element override_liquid_settings")
            }
            if let overrideLiquidSettings,
               overrideLiquidSettings != "apply_waterlogging" && overrideLiquidSettings != "ignore_waterlogging" {
                throw DecodingError.dataCorruptedError(
                    forKey: .overrideLiquidSettings,
                    in: c,
                    debugDescription: "override_liquid_settings must be apply_waterlogging or ignore_waterlogging"
                )
            }
            self = .single(
                location: addDefaultNamespace(try c.decode(String.self, forKey: .location)),
                processors: try c.decodeIfPresent(StructureProcessorListReference.self, forKey: .processors),
                projection: try c.decode(StructurePoolProjection.self, forKey: .projection),
                legacy: type == "minecraft:legacy_single_pool_element",
                overrideLiquidSettings: overrideLiquidSettings
            )
        case "minecraft:list_pool_element":
            let projection = try c.decode(StructurePoolProjection.self, forKey: .projection)
            self = .list(elements: try c.decode([StructurePoolElement].self, forKey: .elements).map { $0.withProjection(projection) }, projection: projection)
        case "minecraft:feature_pool_element":
            self = .feature(projection: try c.decode(StructurePoolProjection.self, forKey: .projection))
        case "minecraft:empty_pool_element":
            self = .empty
        default:
            throw DecodingError.dataCorruptedError(forKey: .elementType, in: c, debugDescription: "Unknown structure pool element type: \(type)")
        }
    }

    var projection: StructurePoolProjection {
        switch self {
        case .single(_, _, let projection, _, _), .list(_, let projection), .feature(let projection): return projection
        case .empty: return .rigid
        }
    }

    var groundLevelDelta: Int32 { 1 }

    var templateLocations: [String] {
        switch self {
        case .single(let location, _, _, _, _): return [location]
        case .list(let elements, _): return elements.flatMap(\.templateLocations)
        case .feature, .empty: return []
        }
    }

    private func withProjection(_ projection: StructurePoolProjection) -> StructurePoolElement {
        switch self {
        case .single(let location, let processors, _, let legacy, let overrideLiquidSettings):
            return .single(
                location: location,
                processors: processors,
                projection: projection,
                legacy: legacy,
                overrideLiquidSettings: overrideLiquidSettings
            )
        case .list(let elements, _):
            return .list(elements: elements.map { $0.withProjection(projection) }, projection: projection)
        case .feature: return .feature(projection: projection)
        case .empty: return .empty
        }
    }

    var overrideLiquidSettings: String? {
        if case .single(_, _, _, _, let value) = self { return value }
        return nil
    }

    private enum CodingKeys: String, CodingKey {
        case elementType = "element_type", location, processors, projection, elements
        case overrideLiquidSettings = "override_liquid_settings"
    }
}

/// Processor lists can be an inline object or a registry identifier.
public enum StructureProcessorListReference: Decodable {
    case registry(String)
    case inline

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let value = try? container.decode(String.self) {
            self = .registry(addDefaultNamespace(value))
        } else {
            self = .inline
        }
    }
}
