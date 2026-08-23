import Foundation

/// A constant, uniform, or trapezoidal floating-point distribution used by carvers.
public enum CarverFloatProvider: Codable, Equatable {
    case constant(Float)
    case uniform(minInclusive: Float, maxExclusive: Float)
    case trapezoid(min: Float, max: Float, plateau: Float)
    case clampedNormal(mean: Float, deviation: Float, min: Float, max: Float)

    public init(from decoder: any Decoder) throws {
        if let single = try? decoder.singleValueContainer(), let value = try? single.decode(Float.self) {
            self = .constant(value)
            return
        }
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch addDefaultNamespace(try container.decode(String.self, forKey: .type)) {
        case "minecraft:constant": self = .constant(try container.decode(Float.self, forKey: .value))
        case "minecraft:uniform": self = .uniform(
            minInclusive: try container.decode(Float.self, forKey: .minInclusive),
            maxExclusive: try container.decode(Float.self, forKey: .maxExclusive)
        )
        case "minecraft:trapezoid": self = .trapezoid(
            min: try container.decode(Float.self, forKey: .min),
            max: try container.decode(Float.self, forKey: .max),
            plateau: try container.decode(Float.self, forKey: .plateau)
        )
        case "minecraft:clamped_normal": self = .clampedNormal(
            mean: try container.decode(Float.self, forKey: .mean),
            deviation: try container.decode(Float.self, forKey: .deviation),
            min: try container.decode(Float.self, forKey: .min),
            max: try container.decode(Float.self, forKey: .max)
        )
        default:
            throw DecodingError.dataCorruptedError(forKey: .type, in: container, debugDescription: "Unsupported carver float provider")
        }
    }

    public func encode(to encoder: any Encoder) throws {
        switch self {
        case .constant(let value):
            var container = encoder.singleValueContainer(); try container.encode(value)
        case .uniform(let min, let max):
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode("minecraft:uniform", forKey: .type)
            try container.encode(min, forKey: .minInclusive); try container.encode(max, forKey: .maxExclusive)
        case .trapezoid(let min, let max, let plateau):
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode("minecraft:trapezoid", forKey: .type)
            try container.encode(min, forKey: .min); try container.encode(max, forKey: .max); try container.encode(plateau, forKey: .plateau)
        case .clampedNormal(let mean, let deviation, let min, let max):
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode("minecraft:clamped_normal", forKey: .type)
            try container.encode(mean, forKey: .mean); try container.encode(deviation, forKey: .deviation)
            try container.encode(min, forKey: .min); try container.encode(max, forKey: .max)
        }
    }

    mutating func sample(random: inout CheckedRandom) -> Float {
        switch self {
        case .constant(let value): return value
        case .uniform(let min, let max): return min + random.nextFloat() * (max - min)
        case .trapezoid(let min, let max, let plateau):
            let span = max - min
            let slope = (span - plateau) / 2
            return min + random.nextFloat() * (span - slope) + random.nextFloat() * slope
        case .clampedNormal(let mean, let deviation, let min, let max):
            let u1 = Swift.max(Double.leastNonzeroMagnitude, random.nextDouble())
            let gaussian = sqrt(-2 * log(u1)) * cos(2 * Double.pi * random.nextDouble())
            return Swift.min(max, Swift.max(min, mean + deviation * Float(gaussian)))
        }
    }

    private enum CodingKeys: String, CodingKey {
        case type, value, min, max, plateau, mean, deviation
        case minInclusive = "min_inclusive"
        case maxExclusive = "max_exclusive"
    }
}

/// A constant or uniform vertical distribution used to select a carver origin.
public indirect enum CarverHeightProvider: Codable, Equatable {
    case constant(VerticalAnchor)
    case uniform(minInclusive: VerticalAnchor, maxInclusive: VerticalAnchor)
    case biasedToBottom(minInclusive: VerticalAnchor, maxInclusive: VerticalAnchor, inner: Int)
    case veryBiasedToBottom(minInclusive: VerticalAnchor, maxInclusive: VerticalAnchor, inner: Int)
    case trapezoid(minInclusive: VerticalAnchor, maxInclusive: VerticalAnchor, plateau: Int)
    case weightedList([WeightedEntry])

    public struct WeightedEntry: Codable, Equatable {
        public let data: CarverHeightProvider
        public let weight: Int

        public init(data: CarverHeightProvider, weight: Int) { self.data = data; self.weight = weight }
    }

    public init(from decoder: any Decoder) throws {
        if let anchor = try? VerticalAnchor(from: decoder) { self = .constant(anchor); return }
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch addDefaultNamespace(try container.decode(String.self, forKey: .type)) {
        case "minecraft:constant": self = .constant(try container.decode(VerticalAnchor.self, forKey: .value))
        case "minecraft:uniform": self = .uniform(
            minInclusive: try container.decode(VerticalAnchor.self, forKey: .minInclusive),
            maxInclusive: try container.decode(VerticalAnchor.self, forKey: .maxInclusive)
        )
        case "minecraft:biased_to_bottom": self = .biasedToBottom(
            minInclusive: try container.decode(VerticalAnchor.self, forKey: .minInclusive),
            maxInclusive: try container.decode(VerticalAnchor.self, forKey: .maxInclusive),
            inner: try container.decodeIfPresent(Int.self, forKey: .inner) ?? 1
        )
        case "minecraft:very_biased_to_bottom": self = .veryBiasedToBottom(
            minInclusive: try container.decode(VerticalAnchor.self, forKey: .minInclusive),
            maxInclusive: try container.decode(VerticalAnchor.self, forKey: .maxInclusive),
            inner: try container.decodeIfPresent(Int.self, forKey: .inner) ?? 1
        )
        case "minecraft:trapezoid": self = .trapezoid(
            minInclusive: try container.decode(VerticalAnchor.self, forKey: .minInclusive),
            maxInclusive: try container.decode(VerticalAnchor.self, forKey: .maxInclusive),
            plateau: try container.decodeIfPresent(Int.self, forKey: .plateau) ?? 0
        )
        case "minecraft:weighted_list": self = .weightedList(try container.decode([WeightedEntry].self, forKey: .distribution))
        default:
            throw DecodingError.dataCorruptedError(forKey: .type, in: container, debugDescription: "Unsupported carver height provider")
        }
    }

    public func encode(to encoder: any Encoder) throws {
        switch self {
        case .constant(let value): try value.encode(to: encoder)
        case .uniform(let min, let max):
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode("minecraft:uniform", forKey: .type)
            try container.encode(min, forKey: .minInclusive); try container.encode(max, forKey: .maxInclusive)
        case .biasedToBottom(let min, let max, let inner):
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode("minecraft:biased_to_bottom", forKey: .type)
            try container.encode(min, forKey: .minInclusive); try container.encode(max, forKey: .maxInclusive)
            try container.encode(inner, forKey: .inner)
        case .veryBiasedToBottom(let min, let max, let inner):
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode("minecraft:very_biased_to_bottom", forKey: .type)
            try container.encode(min, forKey: .minInclusive); try container.encode(max, forKey: .maxInclusive)
            try container.encode(inner, forKey: .inner)
        case .trapezoid(let min, let max, let plateau):
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode("minecraft:trapezoid", forKey: .type)
            try container.encode(min, forKey: .minInclusive); try container.encode(max, forKey: .maxInclusive)
            try container.encode(plateau, forKey: .plateau)
        case .weightedList(let entries):
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode("minecraft:weighted_list", forKey: .type)
            try container.encode(entries, forKey: .distribution)
        }
    }

    func sample(random: inout CheckedRandom, minY: Int32, height: Int32) -> Int32 {
        switch self {
        case .constant(let anchor): return Self.resolve(anchor, minY: minY, height: height)
        case .uniform(let lower, let upper):
            let minValue = Self.resolve(lower, minY: minY, height: height)
            let maxValue = Self.resolve(upper, minY: minY, height: height)
            guard maxValue > minValue else { return minValue }
            return minValue + Int32(random.next(bound: UInt32(maxValue - minValue + 1)))
        case .biasedToBottom(let lower, let upper, let inner):
            let minValue = Self.resolve(lower, minY: minY, height: height)
            let maxValue = Self.resolve(upper, minY: minY, height: height)
            let outerBound = Int(maxValue - minValue) - inner + 1
            guard outerBound > 0 else { return minValue }
            let nestedBound = Int(random.next(bound: UInt32(outerBound))) + inner
            return minValue + Int32(random.next(bound: UInt32(nestedBound)))
        case .veryBiasedToBottom(let lower, let upper, let inner):
            let minValue = Self.resolve(lower, minY: minY, height: height)
            let maxValue = Self.resolve(upper, minY: minY, height: height)
            guard maxValue - minValue - Int32(inner) + 1 > 0 else { return minValue }
            let high = Self.nextInclusive(random: &random, min: minValue + Int32(inner), max: maxValue)
            let middle = Self.nextInclusive(random: &random, min: minValue, max: high - 1)
            return Self.nextInclusive(random: &random, min: minValue, max: middle - 1 + Int32(inner))
        case .trapezoid(let lower, let upper, let plateau):
            let minValue = Self.resolve(lower, minY: minY, height: height)
            let maxValue = Self.resolve(upper, minY: minY, height: height)
            let span = Int(maxValue - minValue)
            guard span >= 0 else { return minValue }
            if plateau >= span { return Self.nextInclusive(random: &random, min: minValue, max: maxValue) }
            let lowerSlope = (span - plateau) / 2
            let upperSlope = span - lowerSlope
            return minValue
                + Int32(random.next(bound: UInt32(upperSlope + 1)))
                + Int32(random.next(bound: UInt32(lowerSlope + 1)))
        case .weightedList(let entries):
            let total = entries.reduce(0) { $0 + max(0, $1.weight) }
            guard total > 0 else { return minY }
            var selection = Int(random.next(bound: UInt32(total)))
            for entry in entries where entry.weight > 0 {
                if selection < entry.weight { return entry.data.sample(random: &random, minY: minY, height: height) }
                selection -= entry.weight
            }
            return minY
        }
    }

    static func resolve(_ anchor: VerticalAnchor, minY: Int32, height: Int32) -> Int32 {
        switch anchor {
        case .absolute(let value): return Int32(value)
        case .aboveBottom(let value): return minY + Int32(value)
        case .belowTop(let value): return minY + height - 1 - Int32(value)
        }
    }

    private static func nextInclusive(random: inout CheckedRandom, min: Int32, max: Int32) -> Int32 {
        guard max > min else { return min }
        return min + Int32(random.next(bound: UInt32(max - min + 1)))
    }

    private enum CodingKeys: String, CodingKey {
        case type, value, inner, plateau, distribution
        case minInclusive = "min_inclusive"
        case maxInclusive = "max_inclusive"
    }
}

/// Debug block substitutions for visualizing carved volumes.
public struct CarverDebugSettings: Codable, Equatable {
    public let debugMode: Bool
    public let airState: BlockStateDefinition
    public let waterState: BlockStateDefinition
    public let lavaState: BlockStateDefinition
    public let barrierState: BlockStateDefinition

    public init(
        debugMode: Bool = false,
        airState: BlockStateDefinition = .init(name: "minecraft:acacia_button"),
        waterState: BlockStateDefinition = .init(name: "minecraft:candle"),
        lavaState: BlockStateDefinition = .init(name: "minecraft:orange_stained_glass"),
        barrierState: BlockStateDefinition = .init(name: "minecraft:glass")
    ) {
        self.debugMode = debugMode; self.airState = airState; self.waterState = waterState
        self.lavaState = lavaState; self.barrierState = barrierState
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.debugMode = try container.decodeIfPresent(Bool.self, forKey: .debugMode) ?? false
        self.airState = try container.decodeIfPresent(BlockStateDefinition.self, forKey: .airState) ?? .init(name: "minecraft:acacia_button")
        self.waterState = try container.decodeIfPresent(BlockStateDefinition.self, forKey: .waterState) ?? .init(name: "minecraft:candle")
        self.lavaState = try container.decodeIfPresent(BlockStateDefinition.self, forKey: .lavaState) ?? .init(name: "minecraft:orange_stained_glass")
        self.barrierState = try container.decodeIfPresent(BlockStateDefinition.self, forKey: .barrierState) ?? .init(name: "minecraft:glass")
    }

    private enum CodingKeys: String, CodingKey {
        case debugMode = "debug_mode", airState = "air_state", waterState = "water_state"
        case lavaState = "lava_state", barrierState = "barrier_state"
    }
}

/// Fields shared by cave and canyon carver configurations.
public struct CarverConfig: Codable, Equatable {
    public let probability: Float
    public var y: CarverHeightProvider
    public var yScale: CarverFloatProvider
    public let lavaLevel: VerticalAnchor
    public let debugSettings: CarverDebugSettings
    public let replaceable: String

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.probability = try container.decode(Float.self, forKey: .probability)
        self.y = try container.decode(CarverHeightProvider.self, forKey: .y)
        self.yScale = try container.decode(CarverFloatProvider.self, forKey: .yScale)
        self.lavaLevel = try container.decode(VerticalAnchor.self, forKey: .lavaLevel)
        self.debugSettings = try container.decodeIfPresent(CarverDebugSettings.self, forKey: .debugSettings) ?? CarverDebugSettings()
        self.replaceable = try container.decode(String.self, forKey: .replaceable)
    }

    private enum CodingKeys: String, CodingKey {
        case probability, y, replaceable
        case yScale = "yScale", lavaLevel = "lava_level", debugSettings = "debug_settings"
    }
}

/// A configured cave or nether-cave carver.
public struct CaveCarverConfig: Codable, Equatable {
    public var base: CarverConfig
    public var horizontalRadiusMultiplier: CarverFloatProvider
    public var verticalRadiusMultiplier: CarverFloatProvider
    public var floorLevel: CarverFloatProvider

    public init(from decoder: any Decoder) throws {
        self.base = try CarverConfig(from: decoder)
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.horizontalRadiusMultiplier = try container.decode(CarverFloatProvider.self, forKey: .horizontalRadiusMultiplier)
        self.verticalRadiusMultiplier = try container.decode(CarverFloatProvider.self, forKey: .verticalRadiusMultiplier)
        self.floorLevel = try container.decode(CarverFloatProvider.self, forKey: .floorLevel)
    }

    public func encode(to encoder: any Encoder) throws {
        try self.base.encode(to: encoder)
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(horizontalRadiusMultiplier, forKey: .horizontalRadiusMultiplier)
        try container.encode(verticalRadiusMultiplier, forKey: .verticalRadiusMultiplier)
        try container.encode(floorLevel, forKey: .floorLevel)
    }

    private enum CodingKeys: String, CodingKey {
        case horizontalRadiusMultiplier = "horizontal_radius_multiplier"
        case verticalRadiusMultiplier = "vertical_radius_multiplier"
        case floorLevel = "floor_level"
    }
}

/// Shape controls unique to the canyon carver.
public struct RavineCarverShape: Codable, Equatable {
    public var distanceFactor: CarverFloatProvider
    public var thickness: CarverFloatProvider
    public let widthSmoothness: Int
    public var horizontalRadiusFactor: CarverFloatProvider
    public let verticalRadiusDefaultFactor: Float
    public let verticalRadiusCenterFactor: Float

    private enum CodingKeys: String, CodingKey {
        case distanceFactor = "distance_factor", thickness, widthSmoothness = "width_smoothness"
        case horizontalRadiusFactor = "horizontal_radius_factor"
        case verticalRadiusDefaultFactor = "vertical_radius_default_factor"
        case verticalRadiusCenterFactor = "vertical_radius_center_factor"
    }
}

/// A configured canyon carver.
public struct RavineCarverConfig: Codable, Equatable {
    public var base: CarverConfig
    public var verticalRotation: CarverFloatProvider
    public var shape: RavineCarverShape

    public init(from decoder: any Decoder) throws {
        self.base = try CarverConfig(from: decoder)
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.verticalRotation = try container.decode(CarverFloatProvider.self, forKey: .verticalRotation)
        self.shape = try container.decode(RavineCarverShape.self, forKey: .shape)
    }

    public func encode(to encoder: any Encoder) throws {
        try self.base.encode(to: encoder)
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(verticalRotation, forKey: .verticalRotation); try container.encode(shape, forKey: .shape)
    }

    private enum CodingKeys: String, CodingKey { case verticalRotation = "vertical_rotation", shape }
}

/// A data-pack configured cave, nether cave, or canyon carver.
public enum ConfiguredCarver: Codable, Equatable {
    case cave(CaveCarverConfig)
    case netherCave(CaveCarverConfig)
    case canyon(RavineCarverConfig)

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch addDefaultNamespace(try container.decode(String.self, forKey: .type)) {
        case "minecraft:cave": self = .cave(try container.decode(CaveCarverConfig.self, forKey: .config))
        case "minecraft:nether_cave": self = .netherCave(try container.decode(CaveCarverConfig.self, forKey: .config))
        case "minecraft:canyon": self = .canyon(try container.decode(RavineCarverConfig.self, forKey: .config))
        default: throw DecodingError.dataCorruptedError(forKey: .type, in: container, debugDescription: "Unknown configured carver type")
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .cave(let config): try container.encode("minecraft:cave", forKey: .type); try container.encode(config, forKey: .config)
        case .netherCave(let config): try container.encode("minecraft:nether_cave", forKey: .type); try container.encode(config, forKey: .config)
        case .canyon(let config): try container.encode("minecraft:canyon", forKey: .type); try container.encode(config, forKey: .config)
        }
    }

    var base: CarverConfig {
        switch self { case .cave(let c), .netherCave(let c): return c.base; case .canyon(let c): return c.base }
    }

    private enum CodingKeys: String, CodingKey { case type, config }
}

struct CarvingMask {
    private let minY: Int32
    private var words: [UInt64]

    init(minY: Int32, height: Int32) {
        self.minY = minY
        self.words = [UInt64](repeating: 0, count: Int(height) * 4)
    }

    mutating func insert(x: Int32, y: Int32, z: Int32) -> Bool {
        let index = Int(x & 15) | (Int(z & 15) << 4) | (Int(y - minY) << 8)
        guard index >= 0 && index >> 6 < words.count else { return false }
        let word = index >> 6
        let bit = UInt64(1) << UInt64(index & 63)
        let wasSet = words[word] & bit != 0
        words[word] |= bit
        return !wasSet
    }
}

final class CarverApplicator {
    private let replaceable: (String, String) -> Bool

    init(replaceable: @escaping (String, String) -> Bool) { self.replaceable = replaceable }

    func apply(
        _ configured: [(ConfiguredCarver, Int)],
        to chunk: ProtoChunk,
        targetChunkPos: PosInt2D,
        sourceChunkPos: PosInt2D,
        worldSeed: WorldSeed,
        aquifer: AquiferSampler? = nil,
        mask: inout CarvingMask
    ) {
        for (carver, index) in configured {
            var random = Self.carverRandom(seed: worldSeed &+ UInt64(index), chunkPos: sourceChunkPos)
            guard random.nextFloat() <= carver.base.probability else { continue }
            switch carver {
            case .cave(var config):
                self.carveCaves(config: &config, nether: false, chunk: chunk, target: targetChunkPos, source: sourceChunkPos, random: &random, aquifer: aquifer, mask: &mask)
            case .netherCave(var config):
                self.carveCaves(config: &config, nether: true, chunk: chunk, target: targetChunkPos, source: sourceChunkPos, random: &random, aquifer: aquifer, mask: &mask)
            case .canyon(var config):
                self.carveRavine(config: &config, chunk: chunk, target: targetChunkPos, source: sourceChunkPos, random: &random, aquifer: aquifer, mask: &mask)
            }
        }
    }

    private static func carverRandom(seed: WorldSeed, chunkPos: PosInt2D) -> CheckedRandom {
        var random = CheckedRandom(seed: seed)
        let xMultiplier = random.nextLong()
        let zMultiplier = random.nextLong()
        let mixed = (UInt64(bitPattern: Int64(chunkPos.x)) &* xMultiplier)
            ^ (UInt64(bitPattern: Int64(chunkPos.z)) &* zMultiplier) ^ seed
        return CheckedRandom(seed: mixed)
    }

    private func carveCaves(
        config: inout CaveCarverConfig, nether: Bool, chunk: ProtoChunk, target: PosInt2D, source: PosInt2D,
        random: inout CheckedRandom, aquifer: AquiferSampler?, mask: inout CarvingMask
    ) {
        let branchCount = 112
        let maxCaves = nether ? 10 : 15
        let count = Int(random.next(bound: random.next(bound: random.next(bound: UInt32(maxCaves)) + 1) + 1))
        for _ in 0..<count {
            let startX = Double(source.x * 16 + Int32(random.next(bound: 16)))
            let startY = Double(config.base.y.sample(random: &random, minY: chunk.minY, height: chunk.height))
            let startZ = Double(source.z * 16 + Int32(random.next(bound: 16)))
            let horizontal = Double(config.horizontalRadiusMultiplier.sample(random: &random))
            let vertical = Double(config.verticalRadiusMultiplier.sample(random: &random))
            let floor = Double(config.floorLevel.sample(random: &random))
            var tunnels = 1
            if random.next(bound: 4) == 0 {
                let yScale = Double(config.base.yScale.sample(random: &random))
                let width = 1 + random.nextFloat() * 6
                let radius = 1.5 + sin(Double.pi / 2) * Double(width)
                self.carveRegion(config: config.base, nether: nether, chunk: chunk, target: target, x: startX + 1, y: startY, z: startZ, width: radius, height: radius * yScale, floor: floor, stretch: nil, aquifer: aquifer, mask: &mask)
                tunnels += Int(random.next(bound: 4))
            }
            for _ in 0..<tunnels {
                let yaw = random.nextFloat() * Float.pi * 2
                let pitch = (random.nextFloat() - 0.5) / 4
                var width = random.nextFloat() * 2 + random.nextFloat()
                if nether { width *= 2 }
                else if random.next(bound: 10) == 0 { width *= random.nextFloat() * random.nextFloat() * 3 + 1 }
                let length = branchCount - Int(random.next(bound: UInt32(branchCount / 4)))
                self.carveTunnel(config: config, nether: nether, chunk: chunk, target: target, seed: random.nextLong(), x: startX, y: startY, z: startZ, horizontal: horizontal, vertical: vertical, width: width, yaw: yaw, pitch: pitch, start: 0, count: length, ratio: nether ? 5 : 1, floor: floor, aquifer: aquifer, mask: &mask)
            }
        }
    }

    private func carveTunnel(
        config: CaveCarverConfig, nether: Bool, chunk: ProtoChunk, target: PosInt2D, seed: UInt64,
        x initialX: Double, y initialY: Double, z initialZ: Double, horizontal: Double, vertical: Double,
        width: Float, yaw initialYaw: Float, pitch initialPitch: Float, start: Int, count: Int, ratio: Double,
        floor: Double, aquifer: AquiferSampler?, mask: inout CarvingMask
    ) {
        var random = CheckedRandom(seed: seed)
        let split = Int(random.next(bound: UInt32(max(1, count / 2)))) + count / 4
        let largePitch = random.next(bound: 6) == 0
        var x = initialX, y = initialY, z = initialZ, yaw = initialYaw, pitch = initialPitch
        var yawOffset: Float = 0, pitchOffset: Float = 0
        for branch in start..<count {
            let radius = 1.5 + sin(Double.pi * Double(branch) / Double(count)) * Double(width)
            let verticalRadius = radius * ratio
            let distance = cos(Double(pitch))
            x += cos(Double(yaw)) * distance; y += sin(Double(pitch)); z += sin(Double(yaw)) * distance
            pitch *= largePitch ? 0.92 : 0.7; pitch += pitchOffset * 0.1; yaw += yawOffset * 0.1
            pitchOffset *= 0.9; yawOffset *= 0.75
            pitchOffset += (random.nextFloat() - random.nextFloat()) * random.nextFloat() * 2
            yawOffset += (random.nextFloat() - random.nextFloat()) * random.nextFloat() * 4
            if branch == split && width > 1 {
                let childSeed1 = random.nextLong()
                let childWidth1 = random.nextFloat() * 0.5 + 0.5
                self.carveTunnel(config: config, nether: nether, chunk: chunk, target: target, seed: childSeed1, x: x, y: y, z: z, horizontal: horizontal, vertical: vertical, width: childWidth1, yaw: yaw - Float.pi / 2, pitch: pitch / 3, start: branch, count: count, ratio: 1, floor: floor, aquifer: aquifer, mask: &mask)
                let childSeed2 = random.nextLong()
                let childWidth2 = random.nextFloat() * 0.5 + 0.5
                self.carveTunnel(config: config, nether: nether, chunk: chunk, target: target, seed: childSeed2, x: x, y: y, z: z, horizontal: horizontal, vertical: vertical, width: childWidth2, yaw: yaw + Float.pi / 2, pitch: pitch / 3, start: branch, count: count, ratio: 1, floor: floor, aquifer: aquifer, mask: &mask)
                return
            }
            if random.next(bound: 4) != 0 {
                guard Self.canCarveBranch(target: target, x: x, z: z, branch: branch, count: count, width: width) else { return }
                self.carveRegion(config: config.base, nether: nether, chunk: chunk, target: target, x: x, y: y, z: z, width: radius * horizontal, height: verticalRadius * vertical, floor: floor, stretch: nil, aquifer: aquifer, mask: &mask)
            }
        }
    }

    private func carveRavine(
        config: inout RavineCarverConfig, chunk: ProtoChunk, target: PosInt2D, source: PosInt2D,
        random: inout CheckedRandom, aquifer: AquiferSampler?, mask: inout CarvingMask
    ) {
        let maxLength = 112
        let startX = Double(source.x * 16 + Int32(random.next(bound: 16)))
        let startY = Double(config.base.y.sample(random: &random, minY: chunk.minY, height: chunk.height))
        let startZ = Double(source.z * 16 + Int32(random.next(bound: 16)))
        var yaw = random.nextFloat() * Float.pi * 2
        var pitch = config.verticalRotation.sample(random: &random)
        let yScale = Double(config.base.yScale.sample(random: &random))
        let width = config.shape.thickness.sample(random: &random)
        let count = Int(Float(maxLength) * config.shape.distanceFactor.sample(random: &random))
        var branchRandom = CheckedRandom(seed: random.nextLong())
        var stretch = [Float](repeating: 1, count: Int(chunk.height))
        var factor: Float = 1
        for index in stretch.indices {
            if index == 0 || branchRandom.next(bound: UInt32(config.shape.widthSmoothness)) == 0 {
                factor = 1 + branchRandom.nextFloat() * branchRandom.nextFloat()
            }
            stretch[index] = factor * factor
        }
        var x = startX, y = startY, z = startZ, yawOffset: Float = 0, pitchOffset: Float = 0
        for branch in 0..<count {
            var radius = 1.5 + sin(Double(branch) * .pi / Double(count)) * Double(width)
            var verticalRadius = radius * yScale
            radius *= Double(config.shape.horizontalRadiusFactor.sample(random: &branchRandom))
            let centerFactor = 1 - abs(0.5 - Float(branch) / Float(count)) * 2
            let scale = config.shape.verticalRadiusDefaultFactor + config.shape.verticalRadiusCenterFactor * centerFactor
            verticalRadius *= Double(scale * (0.75 + branchRandom.nextFloat() * 0.25))
            let distance = cos(Double(pitch)); x += cos(Double(yaw)) * distance; y += sin(Double(pitch)); z += sin(Double(yaw)) * distance
            pitch *= 0.7; pitch += pitchOffset * 0.05; yaw += yawOffset * 0.05
            pitchOffset *= 0.8; yawOffset *= 0.5
            pitchOffset += (branchRandom.nextFloat() - branchRandom.nextFloat()) * branchRandom.nextFloat() * 2
            yawOffset += (branchRandom.nextFloat() - branchRandom.nextFloat()) * branchRandom.nextFloat() * 4
            if branchRandom.next(bound: 4) != 0 {
                guard Self.canCarveBranch(target: target, x: x, z: z, branch: branch, count: count, width: width) else { return }
                self.carveRegion(config: config.base, nether: false, chunk: chunk, target: target, x: x, y: y, z: z, width: radius, height: verticalRadius, floor: -Double.greatestFiniteMagnitude, stretch: stretch, aquifer: aquifer, mask: &mask)
            }
        }
    }

    private func carveRegion(
        config: CarverConfig, nether: Bool, chunk: ProtoChunk, target: PosInt2D,
        x: Double, y: Double, z: Double, width: Double, height: Double, floor floorLimit: Double,
        stretch: [Float]?, aquifer: AquiferSampler?, mask: inout CarvingMask
    ) {
        guard width > 0, height > 0 else { return }
        let centerX = Double(target.x * 16 + 8), centerZ = Double(target.z * 16 + 8)
        let maximumDistance = 16 + width * 2
        guard abs(x - centerX) <= maximumDistance, abs(z - centerZ) <= maximumDistance else { return }
        let startX = max(Int32(floor(x - width)) - target.x * 16 - 1, 0)
        let endX = min(Int32(floor(x + width)) - target.x * 16, 15)
        let bottomY = max(Int32(floor(y - height)) - 1, chunk.minY + 1)
        let topY = min(Int32(floor(y + height)) + 1, chunk.minY + chunk.height - 8)
        let startZ = max(Int32(floor(z - width)) - target.z * 16 - 1, 0)
        let endZ = min(Int32(floor(z + width)) - target.z * 16, 15)
        guard startX <= endX, startZ <= endZ, topY > bottomY else { return }
        let lavaY = CarverHeightProvider.resolve(config.lavaLevel, minY: chunk.minY, height: chunk.height)
        for localX in startX...endX {
            let worldX = target.x * 16 + localX
            let dx = (Double(worldX) + 0.5 - x) / width
            for localZ in startZ...endZ {
                let worldZ = target.z * 16 + localZ
                let dz = (Double(worldZ) + 0.5 - z) / width
                if dx * dx + dz * dz >= 1 { continue }
                var worldY = topY
                while worldY > bottomY {
                    let dy = (Double(worldY) - 0.5 - y) / height
                    let excluded: Bool
                    if let stretch {
                        let index = Int(worldY - chunk.minY - 1)
                        excluded = index < 0 || index >= stretch.count || (dx * dx + dz * dz) * Double(stretch[index]) + dy * dy / 6 >= 1
                    } else {
                        excluded = dy <= floorLimit || dx * dx + dy * dy + dz * dz >= 1
                    }
                    if !excluded && mask.insert(x: localX, y: worldY, z: localZ) {
                        let local = PosInt3D(x: localX, y: worldY - chunk.minY, z: localZ)
                        let current = chunk.block(atLocal: local)
                        if self.replaceable(config.replaceable, current.type.id) {
                            if let replacement = self.carvedState(
                                config: config,
                                nether: nether,
                                position: PosInt3D(x: worldX, y: worldY, z: worldZ),
                                minimumY: chunk.minY,
                                lavaY: lavaY,
                                aquifer: aquifer
                            ) {
                                chunk.setBlock(replacement, atLocal: local)
                            }
                        }
                    }
                    worldY -= 1
                }
            }
        }
    }

    private func carvedState(
        config: CarverConfig,
        nether: Bool,
        position: PosInt3D,
        minimumY: Int32,
        lavaY: Int32,
        aquifer: AquiferSampler?
    ) -> BlockState? {
        let lava = BlockState(type: Block(withID: "minecraft:lava"))
        if nether { return position.y <= minimumY + 31 ? lava : Blocks.caveAirState }
        if position.y <= lavaY {
            return config.debugSettings.debugMode ? config.debugSettings.lavaState.blockState : lava
        }
        guard let aquifer else {
            return config.debugSettings.debugMode ? config.debugSettings.airState.blockState : Blocks.caveAirState
        }
        guard let sampled = aquifer.apply(at: position, density: 0) else {
            return config.debugSettings.debugMode ? config.debugSettings.barrierState.blockState : nil
        }
        guard config.debugSettings.debugMode else { return sampled }
        switch sampled.type.id {
        case "minecraft:water": return config.debugSettings.waterState.blockState
        case "minecraft:lava": return config.debugSettings.lavaState.blockState
        default: return config.debugSettings.airState.blockState
        }
    }

    private static func canCarveBranch(target: PosInt2D, x: Double, z: Double, branch: Int, count: Int, width: Float) -> Bool {
        let dx = x - Double(target.x * 16 + 8), dz = z - Double(target.z * 16 + 8)
        let remaining = Double(count - branch), radius = Double(width + 18)
        return dx * dx + dz * dz - remaining * remaining <= radius * radius
    }
}
