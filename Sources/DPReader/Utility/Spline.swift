import TestVisible

// Utilities for the implementation of `SplineDensityFunction`.
// These are all internal for a reason.

@TestVisible(property: "testingAttributes") internal final class SplineObject: Codable {
    private let input: any DensityFunction
    private let locations: [Float]
    private let values: [SplineSegment]
    private let derivatives: [Float]

    init(withInput input: any DensityFunction, locations: [Float], values: [SplineSegment], derivatives: [Float]) {
        self.input = input
        self.locations = locations
        self.values = values
        self.derivatives = derivatives
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.input = try container.decode(DensityFunctionInitializer.self, forKey: .input).value
        let points = try container.decode([Point].self, forKey: .points)

        var locations: [Float] = []
        var values: [SplineSegment] = []
        var derivatives: [Float] = []

        for point in points {
            locations.append(point.location)
            values.append(point.value)
            derivatives.append(point.derivative)
        }

        self.locations = locations
        self.values = values
        self.derivatives = derivatives
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(self.input, forKey: .input)
        
        var points: [Point] = []
        for idx in 0..<locations.count {
            points.append(Point(location: self.locations[idx], value: self.values[idx], derivative: self.derivatives[idx]))
        }
        try container.encode(points, forKey: .points)
    }

    private static func sampleOutsideRange(point: Float, locations: [Float], value: Float, derivatives: [Float], location: Int) -> Float {
        let derivative = derivatives[location]
        return derivative == 0.0 ? value : value + derivative * (point - locations[location])
    }

    private static func findGreatestLocation(in locations: [Float], lowerThan value: Float) -> Int {
        var low = 0
        var high = locations.count
        while low < high {
            let mid = (low + high) / 2
            if locations[mid] < value {
                low = mid + 1
            } else {
                high = mid
            }
        }
        return low - 1
    }

    // Minecraft's splines use floats. I have no clue why.
    func sample(at pos: PosInt3D) -> Float {
        let value = Float(self.input.sample(at: pos))
        let lowerBound = SplineObject.findGreatestLocation(in: self.locations, lowerThan: value)
        let lastLocation = self.locations.count - 1
        if lowerBound < 0 {
            return SplineObject.sampleOutsideRange(point: value, locations: self.locations, value: self.values[0].sample(at: pos), derivatives: self.derivatives, location: 0)
        }
        if lowerBound == lastLocation {
            return SplineObject.sampleOutsideRange(point: value, locations: self.locations, value: self.values[lastLocation].sample(at: pos), derivatives: self.derivatives, location: lastLocation)
        }
        let locationBeforeValue = self.locations[lowerBound]
        let locationAfterValue = self.locations[lowerBound + 1]
        let segmentSlope = (value - locationBeforeValue) / (locationAfterValue - locationBeforeValue)
        let l = self.derivatives[lowerBound]
        let m = self.derivatives[lowerBound + 1]
        let n = self.values[lowerBound].sample(at: pos)
        let o = self.values[lowerBound+1].sample(at: pos)
        let p = l * (locationAfterValue - locationBeforeValue) - (o - n)
        let q = -m * (locationAfterValue - locationBeforeValue) + (o - n)
        return lerp(delta: segmentSlope, start: n, end: o) + segmentSlope * (1.0 - segmentSlope) * lerp(delta: segmentSlope, start: p, end: q)
    }

    func bake(withBaker baker: any DensityFunctionBaker) throws -> SplineObject {
        return SplineObject(
            withInput: try self.input.bake(withBaker: baker),
            locations: self.locations,
            values: try self.values.map { try $0.bake(withBaker: baker) },
            derivatives: self.derivatives
        )
    }

    private struct Point: Codable {
        let location: Float
        let value: SplineSegment
        let derivative: Float
    }

    private enum CodingKeys: String, CodingKey {
        case input = "coordinate"
        case points = "points"
    }
}

internal enum SplineSegment: Codable {
    case object(SplineObject)
    case number(Float)

    init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let numberValue = try? container.decode(Float.self) {
            self = .number(numberValue)
        } else {
            let objectValue = try container.decode(SplineObject.self)
            self = .object(objectValue)
        }
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
            case .number(let x):
                try container.encode(x)
            case .object(let obj):
                try container.encode(obj)
        }
    }

    func sample(at pos: PosInt3D) -> Float {
        switch self {
            case .number(let x):
                return x
            case .object(let obj):
                return obj.sample(at: pos)
        }
    }

    func bake(withBaker baker: any DensityFunctionBaker) throws -> SplineSegment {
        switch self {
            case .number:
                return self
            case .object(let obj):
                return .object(try obj.bake(withBaker: baker))
        }
    }
}
