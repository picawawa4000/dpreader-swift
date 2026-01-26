/// So I don't forget whether seeds are unsigned or signed
/// (Swift has stricter rules about that than C++).
public typealias WorldSeed = UInt64

// why are none of these in the standard library
func rotateLeft(_ x: UInt64, _ bits: UInt8) -> UInt64 {
    return (x << bits) | (x >> (64 - bits))
}

func clamp<T: Comparable>(value: T, lowerBound: T, upperBound: T) -> T {
    return value > upperBound ? upperBound : (value < lowerBound ? lowerBound : value)
}

func lerp(delta: Double, start: Double, end: Double) -> Double {
    return start + delta * (end - start)
}

func lerp(delta: Float, start: Float, end: Float) -> Float {
    return start + delta * (end - start)
}

func lerp2(deltaX: Double, deltaY: Double, x0y0: Double, x1y0: Double, x0y1: Double, x1y1: Double) -> Double {
    return lerp(delta: deltaY, start: lerp(delta: deltaX, start: x0y0, end: x1y0), end: lerp(delta: deltaX, start: x0y1, end: x1y1))
}

func lerp3(deltaX: Double, deltaY: Double, deltaZ: Double, x0y0z0: Double, x1y0z0: Double, x0y1z0: Double, x1y1z0: Double, x0y0z1: Double, x1y0z1: Double, x0y1z1: Double, x1y1z1: Double) -> Double {
    return lerp(delta: deltaZ,
                start: lerp2(deltaX: deltaX, deltaY: deltaY, x0y0: x0y0z0, x1y0: x1y0z0, x0y1: x0y1z0, x1y1: x1y1z0),
                end: lerp2(deltaX: deltaX, deltaY: deltaY, x0y0: x0y0z1, x1y0: x1y0z1, x0y1: x0y1z1, x1y1: x1y1z1))
}

func clampedLerp(delta: Double, start: Double, end: Double) -> Double {
    return delta <= 0.0 ? start : (delta >= 1.0 ? end : lerp(delta: delta, start: start, end: end))
}

func getLerpProgress(value: Double, start: Double, end: Double) -> Double {
    return (value - start) / (end - start)
}

func clampedMap(value: Double, oldStart: Double, oldEnd: Double, newStart: Double, newEnd: Double) -> Double {
    return clampedLerp(delta: getLerpProgress(value: value, start: oldStart, end: oldEnd), start: newStart, end: newEnd)
}

/// Protection from overflow protection.
/// - Parameter x: The potentially overflowing value.
/// - Returns: The value as a `UInt64`.
func overflow(_ x: Int64) -> UInt64 {
    return UInt64(bitPattern: x)
}

enum TestingError: Error {
    case testFailed(String)
}

/// Represents an identifier of a single object (`rawID`),
/// an identifier of a tag (`tagID`),
/// or a list of identifiers (`idList`).
enum Identifiers: Codable, Equatable {
    case rawID(String), tagID(String), idList([String])

    init(from: any Decoder) throws {
        let value = try from.singleValueContainer()
        do {
            // is there a better way to check whether the type is either String or [String]?
            let stringValue = try value.decode(String.self)
            if (stringValue.first == "#") {
                self = Identifiers.tagID(String(stringValue.dropFirst()))
            } else {
                self = Identifiers.rawID(stringValue)
            }
        } catch DecodingError.typeMismatch {
            let arrayValue = try value.decode([String].self)
            self = Identifiers.idList(arrayValue)
        }
    }
}

/// A 3D position, represented by ints. Usually used for blocks.
public struct PosInt3D {
    let x, y, z: Int32
}

/// A 3D position, represented by doubles.
public struct PosDouble3D {
    let x, y, z: Double
}

/// A 2D position, represented by ints. Usually used for chunks.
public struct PosInt2D {
    let x, z: Int32
}

/// Adds the vanilla namespace `minecraft:` to an ID if it does not have a namespace.
/// This ensures that all IDs are properly namespaced.
/// - Parameter id: The potentially non-namespaced ID.
func addDefaultNamespace(_ id: String) -> String {
    return id.contains(":") ? id : "minecraft:" + id
}
