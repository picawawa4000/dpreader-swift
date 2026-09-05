import Foundation

private func requireDensityFunction113(_ encoder: Encoder, feature: String) throws {
    guard encoder.dpReaderPackFormat >= Version(major: 113, minor: 0) else {
        throw EncodingError.invalidValue(feature, .init(codingPath: encoder.codingPath, debugDescription: "\(feature) requires pack format 113.0 or newer"))
    }
}

/// Unary density functions introduced in pack format 113.
public final class ModernUnaryDensityFunction: DensityFunction {
    public enum Operation: String, Codable {
        case sqrt = "minecraft:sqrt"
        case log = "minecraft:log"
        case sign = "minecraft:sign"
        case negate = "minecraft:negate"
    }

    private let input: DensityFunction
    private let operation: Operation

    public init(input: DensityFunction, operation: Operation) {
        self.input = input
        self.operation = operation
    }

    public convenience init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            input: try container.decode(DensityFunctionInitializer.self, forKey: .input).value,
            operation: try container.decode(Operation.self, forKey: .type)
        )
    }

    public func encode(to encoder: Encoder) throws {
        try requireDensityFunction113(encoder, feature: operation.rawValue)
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(operation, forKey: .type)
        try container.encode(input, forKey: .input)
    }

    public func sample(at pos: PosInt3D) -> Double {
        let value = input.sample(at: pos)
        switch operation {
        case .sqrt: return Foundation.sqrt(value)
        case .log: return Foundation.log(value)
        case .sign: return value == 0 ? 0 : value.sign == .minus ? -1 : 1
        case .negate: return -value
        }
    }

    public func lowerBoundValue() -> Double {
        switch operation {
        case .sqrt: return input.upperBoundValue() < 0 ? .nan : 0
        case .sign: return -1
        case .log: return -Double.greatestFiniteMagnitude
        case .negate: return -input.upperBoundValue()
        }
    }

    public func upperBoundValue() -> Double {
        switch operation {
        case .sqrt: return Foundation.sqrt(max(0, input.upperBoundValue()))
        case .sign: return 1
        case .log: return .greatestFiniteMagnitude
        case .negate: return -input.lowerBoundValue()
        }
    }

    public func bake(withBaker baker: any DensityFunctionBaker) throws -> any DensityFunction {
        try ModernUnaryDensityFunction(input: input.bake(withBaker: baker), operation: operation)
    }

    private enum CodingKeys: String, CodingKey {
        case type
        case input
    }
}

/// Binary arithmetic that uses the left/right schema introduced in format 113.
public final class ModernBinaryDensityFunction: DensityFunction {
    public enum Operation: String, Codable {
        case subtract = "minecraft:sub"
        case divide = "minecraft:div"
    }

    private let left: DensityFunction
    private let right: DensityFunction
    private let operation: Operation

    public init(left: DensityFunction, right: DensityFunction, operation: Operation) {
        self.left = left
        self.right = right
        self.operation = operation
    }

    public convenience init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            left: try container.decode(DensityFunctionInitializer.self, forKey: .left).value,
            right: try container.decode(DensityFunctionInitializer.self, forKey: .right).value,
            operation: try container.decode(Operation.self, forKey: .type)
        )
    }

    public func encode(to encoder: Encoder) throws {
        try requireDensityFunction113(encoder, feature: operation.rawValue)
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(operation, forKey: .type)
        try container.encode(left, forKey: .left)
        try container.encode(right, forKey: .right)
    }

    public func sample(at pos: PosInt3D) -> Double {
        switch operation {
        case .subtract: return left.sample(at: pos) - right.sample(at: pos)
        case .divide: return left.sample(at: pos) / right.sample(at: pos)
        }
    }

    public func lowerBoundValue() -> Double {
        switch operation {
        case .subtract: return left.lowerBoundValue() - right.upperBoundValue()
        case .divide: return -Double.greatestFiniteMagnitude
        }
    }

    public func upperBoundValue() -> Double {
        switch operation {
        case .subtract: return left.upperBoundValue() - right.lowerBoundValue()
        case .divide: return Double.greatestFiniteMagnitude
        }
    }

    public func bake(withBaker baker: any DensityFunctionBaker) throws -> any DensityFunction {
        try ModernBinaryDensityFunction(left: left.bake(withBaker: baker), right: right.bake(withBaker: baker), operation: operation)
    }

    private enum CodingKeys: String, CodingKey { case type, left, right }
}

/// Linearly interpolates between two density functions using an unbounded alpha.
public final class LerpDensityFunction: DensityFunction {
    private let alpha: DensityFunction
    private let first: DensityFunction
    private let second: DensityFunction

    public init(alpha: DensityFunction, first: DensityFunction, second: DensityFunction) {
        self.alpha = alpha
        self.first = first
        self.second = second
    }

    public convenience init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            alpha: try container.decode(DensityFunctionInitializer.self, forKey: .alpha).value,
            first: try container.decode(DensityFunctionInitializer.self, forKey: .first).value,
            second: try container.decode(DensityFunctionInitializer.self, forKey: .second).value
        )
    }

    public func encode(to encoder: Encoder) throws {
        try requireDensityFunction113(encoder, feature: "minecraft:lerp")
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode("minecraft:lerp", forKey: .type)
        try container.encode(alpha, forKey: .alpha)
        try container.encode(first, forKey: .first)
        try container.encode(second, forKey: .second)
    }

    public func sample(at pos: PosInt3D) -> Double {
        let alpha = alpha.sample(at: pos)
        return first.sample(at: pos) + alpha * (second.sample(at: pos) - first.sample(at: pos))
    }

    public func lowerBoundValue() -> Double { -Double.greatestFiniteMagnitude }
    public func upperBoundValue() -> Double { Double.greatestFiniteMagnitude }

    public func bake(withBaker baker: any DensityFunctionBaker) throws -> any DensityFunction {
        try LerpDensityFunction(alpha: alpha.bake(withBaker: baker), first: first.bake(withBaker: baker), second: second.bake(withBaker: baker))
    }

    private enum CodingKeys: String, CodingKey { case type, alpha, first, second }
}

/// Samples its input at a fixed coordinate on one axis.
public final class SliceDensityFunction: DensityFunction {
    public enum Axis: String, Codable { case x, y, z }

    private let axis: Axis
    private let coordinate: Int32
    private let input: DensityFunction

    public init(axis: Axis, coordinate: Int32, input: DensityFunction) {
        self.axis = axis
        self.coordinate = coordinate
        self.input = input
    }

    public convenience init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            axis: try container.decode(Axis.self, forKey: .axis),
            coordinate: try container.decode(Int32.self, forKey: .coordinate),
            input: try container.decode(DensityFunctionInitializer.self, forKey: .input).value
        )
    }

    public func encode(to encoder: Encoder) throws {
        try requireDensityFunction113(encoder, feature: "minecraft:slice")
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode("minecraft:slice", forKey: .type)
        try container.encode(axis, forKey: .axis)
        try container.encode(coordinate, forKey: .coordinate)
        try container.encode(input, forKey: .input)
    }

    public func sample(at pos: PosInt3D) -> Double {
        let sliced = switch axis {
        case .x: PosInt3D(x: coordinate, y: pos.y, z: pos.z)
        case .y: PosInt3D(x: pos.x, y: coordinate, z: pos.z)
        case .z: PosInt3D(x: pos.x, y: pos.y, z: coordinate)
        }
        return input.sample(at: sliced)
    }

    public func lowerBoundValue() -> Double { input.lowerBoundValue() }
    public func upperBoundValue() -> Double { input.upperBoundValue() }
    public func bake(withBaker baker: any DensityFunctionBaker) throws -> any DensityFunction {
        try SliceDensityFunction(axis: axis, coordinate: coordinate, input: input.bake(withBaker: baker))
    }

    private enum CodingKeys: String, CodingKey { case type, axis, coordinate, input }
}

/// The `minecraft:pow` density function introduced in pack format 113.
public final class PowerDensityFunction: DensityFunction {
    private let base: DensityFunction
    private let exponent: DensityFunction

    public init(base: DensityFunction, exponent: DensityFunction) {
        self.base = base
        self.exponent = exponent
    }

    public convenience init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            base: try container.decode(DensityFunctionInitializer.self, forKey: .base).value,
            exponent: try container.decode(DensityFunctionInitializer.self, forKey: .exponent).value
        )
    }

    public func encode(to encoder: Encoder) throws {
        try requireDensityFunction113(encoder, feature: "minecraft:pow")
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode("minecraft:pow", forKey: .type)
        try container.encode(base, forKey: .base)
        try container.encode(exponent, forKey: .exponent)
    }

    public func sample(at pos: PosInt3D) -> Double {
        Foundation.pow(base.sample(at: pos), exponent.sample(at: pos))
    }

    public func lowerBoundValue() -> Double { -Double.greatestFiniteMagnitude }
    public func upperBoundValue() -> Double { Double.greatestFiniteMagnitude }

    public func bake(withBaker baker: any DensityFunctionBaker) throws -> any DensityFunction {
        try PowerDensityFunction(base: base.bake(withBaker: baker), exponent: exponent.bake(withBaker: baker))
    }

    private enum CodingKeys: String, CodingKey {
        case type
        case base
        case exponent
    }
}

/// The distance to a fixed block position using one of vanilla's metrics.
public final class DistanceToPointDensityFunction: DensityFunction {
    public enum Metric: String, Codable {
        case euclidean
        case euclideanSquared = "euclidean_squared"
        case manhattan
        case chebyshev
    }

    private let point: PosInt3D
    private let metric: Metric

    public init(point: PosInt3D, metric: Metric) {
        self.point = point
        self.metric = metric
    }

    public convenience init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let values = try container.decode([Int32].self, forKey: .point)
        guard values.count == 3 else {
            throw DecodingError.dataCorruptedError(forKey: .point, in: container, debugDescription: "distance_to_point.point must contain exactly [x, y, z]")
        }
        self.init(point: PosInt3D(x: values[0], y: values[1], z: values[2]), metric: try container.decode(Metric.self, forKey: .metric))
    }

    public func encode(to encoder: Encoder) throws {
        try requireDensityFunction113(encoder, feature: "minecraft:distance_to_point")
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode("minecraft:distance_to_point", forKey: .type)
        try container.encode([point.x, point.y, point.z], forKey: .point)
        try container.encode(metric, forKey: .metric)
    }

    public func sample(at pos: PosInt3D) -> Double {
        let x = Double(pos.x) - Double(point.x)
        let y = Double(pos.y) - Double(point.y)
        let z = Double(pos.z) - Double(point.z)
        switch metric {
        case .euclidean: return Foundation.sqrt(x * x + y * y + z * z)
        case .euclideanSquared: return x * x + y * y + z * z
        case .manhattan: return abs(x) + abs(y) + abs(z)
        case .chebyshev: return max(abs(x), max(abs(y), abs(z)))
        }
    }

    public func lowerBoundValue() -> Double { 0 }
    public func upperBoundValue() -> Double { Double.greatestFiniteMagnitude }
    public func bake(withBaker: any DensityFunctionBaker) -> any DensityFunction { self }

    private enum CodingKeys: String, CodingKey {
        case type
        case point
        case metric
    }
}

/// The generalized gradient that replaced `minecraft:y_clamped_gradient` in format 113.
public final class GradientDensityFunction: DensityFunction {
    public enum Axis: String, Codable { case x, y, z }
    public enum Tiling: String, Codable { case clampToEdge = "clamp_to_edge", `repeat`, mirroredRepeat = "mirrored_repeat" }

    private let axis: Axis
    private let tiling: Tiling
    private let fromCoordinate: Int32
    private let toCoordinate: Int32
    private let fromValue: Double
    private let toValue: Double

    public init(axis: Axis, tiling: Tiling = .clampToEdge, fromCoordinate: Int32, toCoordinate: Int32, fromValue: Double, toValue: Double) {
        precondition(fromCoordinate != toCoordinate, "gradient coordinates must differ")
        self.axis = axis
        self.tiling = tiling
        self.fromCoordinate = fromCoordinate
        self.toCoordinate = toCoordinate
        self.fromValue = fromValue
        self.toValue = toValue
    }

    public convenience init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let from = try container.decode(Int32.self, forKey: .fromCoordinate)
        let to = try container.decode(Int32.self, forKey: .toCoordinate)
        guard from != to else {
            throw DecodingError.dataCorruptedError(forKey: .toCoordinate, in: container, debugDescription: "gradient.to_coordinate must differ from from_coordinate")
        }
        self.init(
            axis: try container.decode(Axis.self, forKey: .axis),
            tiling: try container.decodeIfPresent(Tiling.self, forKey: .tiling) ?? .clampToEdge,
            fromCoordinate: from,
            toCoordinate: to,
            fromValue: try container.decode(Double.self, forKey: .fromValue),
            toValue: try container.decode(Double.self, forKey: .toValue)
        )
    }

    public func encode(to encoder: Encoder) throws {
        try requireDensityFunction113(encoder, feature: "minecraft:gradient")
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode("minecraft:gradient", forKey: .type)
        try container.encode(axis, forKey: .axis)
        try container.encode(fromCoordinate, forKey: .fromCoordinate)
        try container.encode(toCoordinate, forKey: .toCoordinate)
        try container.encode(fromValue, forKey: .fromValue)
        try container.encode(toValue, forKey: .toValue)
    }

    public func sample(at pos: PosInt3D) -> Double {
        let coordinate = switch axis {
        case .x: pos.x
        case .y: pos.y
        case .z: pos.z
        }
        let range = Double(toCoordinate - fromCoordinate)
        var progress = (Double(coordinate) - Double(fromCoordinate)) / range
        switch tiling {
        case .clampToEdge:
            progress = clamp(value: progress, lowerBound: 0, upperBound: 1)
        case .repeat:
            progress -= Foundation.floor(progress)
        case .mirroredRepeat:
            let repetition = Foundation.floor(progress)
            progress -= repetition
            if Int64(repetition) % 2 != 0 { progress = 1 - progress }
        }
        return fromValue + (toValue - fromValue) * progress
    }

    public func lowerBoundValue() -> Double { min(fromValue, toValue) }
    public func upperBoundValue() -> Double { max(fromValue, toValue) }
    public func bake(withBaker: any DensityFunctionBaker) -> any DensityFunction { self }

    private enum CodingKeys: String, CodingKey {
        case type
        case axis
        case tiling
        case fromCoordinate = "from_coordinate"
        case toCoordinate = "to_coordinate"
        case fromValue = "from_value"
        case toValue = "to_value"
    }
}
