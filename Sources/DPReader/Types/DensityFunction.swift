import Foundation
import TestVisible

/// An abstraction for simple functions of noises that comprise the brunt of Minecraft's world generation.
/// More specifically, they are functions that convert positions into numbers based on the world seed.
/// To decode an arbitrary density function, see `DensityFunctionInitializer`.
public protocol DensityFunction: Codable {
    /// Samples this density function at the given position.
    /// This function is not particularly supported on raw density functions for a variety of reasons.
    /// It is best to use `bake` instead before sampling.
    func sample(at: PosInt3D) -> Double
    /// "Bake" this density function to prepare it for repeated usage.
    func bake(withBaker: DensityFunctionBaker) throws -> DensityFunction
}

/// "Bakes" a density function; that is, prepares it for proper usage.
public protocol DensityFunctionBaker {
    /// "Bakes" a noise definition; that is, converts it to a sampler ready for usage.
    func bake(noise: DensityFunctionNoise) throws -> BakedNoise
    /// "Bakes" a reference; that is, converts it to a non-reference density function.
    func bake(referenceDensityFunction: ReferenceDensityFunction) throws -> DensityFunction
    /// "Bakes" a cache marker; that is, converts it to an actual cache.
    func bake(cacheMarker: CacheMarker) throws -> DensityFunction
    /// "Bakes" a beardifier; that is, converts it to an actual beardifier.
    func bake(beardifier: BeardifierMarker) throws -> DensityFunction
    /// "Bakes" a simplex noise sampler; that is, initialises it with the world seed.
    func bake(simplexNoise: DensityFunctionSimplexNoise) throws -> DensityFunctionSimplexNoise
    /// "Bakes" an interpolated noise sampler; that is, initialises it with the world seed.
    func bake(interpolatedNoise: InterpolatedNoise) throws -> InterpolatedNoise
}

/// Represents a noise within a density function.
public protocol DensityFunctionNoise {
    var key: RegistryKey<NoiseDefinition> { get }

    func sample(x: Double, y: Double, z: Double) -> Double
}

/// An unsafe, unbaked noise.
public final class UnbakedNoise: DensityFunctionNoise {
    public let key: RegistryKey<NoiseDefinition>
    var defaultNoiseRegistry: Registry<NoiseDefinition>? = nil

    public init(fromKey key: RegistryKey<NoiseDefinition>) {
        self.key = key
    }

    public func setDefaultNoiseRegistry(_ registry: Registry<NoiseDefinition>) {
        self.defaultNoiseRegistry = registry
    }

    public func sample(x: Double, y: Double, z: Double) -> Double {
        print("WARNING: Deprecated function UnbakedNoise.sample(x:y:z:) called! Maybe a noise wasn't baked?")
        guard let noise = self.defaultNoiseRegistry?.get(self.key) else {
            print("WARNING: Uninitialised noise in density function referencing noise key \(self.key.name). Returning 0.0.")
            // Bizarrely, this is vanilla behaviour.
            return 0.0
        }
        // This is not vanilla behaviour, but it's a close approximation that doesn't force
        // `DensityFunction::sample(pos:)` to be marked with `throws`.
        let optionalRet = try? noise.sample(x: x, y: y, z: z)
        if let ret = optionalRet {
            return ret
        } else {
            print("WARNING: Error in noise sampling for density function (was a seed not set?) Returning 0.0.")
            return 0.0
        }
    }
}

public final class BakedNoise: DensityFunctionNoise {
    public let key: RegistryKey<NoiseDefinition>
    let sampler: DoublePerlinNoise

    public init(fromKey key: RegistryKey<NoiseDefinition>, withSampler sampler: DoublePerlinNoise) {
        self.key = key
        self.sampler = sampler
    }

    public func sample(x: Double, y: Double, z: Double) -> Double {
        return self.sampler.sample(x: x, y: y, z: z)
    }
}

/// Represents a simplex noise within a density function.
/// Only relevant for `EndIslandsDensityFunction`.
public struct DensityFunctionSimplexNoise {
    var noise: SimplexNoise
    // For debugging.
    var isBaked: Bool

    init() {
        // This is one of those weird cases where this is vanilla behaviour, although it's highly unexpected.
        var tempRandom = CheckedRandom(seed: 0)
        self.noise = SimplexNoise(random: &tempRandom)
        self.isBaked = false
    }

    init(withRandom random: inout any Random) {
        random.skip(calls: 17292)
        self.noise = SimplexNoise(random: &random)
        self.isBaked = true
    }

    func sample(x: Double, y: Double) -> Double {
        if (!self.isBaked) { print("WARNING: Unbaked DensityFunctionSimplexNoise sampled!") }
        return self.noise.sample(x: x, y: y)
    }
}

/// A density function that references another density function via a namespaced ID.
@TestVisible(property: "testingAttributes") public final class ReferenceDensityFunction: DensityFunction {
    public let targetKey: RegistryKey<DensityFunction>
    private var densityFunctionRegistry: Registry<DensityFunction>? = nil

    public init(target: String) {
        self.targetKey = RegistryKey<DensityFunction>(referencing: target)
    }

    public init(targetKey: RegistryKey<DensityFunction>) {
        self.targetKey = targetKey
    }

    public init(from decoder: Decoder) throws {
        let singleValueContainer = try decoder.singleValueContainer()
        self.targetKey = try RegistryKey<DensityFunction>(referencing: singleValueContainer.decode(String.self))
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(self.targetKey.name)
    }

    internal func setDensityFunctionRegistry(_ registry: Registry<DensityFunction>) {
        self.densityFunctionRegistry = registry
    }

    public func sample(at pos: PosInt3D) -> Double {
        print("WARNING: Deprecated function ReferenceDensityFunction.sample(pos:) called!")
        guard let registry = self.densityFunctionRegistry else {
            print("WARNING: No density function registry provided to ReferenceDensityFunction! Returning 0.0.")
            return 0.0
        }
        return registry.get(self.targetKey)!.sample(at: pos)
    }

    public func bake(withBaker baker: any DensityFunctionBaker) throws -> any DensityFunction {
        return try baker.bake(referenceDensityFunction: self)
    }
}

/// A density function that always returns the same value.
@TestVisible(property: "testingAttributes") public final class ConstantDensityFunction: DensityFunction {
    private let value: Double

    public init(value: Double) {
        self.value = value
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(self.value)
    }

    public func sample(at pos: PosInt3D) -> Double {
        return self.value
    }

    public func bake(withBaker baker: any DensityFunctionBaker) -> any DensityFunction {
        return self
    }
}

/// A density function that performs one of multiple numerical operations
/// on the output of another density function.
@TestVisible(property: "testingAttributes") public final class UnaryDensityFunction: DensityFunction {
    private let operand: DensityFunction
    private let operation: OperationType

    public init(operand: DensityFunction, type: OperationType) {
        self.operand = operand
        self.operation = type
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.operand = try container.decode(DensityFunctionInitializer.self, forKey: .operand).value
        self.operation = try container.decode(OperationType.self, forKey: .operation)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(self.operand, forKey: .operand)
        try container.encode(self.operation.rawValue, forKey: .operation)
    }

    public func sample(at pos: PosInt3D) -> Double {
        let x = self.operand.sample(at: pos)
        return switch self.operation {
            case .ABS: abs(x)
            // where's the standard library function for exponentiaton?
            // it's not `pow` or `exp`
            case .SQUARE: x * x
            case .CUBE: x * x * x
            case .HALF_NEGATIVE: x < 0 ? x / 2.0 : x
            case .QUARTER_NEGATIVE: x < 0 ? x / 4.0 : x
            case .SQUEEZE: UnaryDensityFunction.squeeze(x)
            case .INVERT: 1.0 / x
        }
    }

    private static func squeeze(_ x: Double) -> Double {
        let e = clamp(value: x, lowerBound: -1.0, upperBound: 1.0)
        return e / 2.0 - e * e * e / 24.0
    }

    public func bake(withBaker baker: any DensityFunctionBaker) throws -> any DensityFunction {
        return UnaryDensityFunction(operand: try self.operand.bake(withBaker: baker), type: self.operation)
    }

    public enum OperationType: String, Decodable {
        case ABS = "minecraft:abs"
        case SQUARE = "minecraft:square"
        case CUBE = "minecraft:cube"
        case HALF_NEGATIVE = "minecraft:half_negative"
        case QUARTER_NEGATIVE = "minecraft:quarter_negative"
        case SQUEEZE = "minecraft:squeeze"
        case INVERT = "minecraft:invert"
    }

    private enum CodingKeys: String, CodingKey {
        case operand = "argument"
        case operation = "type"
    }
}

/// A density function that performs one of multiple numerical operations
/// on the output of two other density functions to combine them into a single number.
@TestVisible(property: "testingAttributes") public final class BinaryDensityFunction: DensityFunction {
    private let first: any DensityFunction
    private let second: any DensityFunction
    private let operation: OperationType

    public init(firstOperand first: DensityFunction, secondOperand second: DensityFunction, type: OperationType) {
        self.first = first
        self.second = second
        self.operation = type
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.first = try container.decode(DensityFunctionInitializer.self, forKey: .first).value
        self.second = try container.decode(DensityFunctionInitializer.self, forKey: .second).value
        self.operation = try container.decode(OperationType.self, forKey: .operation)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(self.first, forKey: .first)
        try container.encode(self.second, forKey: .second)
        try container.encode(self.operation.rawValue, forKey: .operation)
    }

    public func sample(at pos: PosInt3D) -> Double {
        return switch self.operation {
            case .ADD: self.first.sample(at: pos) + self.second.sample(at: pos)
            case .MULTIPLY: self.first.sample(at: pos) * self.second.sample(at: pos)
            case .MAXIMUM: max(self.first.sample(at: pos), self.second.sample(at: pos))
            case .MINIMUM: min(self.first.sample(at: pos), self.second.sample(at: pos))
        }
    }

    public func bake(withBaker baker: any DensityFunctionBaker) throws -> any DensityFunction {
        return BinaryDensityFunction(firstOperand: try self.first.bake(withBaker: baker), secondOperand: try self.second.bake(withBaker: baker), type: self.operation)
    }

    public enum OperationType: String, Decodable {
        case ADD = "minecraft:add"
        case MULTIPLY = "minecraft:mul"
        case MAXIMUM = "minecraft:max"
        case MINIMUM = "minecraft:min"
    }

    private enum CodingKeys: String, CodingKey {
        case first = "argument1"
        case second = "argument2"
        case operation = "type"
    }
}

/// A density function that clamps the output of its input function into the given range.
@TestVisible(property: "testingAttributes") public final class ClampDensityFunction: DensityFunction {
    private let input: any DensityFunction
    private let lowerBound: Double
    private let upperBound: Double

    public init(input: DensityFunction, lowerBound: Double, upperBound: Double) {
        self.input = input
        self.lowerBound = lowerBound
        self.upperBound = upperBound
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.input = try container.decode(DensityFunctionInitializer.self, forKey: .input).value
        self.lowerBound = try container.decode(Double.self, forKey: .lowerBound)
        self.upperBound = try container.decode(Double.self, forKey: .upperBound)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode("minecraft:clamp", forKey: .type)
        try container.encode(self.input, forKey: .input)
        try container.encode(self.lowerBound, forKey: .lowerBound)
        try container.encode(self.upperBound, forKey: .upperBound)
    }

    public func sample(at pos: PosInt3D) -> Double {
        return clamp(value: self.input.sample(at: pos), lowerBound: self.lowerBound, upperBound: self.upperBound)
    }

    public func bake(withBaker baker: any DensityFunctionBaker) throws -> any DensityFunction {
        return ClampDensityFunction(input: try self.input.bake(withBaker: baker), lowerBound: self.lowerBound, upperBound: self.upperBound)
    }

    private enum CodingKeys: String, CodingKey {
        case input = "input"
        case lowerBound = "min"
        case upperBound = "max"
        case type = "type"
    }
}

/// A density function that produces a gradient based on the Y coordinate of the sampled position.
@TestVisible(property: "testingAttributes") public final class YClampedGradient: DensityFunction {
    private let fromY: Int32
    private let toY: Int32
    private let fromValue: Double
    private let toValue: Double

    public init(fromY: Int32, toY: Int32, fromValue: Double, toValue: Double) {
        self.fromY = fromY
        self.toY = toY
        self.fromValue = fromValue
        self.toValue = toValue
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.fromY = try container.decode(Int32.self, forKey: .fromY)
        self.toY = try container.decode(Int32.self, forKey: .toY)
        self.fromValue = try container.decode(Double.self, forKey: .fromValue)
        self.toValue = try container.decode(Double.self, forKey: .toValue)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode("minecraft:y_clamped_gradient", forKey: .type)
        try container.encode(self.fromY, forKey: .fromY)
        try container.encode(self.toY, forKey: .toY)
        try container.encode(self.fromValue, forKey: .fromValue)
        try container.encode(self.toValue, forKey: .toValue)
    }

    public func sample(at pos: PosInt3D) -> Double {
        return clampedMap(value: Double(pos.y), oldStart: Double(self.fromY), oldEnd: Double(self.toY), newStart: self.fromValue, newEnd: self.toValue)
    }

    public func bake(withBaker baker: any DensityFunctionBaker) -> any DensityFunction {
        return self
    }

    private enum CodingKeys: String, CodingKey {
        case fromY = "from_y"
        case toY = "to_y"
        case fromValue = "from_value"
        case toValue = "to_value"
        case type = "type"
    }
}

/// Based on the value of its input, selects one of two outputs. The only conditional density function.
@TestVisible(property: "testingAttributes") public final class RangeChoice: DensityFunction {
    private let minInclusive: Double
    private let maxExclusive: Double
    private let inputChoice: any DensityFunction
    private let whenInRange: any DensityFunction
    private let whenOutOfRange: any DensityFunction

    public init(inputChoice: DensityFunction, minInclusive: Double, maxExclusive: Double, whenInRange: DensityFunction, whenOutOfRange: DensityFunction) {
        self.minInclusive = minInclusive
        self.maxExclusive = maxExclusive
        self.inputChoice = inputChoice
        self.whenInRange = whenInRange
        self.whenOutOfRange = whenOutOfRange
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.minInclusive = try container.decode(Double.self, forKey: .minInclusive)
        self.maxExclusive = try container.decode(Double.self, forKey: .maxExclusive)
        self.inputChoice = try container.decode(DensityFunctionInitializer.self, forKey: .inputChoice).value
        self.whenInRange = try container.decode(DensityFunctionInitializer.self, forKey: .whenInRange).value
        self.whenOutOfRange = try container.decode(DensityFunctionInitializer.self, forKey: .whenOutOfRange).value
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode("minecraft:range_choice", forKey: .type)
        try container.encode(self.minInclusive, forKey: .minInclusive)
        try container.encode(self.maxExclusive, forKey: .maxExclusive)
        try container.encode(self.inputChoice, forKey: .inputChoice)
        try container.encode(self.whenInRange, forKey: .whenInRange)
        try container.encode(self.whenOutOfRange, forKey: .whenOutOfRange)
    }

    public func sample(at pos: PosInt3D) -> Double {
        let x = self.inputChoice.sample(at: pos)
        if (self.minInclusive <= x && x < self.maxExclusive) {
            return self.whenInRange.sample(at: pos)
        }
        return self.whenOutOfRange.sample(at: pos)
    }

    public func bake(withBaker baker: any DensityFunctionBaker) throws -> any DensityFunction {
        return RangeChoice(
            inputChoice: try self.inputChoice.bake(withBaker: baker),
            minInclusive: self.minInclusive,
            maxExclusive: self.maxExclusive,
            whenInRange: try self.whenInRange.bake(withBaker: baker),
            whenOutOfRange: try self.whenOutOfRange.bake(withBaker: baker)
        )
    }

    private enum CodingKeys: String, CodingKey {
        case minInclusive = "min_inclusive"
        case maxExclusive = "max_exclusive"
        case inputChoice = "input"
        case whenInRange = "when_in_range"
        case whenOutOfRange = "when_out_of_range"
        case type = "type"
    }
}

/// Samples a noise at a scaled position.
/// Encapsulates "minecraft:shift", "minecraft:shift_a", and "minecraft:shift_b".
@TestVisible(property: "testingAttributes") public final class ShiftDensityFunction: DensityFunction {
    private let shiftType: ShiftType
    private let noise: DensityFunctionNoise

    public init(noiseKey: String, shiftType: ShiftType) {
        self.noise = UnbakedNoise(fromKey: RegistryKey(referencing: noiseKey))
        self.shiftType = shiftType
    }

    public init(noise: DensityFunctionNoise, shiftType: ShiftType) {
        self.noise = noise
        self.shiftType = shiftType
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.shiftType = try container.decode(ShiftType.self, forKey: .type)
        self.noise = try UnbakedNoise(fromKey: RegistryKey(referencing: container.decode(String.self, forKey: .noiseKey)))
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(self.shiftType.rawValue, forKey: .type)
        try container.encode(self.noise.key.name, forKey: .noiseKey)
    }

    public func sample(at pos: PosInt3D) -> Double {
        return switch self.shiftType {
            // replace self with noise
            case .SHIFT_ALL: 4.0 * self.noise.sample(x: Double(pos.x) * 0.25, y: Double(pos.y) * 0.25, z: Double(pos.z) * 0.25)
            case .SHIFT_XZ: 4.0 * self.noise.sample(x: Double(pos.x) * 0.25, y: 0.0, z: Double(pos.z) * 0.25)
            case .SHIFT_ZX: 4.0 * self.noise.sample(x: Double(pos.z) * 0.25, y: Double(pos.x) * 0.25, z: 0.0)
        }
    }

    public func bake(withBaker baker: any DensityFunctionBaker) throws -> any DensityFunction {
        return ShiftDensityFunction(
            noise: try baker.bake(noise: self.noise),
            shiftType: self.shiftType
        )
    }

    /// `minecraft:shift` is `SHIFT_ALL`, `minecraft:shift_a` is `SHIFT_XZ`, and `minecraft:shift_b` is `SHIFT_ZX`.
    public enum ShiftType: String, Decodable {
        case SHIFT_ALL = "minecraft:shift"
        case SHIFT_XZ = "minecraft:shift_a"
        case SHIFT_ZX = "minecraft:shift_b"
    }

    private enum CodingKeys: String, CodingKey {
        case noiseKey = "argument"
        case type = "type"
    }
}

/// Samples a noise at a scaled position.
/// Simpler version of `ShiftedNoise`.
@TestVisible(property: "testingAttributes") public final class NoiseDensityFunction: DensityFunction {
    private let scaleXZ: Double
    private let scaleY: Double
    private let noise: DensityFunctionNoise

    public init(noiseKey: String, scaleXZ: Double, scaleY: Double) {
        self.scaleXZ = scaleXZ
        self.scaleY = scaleY
        self.noise = UnbakedNoise(fromKey: RegistryKey(referencing: noiseKey))
    }

    public init(noise: DensityFunctionNoise, scaleXZ: Double, scaleY: Double) {
        self.scaleXZ = scaleXZ
        self.scaleY = scaleY
        self.noise = noise
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.scaleXZ = try container.decode(Double.self, forKey: .scaleXZ)
        self.scaleY = try container.decode(Double.self, forKey: .scaleY)
        self.noise = try UnbakedNoise(fromKey: RegistryKey(referencing: container.decode(String.self, forKey: .noiseKey)))
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode("minecraft:noise", forKey: .type)
        try container.encode(self.scaleXZ, forKey: .scaleXZ)
        try container.encode(self.scaleY, forKey: .scaleY)
        try container.encode(self.noise.key.name, forKey: .noiseKey)
    }

    public func sample(at pos: PosInt3D) -> Double {
        return self.noise.sample(x: Double(pos.x) * self.scaleXZ, y: Double(pos.y) * self.scaleY, z: Double(pos.z) * self.scaleXZ)
    }

    public func bake(withBaker baker: any DensityFunctionBaker) throws -> any DensityFunction {
        return NoiseDensityFunction(
            noise: try baker.bake(noise: self.noise),
            scaleXZ: self.scaleXZ,
            scaleY: self.scaleY
        )
    }

    private enum CodingKeys: String, CodingKey {
        case scaleXZ = "xz_scale"
        case scaleY = "y_scale"
        case noiseKey = "noise"
        case type = "type"
    }
}

/// Samples a noise at a scaled and offset position.
/// Completely different from `Shift`.
@TestVisible(property: "testingAttributes") public final class ShiftedNoise: DensityFunction {
    private let shiftX: DensityFunction
    private let shiftY: DensityFunction
    private let shiftZ: DensityFunction
    private let scaleXZ: Double
    private let scaleY: Double
    private let noise: DensityFunctionNoise

    public init(noiseKey: String, shiftX: DensityFunction, shiftY: DensityFunction, shiftZ: DensityFunction, scaleXZ: Double, scaleY: Double) {
        self.shiftX = shiftX
        self.shiftY = shiftY
        self.shiftZ = shiftZ
        self.scaleXZ = scaleXZ
        self.scaleY = scaleY
        self.noise = UnbakedNoise(fromKey: RegistryKey(referencing: noiseKey))
    }

    public init(noise: DensityFunctionNoise, shiftX: DensityFunction, shiftY: DensityFunction, shiftZ: DensityFunction, scaleXZ: Double, scaleY: Double) {
        self.shiftX = shiftX
        self.shiftY = shiftY
        self.shiftZ = shiftZ
        self.scaleXZ = scaleXZ
        self.scaleY = scaleY
        self.noise = noise
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.shiftX = try container.decode(DensityFunctionInitializer.self, forKey: .shiftX).value
        self.shiftY = try container.decode(DensityFunctionInitializer.self, forKey: .shiftY).value
        self.shiftZ = try container.decode(DensityFunctionInitializer.self, forKey: .shiftZ).value
        self.scaleXZ = try container.decode(Double.self, forKey: .scaleXZ)
        self.scaleY = try container.decode(Double.self, forKey: .scaleY)
        self.noise = try UnbakedNoise(fromKey: RegistryKey(referencing: container.decode(String.self, forKey: .noiseKey)))
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode("minecraft:shifted_noise", forKey: .type)
        try container.encode(self.shiftX, forKey: .shiftX)
        try container.encode(self.shiftY, forKey: .shiftY)
        try container.encode(self.shiftZ, forKey: .shiftZ)
        try container.encode(self.scaleXZ, forKey: .scaleXZ)
        try container.encode(self.scaleY, forKey: .scaleY)
        try container.encode(self.noise.key.name, forKey: .noiseKey)
    }

    public func sample(at pos: PosInt3D) -> Double {
        let x = Double(pos.x) * self.scaleXZ + self.shiftX.sample(at: pos)
        let y = Double(pos.y) * self.scaleY + self.shiftY.sample(at: pos)
        let z = Double(pos.z) * self.scaleXZ + self.shiftZ.sample(at: pos)
        return self.noise.sample(x: x, y: y, z: z)
    }

    public func bake(withBaker baker: any DensityFunctionBaker) throws -> any DensityFunction {
        return ShiftedNoise(
            noise: try baker.bake(noise: self.noise),
            shiftX: try self.shiftX.bake(withBaker: baker),
            shiftY: try self.shiftY.bake(withBaker: baker),
            shiftZ: try self.shiftZ.bake(withBaker: baker),
            scaleXZ: self.scaleXZ,
            scaleY: self.scaleY
        )
    }

    private enum CodingKeys: String, CodingKey {
        case shiftX = "shift_x"
        case shiftY = "shift_y"
        case shiftZ = "shift_z"
        case scaleXZ = "xz_scale"
        case scaleY = "y_scale"
        case noiseKey = "noise"
        case type = "type"
    }
}

/// Marks a cache. Does nothing by itself.
@TestVisible(property: "testingAttributes") public final class CacheMarker: DensityFunction {
    public let type: CacheType
    public let argument: DensityFunction

    public init(type: CacheType, wrapping: DensityFunction) {
        self.type = type
        self.argument = wrapping
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.type = try container.decode(CacheType.self, forKey: .type)
        self.argument = try container.decode(DensityFunctionInitializer.self, forKey: .argument).value

        if self.type == .cacheAllInCell {
            print("WARNING: A density function of type minecraft:cache_all_in_cell was decoded. It should not be referenced from data packs.")
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(self.type.rawValue, forKey: .type)
        try container.encode(self.argument, forKey: .argument)
    }

    public func sample(at pos: PosInt3D) -> Double {
        print("WARNING: Cache marker sampled. Performace can be dramatically improved by baking the marker first.")
        return self.argument.sample(at: pos)
    }

    public func bake(withBaker baker: any DensityFunctionBaker) throws -> any DensityFunction {
        return try baker.bake(cacheMarker: self)
    }

    public enum CacheType: String, Decodable {
        case interpolated = "minecraft:interpolated"
        case cache2D = "minecraft:cache_2d"
        case flatCache = "minecraft:flat_cache"
        case cacheAllInCell = "minecraft:cache_all_in_cell"
        case cacheOnce = "minecraft:cache_once"
    }

    private enum CodingKeys: String, CodingKey {
        case type = "type"
        case argument = "argument"
    }
}

/// Part of the blending algorithm that we don't care about.
@TestVisible(property: "testingAttributes") public final class BlendAlpha: DensityFunction {
    public init() {}

    public init(from: Decoder) {}

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode("minecraft:blend_alpha", forKey: .type)
    }

    public func sample(at: PosInt3D) -> Double {
        return 1.0
    }

    public func bake(withBaker: any DensityFunctionBaker) throws -> any DensityFunction {
        return self
    }

    private enum CodingKeys: String, CodingKey {
        case type = "type"
    }
}

/// Part of the blending algorithm that we don't care about.
@TestVisible(property: "testingAttributes") public final class BlendOffset: DensityFunction {
    public init() {}

    public init(from: Decoder) {}

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode("minecraft:blend_offset", forKey: .type)
    }

    public func sample(at: PosInt3D) -> Double {
        return 0.0
    }

    public func bake(withBaker: any DensityFunctionBaker) throws -> any DensityFunction {
        return self
    }

    private enum CodingKeys: String, CodingKey {
        case type = "type"
    }
}

/// Part of the blending algorithm that we don't care about.
@TestVisible(property: "testingAttributes") public final class BlendDensity: DensityFunction {
    let argument: DensityFunction

    public init(wrapping argument: DensityFunction) {
        self.argument = argument
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.argument = try container.decode(DensityFunctionInitializer.self, forKey: .argument).value
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode("minecraft:blend_density", forKey: .type)
        try container.encode(self.argument, forKey: .argument)
    }

    public func sample(at pos: PosInt3D) -> Double {
        return self.argument.sample(at: pos)
    }

    public func bake(withBaker: any DensityFunctionBaker) throws -> any DensityFunction {
        return self
    }

    private enum CodingKeys: String, CodingKey {
        case type = "type"
        case argument = "argument"
    }
}

/// Bearding (structure terrain modification). Should not be referenced in data packs.
@TestVisible(property: "testingAttributes") public final class BeardifierMarker: DensityFunction {
    public init() {}

    public init(from: Decoder) {
        print("WARNING: A density function of type minecraft:beardifier was decoded. It should not be referenced from data packs.")
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode("minecraft:beardifier", forKey: .type)
    }

    public func sample(at: PosInt3D) -> Double {
        return 0.0
    }

    public func bake(withBaker: any DensityFunctionBaker) throws -> any DensityFunction {
        return self
    }

    private enum CodingKeys: String, CodingKey {
        case type = "type"
    }
}

/// Samples a specialised algorithm used for end islands.
@TestVisible(property: "testingAttributes") public final class EndIslandsDensityFunction: DensityFunction {
    private let sampler: DensityFunctionSimplexNoise

    public init() {
        self.sampler = DensityFunctionSimplexNoise()
    }

    public init(withSampler sampler: DensityFunctionSimplexNoise) {
        self.sampler = sampler
    }

    convenience public init(from: Decoder) {
        self.init()
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode("minecraft:end_islands", forKey: .type)
    }

    public func sample(at pos: PosInt3D) -> Double {
        return (Double(self.sample(x: pos.x / 8, z: pos.z / 8)) - 8.0) / 128.0
    }

    private func sample(x: Int32, z: Int32) -> Float {
        let chunkX = x / 2
        let chunkZ = z / 2
        let localX = x % 2
        let localZ = z % 2
        var distSquared = 64 * (UInt64(abs(x)) * UInt64(abs(x)) + UInt64(abs(z)) * UInt64(abs(z)))
        //var ret = clamp(value: 100.0 - dist * 8.0, lowerBound: -100, upperBound: 80)

        for offsetX in -12...12 {
            for offsetZ in -12...12 {
                let trialChunkX = Int64(chunkX + Int32(offsetX))
                let trialChunkZ = Int64(chunkZ + Int32(offsetZ))
                let radiusSquared = trialChunkX * trialChunkX + trialChunkZ * trialChunkZ
                let spx = self.sampler.sample(x: Double(trialChunkX), y: Double(trialChunkZ))
                if (radiusSquared > 4096 && spx < -0.9) {
                    let scaledChunkX = abs(Float(trialChunkX)) * 3439.0
                    let scaledChunkZ = abs(Float(trialChunkZ)) * 147.0
                    let sum = scaledChunkX + scaledChunkZ
                    // This is a Swift implementation of the C float-to-unsigned cast,
                    // which may differ from Java's implementation.
                    let intSum = sum > Float(UInt32.max) ? UInt32.max : UInt32(sum)
                    let scale = UInt64(intSum % 13) + 9
                    let offsetLocalX = localX - Int32(offsetX) * 2
                    let offsetLocalZ = localZ - Int32(offsetZ) * 2
                    let ax = UInt64(abs(offsetLocalX))
                    let az = UInt64(abs(offsetLocalZ))
                    let localDistSquared = ax * ax + az * az
                    let scaledLocalDist = localDistSquared * scale * scale
                    distSquared = min(distSquared, scaledLocalDist)
                }
            }
        }

        return clamp(value: 100.0 - sqrt(Float(distSquared)), lowerBound: -100, upperBound: 80)
    }

    public func bake(withBaker baker: any DensityFunctionBaker) throws -> any DensityFunction {
        return EndIslandsDensityFunction(withSampler: try baker.bake(simplexNoise: self.sampler))
    }

    private enum CodingKeys: String, CodingKey {
        case type = "type"
    }
}

/// According to the input value, scales some regions of the input noise. Only returns the absolute value.
@TestVisible(property: "testingAttributes") public final class WeirdScaledSampler: DensityFunction {
    private let input: any DensityFunction
    private let type: ScalingType
    private let noise: any DensityFunctionNoise

    public init(type: ScalingType, withInput input: any DensityFunction, withNoiseFromKey noiseKey: String) {
        self.type = type
        self.input = input
        self.noise = UnbakedNoise(fromKey: RegistryKey(referencing: noiseKey))
    }

    public init(type: ScalingType, withInput input: any DensityFunction, withNoise noise: any DensityFunctionNoise) {
        self.type = type
        self.input = input
        self.noise = noise
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.type = try container.decode(ScalingType.self, forKey: .rarityValueMapper)
        self.input = try container.decode(DensityFunctionInitializer.self, forKey: .input).value
        self.noise = try UnbakedNoise(fromKey: RegistryKey(referencing: container.decode(String.self, forKey: .noiseKey)))
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode("minecraft:weird_scaled_sampler", forKey: .type)
        try container.encode(self.input, forKey: .input)
        try container.encode(self.noise.key.name, forKey: .noiseKey)
        try container.encode(self.type, forKey: .rarityValueMapper)
    }

    public func sample(at pos: PosInt3D) -> Double {
        let density = self.input.sample(at: pos)
        let scaledValue = self.scale(density)
        return scaledValue * abs(self.noise.sample(x: Double(pos.x) / scaledValue, y: Double(pos.y) / scaledValue, z: Double(pos.z) / scaledValue))
    }

    public func bake(withBaker baker: any DensityFunctionBaker) throws -> any DensityFunction {
        return WeirdScaledSampler(
            type: self.type,
            withInput: try self.input.bake(withBaker: baker),
            withNoise: try baker.bake(noise: self.noise)
        )
    }

    private func scale(_ input: Double) -> Double {
        switch self.type {
            case .scaleTunnels:
                if input < -0.5 { return 0.75 }
                if input < 0.0 { return 1.0 }
                if input < 0.5 { return 1.5 }
                return 2.0
            case .scaleCaves:
                if input < -0.75 { return 0.5 }
                if input < -0.5 { return 0.75 }
                if input < 0.5 { return 1.0 }
                if input < 0.75 { return 2.0 }
                return 3.0
        }
    }

    public enum ScalingType: String, Codable {
        case scaleTunnels = "type_1"
        case scaleCaves = "type_2"
    }

    private enum CodingKeys: String, CodingKey {
        case type = "type"
        case rarityValueMapper = "rarity_value_mapper"
        case noiseKey = "noise"
        case input = "input"
    }
}

/// Samples a cubic spline.
@TestVisible(property: "testingAttributes") public final class SplineDensityFunction: DensityFunction {
    private let spline: SplineSegment

    internal init(withSpline spline: SplineSegment) {
        self.spline = spline
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.spline = try container.decode(SplineSegment.self, forKey: .spline)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode("minecraft:spline", forKey: .type)
        try container.encode(self.spline, forKey: .spline)
    }

    public func sample(at pos: PosInt3D) -> Double {
        return Double(self.spline.sample(at: pos))
    }

    public func bake(withBaker: any DensityFunctionBaker) throws -> any DensityFunction {
        return SplineDensityFunction(withSpline: self.spline)
    }

    private enum CodingKeys: String, CodingKey {
        case type = "type"
        case spline = "spline"
    }
}

/// Finds the top surface of its input (that is, the Y-coordinate at which the input exceeds 0.0).
@TestVisible(property: "testingAttributes") public final class FindTopSurface: DensityFunction {
    private let density: any DensityFunction
    private let upperBound: any DensityFunction
    private let lowerBound: Int
    private let cellHeight: Int

    public init(density: any DensityFunction, upperBound: any DensityFunction, lowerBound: Int, cellHeight: Int) {
        self.density = density
        self.upperBound = upperBound
        self.lowerBound = lowerBound
        self.cellHeight = cellHeight
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.density = try container.decode(DensityFunctionInitializer.self, forKey: .density).value
        self.upperBound = try container.decode(DensityFunctionInitializer.self, forKey: .upperBound).value
        self.lowerBound = try container.decode(Int.self, forKey: .lowerBound)
        self.cellHeight = try container.decode(Int.self, forKey: .cellHeight)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode("minecraft:find_top_surface", forKey: .type)
        try container.encode(self.density, forKey: .density)
        try container.encode(self.upperBound, forKey: .upperBound)
        try container.encode(self.lowerBound, forKey: .lowerBound)
        try container.encode(self.cellHeight, forKey: .cellHeight)
    }

    public func sample(at pos: PosInt3D) -> Double {
        let startingY = Int(floor(self.upperBound.sample(at: pos) / Double(self.cellHeight))) * self.cellHeight
        if (startingY <= self.lowerBound) {
            return Double(self.lowerBound)
        }

        for y in stride(from: startingY, through: self.lowerBound, by: -self.cellHeight) {
            let samplePos = PosInt3D(x: pos.x, y: Int32(y), z: pos.z)
            if self.density.sample(at: samplePos) > 0.0 {
                return Double(y)
            }
        }

        return Double(self.lowerBound)
    }

    public func bake(withBaker baker: any DensityFunctionBaker) throws -> any DensityFunction {
        return FindTopSurface(
            density: try self.density.bake(withBaker: baker),
            upperBound: try self.upperBound.bake(withBaker: baker),
            lowerBound: self.lowerBound,
            cellHeight: self.cellHeight
        )
    }

    private enum CodingKeys: String, CodingKey {
        case type = "type"
        case density = "density"
        case upperBound = "upper_bound"
        case lowerBound = "lower_bound"
        case cellHeight = "cell_height"
    }
}

/// Decodes (deserializes) a density function from a decoder.
/// - Parameter from: The decoder to decode from.
/// - Returns: The density function represented by the decoder.
private func decodeDensityFunction(from decoder: Decoder) throws -> DensityFunction {
    // If this is a single-value container it's either a reference to another density function by key
    // or a shorthand constant.
    if let singleValueContainer = try? decoder.singleValueContainer() {
        if let key = try? singleValueContainer.decode(String.self) {
            return ReferenceDensityFunction(target: key)
        }

        if let value = try? singleValueContainer.decode(Double.self) {
            return ConstantDensityFunction(value: value)
        }
    }

    // Otherwise try a keyed container and inspect the "type" field for known variants.
    if let container = try? decoder.container(keyedBy: GenericCodingKeys.self),
        let typeKey = try? addDefaultNamespace(container.decode(String.self, forKey: GenericCodingKeys(stringValue: "type")!)) {
        switch typeKey {
        case "minecraft:constant":
            return try ConstantDensityFunction(from: decoder)
        case "minecraft:abs", "minecraft:square", "minecraft:cube", "minecraft:half_negative", "minecraft:quarter_negative", "minecraft:squeeze", "minecraft:invert":
            return try UnaryDensityFunction(from: decoder)
        case "minecraft:add", "minecraft:mul", "minecraft:min", "minecraft:max":
            return try BinaryDensityFunction(from: decoder)
        case "minecraft:clamp":
            return try ClampDensityFunction(from: decoder)
        case "minecraft:y_clamped_gradient":
            return try YClampedGradient(from: decoder)
        case "minecraft:range_choice":
            return try RangeChoice(from: decoder)
        case "minecraft:shift", "minecraft:shift_a", "minecraft:shift_b":
            return try ShiftDensityFunction(from: decoder)
        case "minecraft:noise":
            return try NoiseDensityFunction(from: decoder)
        case "minecraft:shifted_noise":
            return try ShiftedNoise(from: decoder)
        case "minecraft:interpolated", "minecraft:flat_cache", "minecraft:cache_2d", "minecraft:cache_once", "minecraft:cache_all_in_cell":
            return try CacheMarker(from: decoder)
        case "minecraft:blend_alpha":
            return BlendAlpha()
        case "minecraft:blend_offset":
            return BlendOffset()
        case "minecraft:blend_density":
            return try BlendDensity(from: decoder)
        case "minecraft:beardifier":
            // using this initialiser to print the warning
            return BeardifierMarker(from: decoder)
        case "minecraft:end_islands":
            return EndIslandsDensityFunction(from: decoder)
        case "minecraft:weird_scaled_sampler":
            return try WeirdScaledSampler(from: decoder)
        case "minecraft:spline":
            return try SplineDensityFunction(from: decoder)
        case "minecraft:find_top_surface":
            return try FindTopSurface(from: decoder)
        default:
            break
        }
        throw DensityFunctionDecodingError.invalidType(typeKey)
    }

    throw DensityFunctionDecodingError.invalidStructure
}

/// An error that might come up when decoding a density function.
public enum DensityFunctionDecodingError: Error {
    /// Either the type key is missing or a decoding container couldn't be synthesized
    /// (potentially because an array was decoded instead of a compound).
    case invalidStructure
    /// The type key is invalid. The raw value is the actual type key.
    case invalidType(String)
}

private struct GenericCodingKeys: CodingKey {
    var stringValue: String
    init?(stringValue: String) { self.stringValue = stringValue }
    var intValue: Int? { return nil }
    init?(intValue: Int) { return nil }
}

/// A conformance structure that allows for the usage of `Decoder.decode`.
public struct DensityFunctionInitializer: Decodable {
    let value: DensityFunction
    
    public init(from decoder: Decoder) throws {
        self.value = try decodeDensityFunction(from: decoder)
    }
}