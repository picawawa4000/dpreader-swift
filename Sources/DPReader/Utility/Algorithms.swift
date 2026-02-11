import Foundation
// For cross-platform String.md5
import CryptoSwift

/// TODO: use `@TestVisible` for tests instead of `compareForTest`.

/// ----- RNG -----

public protocol Random {
    // is this necessary?
    /// The random splitter type associated with this random number generator.
    associatedtype Splitter: RandomSplitter

    mutating func next(bound: UInt32) -> UInt32
    mutating func nextLong() -> UInt64
    mutating func nextFloat() -> Float
    mutating func nextDouble() -> Double
    mutating func nextSplitter() -> Splitter
    mutating func skip(calls: UInt)
}

public protocol RandomSplitter {
    /// The random type returned by this splitter's methods.
    associatedtype ReturnedRandom: Random

    func split(usingPos: PosInt3D) -> ReturnedRandom
    func split(usingString: String) -> ReturnedRandom
    func split(usingLong: WorldSeed) -> ReturnedRandom
}

/// A basic LCG used by Minecraft in a couple of places.
public struct CheckedRandom: Random {
    private var seed: UInt64 = 0

    private static let MULTIPLIER: UInt64 = 25214903917
    private static let INCREMENT: UInt64 = 11
    private static let BITMASK_48: UInt64 = 0xFFFFFFFFFFFF

    public init(seed: UInt64) {
        self.setSeed(newSeed: seed)
    }

    public mutating func setSeed(newSeed seed: UInt64) {
        self.seed = (seed ^ 25214903917) & CheckedRandom.BITMASK_48
    }

    public mutating func next(bits: UInt8) -> UInt32 {
        self.seed = (self.seed &* CheckedRandom.MULTIPLIER &+ CheckedRandom.INCREMENT) & CheckedRandom.BITMASK_48
        // masking to ensure that the value is within bounds (how to not do that?)
        return UInt32((self.seed >> (48 - bits)) & ((1 << 32) - 1))
    }

    public mutating func next(bound: UInt32) -> UInt32 {
        if ((bound & (bound &- 1)) == 0) {
            return UInt32((UInt64(bound) * UInt64(self.next(bits: 31))) >> 31);
        }

        var j, k: Int32
        repeat {
            j = Int32(self.next(bits: 31));
            k = j % Int32(bound);
        } while j &- k &+ Int32(bound &- 1) < 0;
        return UInt32(k);
    }

    public mutating func nextLong() -> UInt64 {
        return (UInt64(self.next(bits: 32)) << 32) + UInt64(self.next(bits: 32))
    }

    public mutating func nextFloat() -> Float {
        return Float(self.next(bits: 24)) * 5.9604645e-8
    }

    public mutating func nextDouble() -> Double {
        let i: UInt64 = UInt64(self.next(bits: 26));
        let j: UInt64 = UInt64(self.next(bits: 27));
        let l = (UInt64(i) << 27) + j;
        return Double(l) * 1.110223E-16;
    }

    public mutating func nextSplitter() -> some RandomSplitter {
        return CheckedRandomSplitter(seed: self.nextLong())
    }

    public mutating func skip(calls: UInt) {
        for _ in 0..<calls {
            let _ = self.next(bits: 32)
        }
    }

    func compareForTest(expectedSeed: UInt64) -> Bool {
        return self.seed == expectedSeed
    }
}

public struct CheckedRandomSplitter: RandomSplitter {
    public typealias ReturnedRandom = CheckedRandom

    private let seed: UInt64

    public init(seed: UInt64) {
        self.seed = seed
    }

    public func split(usingPos pos: PosInt3D) -> ReturnedRandom {
        let l: UInt64 = UInt64(pos.x) &* 3129871 ^ UInt64(pos.z) &* 116129781 ^ UInt64(pos.y)
        let m = l &* l &* 42317861 + l &* 11
        return CheckedRandom(seed: (m >> 16) ^ self.seed)
    }

    public func split(usingString string: String) -> ReturnedRandom {
        fatalError("CheckedRandomSplitter.split(usingString:) is currently unsupported (because I don't think it's ever used)!")
        #warning("Unimplemented function CheckedRandomSplitter.split(usingString:)!")
    }

    public func split(usingLong seed: WorldSeed) -> ReturnedRandom {
        return CheckedRandom(seed: seed)
    }
}

/// A more sophisticated random number generator used by Minecraft for most things.
public struct XoroshiroRandom: Random {
    private var seedLo, seedHi: UInt64

    private static func mixStafford13(seed: UInt64) -> UInt64 {
        let m = (seed ^ seed >> 30) &* overflow(-4658895280553007687);
        let n = (m ^ m >> 27) &* overflow(-7723592293110705685);
        return n ^ n >> 31;
    }

    public init(seed: UInt64) {
        self.seedLo = seed ^ 7640891576956012809;
        self.seedHi = self.seedLo &+ overflow(-7046029254386353131);
        self.seedLo = XoroshiroRandom.mixStafford13(seed: self.seedLo)
        self.seedHi = XoroshiroRandom.mixStafford13(seed: self.seedHi)
    }

    public init(seedLo: UInt64, seedHi: UInt64) {
        if ((seedLo | seedHi) == 0) {
            self.seedLo = overflow(-7046029254386353131)
            self.seedHi = 7640891576956012809
        } else {
            self.seedLo = seedLo
            self.seedHi = seedHi
        }
    }

    public mutating func nextLong() -> UInt64 {
        let lo = self.seedLo
        let hi = self.seedHi
        let ret = rotateLeft(lo &+ hi, 17) &+ lo
        let m = hi ^ lo
        self.seedLo = rotateLeft(lo, 49) ^ m ^ (m << 21)
        self.seedHi = rotateLeft(m, 28)
        return ret
    }

    public mutating func nextInt() -> UInt32 {
        return UInt32(truncatingIfNeeded: self.nextLong())
    }

    private static let BITMASK_32: UInt64 = (1 << 32) - 1

    public mutating func next(bound: UInt32) -> UInt32 {
        let l = UInt64(self.nextInt());
        var m = l &* UInt64(bound);
        var n = m & XoroshiroRandom.BITMASK_32;

        if n < bound {
            let j = (~bound + 1) % bound
            while n < j {
                m = UInt64(self.nextInt()) &* UInt64(bound)
                n = m & XoroshiroRandom.BITMASK_32
            }
        }

        return UInt32(m >> 32);
    }

    public mutating func nextFloat() -> Float {
        return Float(self.nextLong() >> (64 - 24)) * 5.9604645e-8
    }

    public mutating func nextDouble() -> Double {
        return Double(self.nextLong() >> (64 - 53)) * 1.1102230246251565E-16
    }

    public mutating func nextSplitter() -> some RandomSplitter {
        return XoroshiroRandomSplitter(seedLo: self.nextLong(), seedHi: self.nextLong())
    }

    public mutating func skip(calls: UInt) {
        for _ in 0..<calls {
            let _ = self.nextLong()
        }
    }

    func compareForTest(expectedState: XoroshiroRandom) -> Bool {
        return self.seedLo == expectedState.seedLo && self.seedHi == expectedState.seedHi
    }
}

public struct XoroshiroRandomSplitter: RandomSplitter {
    public typealias ReturnedRandom = XoroshiroRandom

    private let seedLo: UInt64
    private let seedHi: UInt64

    public init(seedLo: UInt64, seedHi: UInt64) {
        self.seedLo = seedLo
        self.seedHi = seedHi
    }

    public func split(usingPos pos: PosInt3D) -> ReturnedRandom {
        let l: UInt64 = UInt64(pos.x) * 3129871 ^ UInt64(pos.z) * 116129781 ^ UInt64(pos.y)
        let m = l * l * 42317861 + l * 11
        return XoroshiroRandom(seedLo: m ^ self.seedLo, seedHi: self.seedHi)
    }

    public func split(usingString string: String) -> ReturnedRandom {
        let hashBytes = string.bytes.md5()
        let lo = hashBytes[0..<8].reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
        let hi = hashBytes[8..<16].reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
        return XoroshiroRandom(seedLo: lo ^ self.seedLo, seedHi: hi ^ self.seedHi)
    }

    public func split(usingLong seed: WorldSeed) -> ReturnedRandom {
        return XoroshiroRandom(seedLo: seed ^ self.seedLo, seedHi: seed ^ self.seedHi)
    }
}

/// ----- Noise -----

private let GRADIENTS: Array<Array<Double>> = [
    [1, 1, 0],
    [-1, 1, 0],
    [1, -1, 0],
    [-1, -1, 0],
    [1, 0, 1],
    [-1, 0, 1],
    [1, 0, -1],
    [-1, 0, -1],
    [0, 1, 1],
    [0, -1, 1],
    [0, 1, -1],
    [0, -1, -1],
    [1, 1, 0],
    [0, -1, 1],
    [-1, 1, 0],
    [0, -1, -1]
]
private let SQRT_3 = (3.0).squareRoot()
private let SKEW_FACTOR_2D = 0.5 * (SQRT_3 - 1.0)
private let UNSKEW_FACTOR_2D = (3.0 - SQRT_3) / 6.0

@inline(__always) private func dot(_ gradient: Array<Double>, _ x: Double, _ y: Double, _ z: Double) -> Double {
    let gradX = gradient[0] * x
    let gradY = gradient[1] * y
    let gradZ = gradient[2] * z
    return gradX + gradY + gradZ
}

@inline(__always) private func grad(hash: Int, x: Double, y: Double, z: Double) -> Double {
    let h = hash & 0xF
    let u = h < 8 ? x : y
    let v = h < 4 ? y : (h == 12 || h == 14 ? x : z)
    let uVal = (h & 1) == 0 ? u : -u
    let vVal = (h & 2) == 0 ? v : -v
    return uVal + vVal
}

@inline(__always) private func perlinFade(_ value: Double) -> Double {
    return value * value * value * (value * (value * 6.0 - 15.0) + 10.0)
}

// For end islands.
public class SimplexNoise {
    private let permutation: [UInt8]
    private let originX, originY, originZ: Double

    public init<R: Random>(random rng: inout R) {
        self.originX = rng.nextDouble() * 256.0
        self.originY = rng.nextDouble() * 256.0
        self.originZ = rng.nextDouble() * 256.0

        var permutation: [UInt8] = Array<UInt8>(0...255)
        for i in 0...255 {
            let j = Int(rng.next(bound: 256 - UInt32(i))) + i
            permutation.swapAt(i, j)
        }
        self.permutation = permutation
    }

    private func map(_ input: Int) -> Int {
        return Int(self.permutation[input & 0xFF])
    }

    private func grad(hash: Int, x: Double, y: Double, z: Double, distance: Double) -> Double {
        let d = distance - x * x - y * y - z * z
        return d < 0.0 ? 0.0 : d * d * d * d * dot(GRADIENTS[hash], x, y, z)
    }

    public func sample(x: Double, y: Double) -> Double {
        let skew = (x + y) * SKEW_FACTOR_2D
        let skewedX = Int((x + skew).rounded(FloatingPointRoundingRule.down))
        let skewedY = Int((y + skew).rounded(FloatingPointRoundingRule.down))
        let unskewedSum = Double(skewedX + skewedY) * UNSKEW_FACTOR_2D
        let unskewedX = Double(skewedX) - unskewedSum
        let unskewedY = Double(skewedY) - unskewedSum
        let remainderX = x - unskewedX
        let remainderY = y - unskewedY
        let factorX: Int, factorY: Int
        if (remainderX > remainderY) {
            factorX = 1;
            factorY = 0;
        } else {
            factorX = 0;
            factorY = 1;
        }
        let gradX = remainderX - Double(factorX) + UNSKEW_FACTOR_2D;
        let gradY = remainderY - Double(factorY) + UNSKEW_FACTOR_2D;
        let unskewedRemainderX = remainderX - 1.0 + 2.0 * UNSKEW_FACTOR_2D;
        let unskewedRemainerY = remainderY - 1.0 + 2.0 * UNSKEW_FACTOR_2D;
        let hashX = skewedX & 0xFF;
        let hashY = skewedY & 0xFF;
        let hashRemainderPart = self.map(hashX + self.map(hashY)) % 12;
        let hashGradPart = self.map(hashX + factorX + self.map(hashY + factorY)) % 12;
        let hashUnskewedPart = self.map(hashX + 1 + self.map(hashY + 1)) % 12;
        let remainderPart = self.grad(hash: hashRemainderPart, x: remainderX, y: remainderY, z: 0.0, distance: 0.5);
        let gradPart = self.grad(hash: hashGradPart, x: gradX, y: gradY, z: 0.0, distance: 0.5);
        let unskewedPart = self.grad(hash: hashUnskewedPart, x: unskewedRemainderX, y: unskewedRemainerY, z: 0.0, distance: 0.5);
        return 70.0 * (remainderPart + gradPart + unskewedPart);
    }

    /// NOTE: This function rounds `originX`, `originY`, and `originZ` to the nearest whole number to facilitate comparison.
    /// It is not the most reliable function (but they should match if the xoroshiro tests pass).
    func compareForTest(permutation: [UInt8], originX: Double, originY: Double, originZ: Double) -> Bool {
        let ret = self.originX.rounded() == originX.rounded() && self.originY.rounded() == originY.rounded() && self.originZ.rounded() == originZ.rounded() && self.permutation == permutation
        if !ret {
            print("self.originX = ", self.originX, ", self.originY = ", self.originY, ", self.originZ = ", self.originZ, ", self.permutation = ", self.permutation, separator: "")
        }
        return ret
    }
}

public class PerlinNoise {
    private let permutation: [UInt8]
    private let permutationInts: [Int]
    private let originX, originY, originZ: Double

    public init<R: Random>(random rng: inout R) {
        self.originX = rng.nextDouble() * 256.0
        self.originY = rng.nextDouble() * 256.0
        self.originZ = rng.nextDouble() * 256.0

        var permutation: [UInt8] = Array<UInt8>(0...255)
        for i in 0...255 {
            let j = Int(rng.next(bound: 256 - UInt32(i))) + i
            permutation.swapAt(i, j)
        }
        self.permutation = permutation
        self.permutationInts = permutation.map { Int($0) }
    }

    public init<R: Random>(immutableRandom irng: R) {
        var rng = irng
        self.originX = rng.nextDouble() * 256.0
        self.originY = rng.nextDouble() * 256.0
        self.originZ = rng.nextDouble() * 256.0

        var permutation: [UInt8] = Array<UInt8>(0...255)
        for i in 0...255 {
            let j = Int(rng.next(bound: 256 - UInt32(i))) + i
            permutation.swapAt(i, j)
        }
        self.permutation = permutation
        self.permutationInts = permutation.map { Int($0) }
    }

    public func sample(x: Double, y: Double, z: Double) -> Double {
        let sampleX = x + self.originX
        let sampleY = y + self.originY
        let sampleZ = z + self.originZ

        let sectionX = floor(sampleX)
        let sectionY = floor(sampleY)
        let sectionZ = floor(sampleZ)

        let localX = sampleX - sectionX
        let localY = sampleY - sectionY
        let localZ = sampleZ - sectionZ

        return self.sampleInternal(Int(sectionX), Int(sectionY), Int(sectionZ), localX, localY, localZ, localY)
    }

    @inline(__always) public func sample(x: Double, y: Double, z: Double, yScale: Double, yMax: Double) -> Double {
        let sampleX = x + self.originX
        let sampleY = y + self.originY
        let sampleZ = z + self.originZ

        let sectionX = floor(sampleX)
        let sectionY = floor(sampleY)
        let sectionZ = floor(sampleZ)

        let localX = sampleX - sectionX
        let localY = sampleY - sectionY
        let localZ = sampleZ - sectionZ

        let localYOffset: Double
        if (yScale != 0.0) {
            let r = yMax >= 0.0 && yMax < localY ? yMax : localY
            // Minecraft adds 1.0e-7 to (r / yScale), but Cubiomes does not.
            // After speaking to some people in Minecraft@Home, I've decided to add it here.
            localYOffset = (r / yScale + 1.0e-7).rounded(FloatingPointRoundingRule.down) * yScale
        } else {
            localYOffset = 0.0
        }

        return self.sampleInternal(Int(sectionX), Int(sectionY), Int(sectionZ), localX, localY - localYOffset, localZ, localY)
    }

    @inline(__always) private func map(_ input: Int) -> Int {
        return self.permutationInts[input & 0xFF]
    }

    @inline(__always) private func sampleInternal(_ sectionX: Int, _ sectionY: Int, _ sectionZ: Int, _ localX: Double, _ localY: Double, _ localZ: Double, _ fadeLocalY: Double) -> Double {
        let x0 = self.map(sectionX)
        let x1 = self.map(sectionX + 1)
        let x0y0 = self.map(x0 + sectionY)
        let x0y1 = self.map(x0 + sectionY + 1)
        let x1y0 = self.map(x1 + sectionY)
        let x1y1 = self.map(x1 + sectionY + 1)
        let x0y0z0 = grad(hash: self.map(x0y0 + sectionZ),      x: localX,          y: localY,          z: localZ);
        let x1y0z0 = grad(hash: self.map(x1y0 + sectionZ),      x: localX - 1.0,    y: localY,          z: localZ);
        let x0y1z0 = grad(hash: self.map(x0y1 + sectionZ),      x: localX,          y: localY - 1.0,    z: localZ);
        let x1y1z0 = grad(hash: self.map(x1y1 + sectionZ),      x: localX - 1.0,    y: localY - 1.0,    z: localZ);
        let x0y0z1 = grad(hash: self.map(x0y0 + sectionZ + 1),  x: localX,          y: localY,          z: localZ - 1.0);
        let x1y0z1 = grad(hash: self.map(x1y0 + sectionZ + 1),  x: localX - 1.0,    y: localY,          z: localZ - 1.0);
        let x0y1z1 = grad(hash: self.map(x0y1 + sectionZ + 1),  x: localX,          y: localY - 1.0,    z: localZ - 1.0);
        let x1y1z1 = grad(hash: self.map(x1y1 + sectionZ + 1),  x: localX - 1.0,    y: localY - 1.0,    z: localZ - 1.0);
        let dx = perlinFade(localX);
        let dy = perlinFade(fadeLocalY);
        let dz = perlinFade(localZ);
        return lerp3(deltaX: dx, deltaY: dy, deltaZ: dz, x0y0z0: x0y0z0, x1y0z0: x1y0z0, x0y1z0: x0y1z0, x1y1z0: x1y1z0, x0y0z1: x0y0z1, x1y0z1: x1y0z1, x0y1z1: x0y1z1, x1y1z1: x1y1z1);
    }

    /// NOTE: This function rounds `originX`, `originY`, and `originZ` to the nearest whole number to facilitate comparison.
    /// It is not the most reliable function (but they should match if the xoroshiro tests pass).
    func compareForTest(permutation: [UInt8], originX: Double, originY: Double, originZ: Double) -> Bool {
        let ret = self.originX.rounded() == originX.rounded() && self.originY.rounded() == originY.rounded() && self.originZ.rounded() == originZ.rounded() && self.permutation == permutation
        if !ret {
            print("self.originX = ", self.originX, ", self.originY = ", self.originY, ", self.originZ = ", self.originZ, ", self.permutation = ", self.permutation, separator: "")
        }
        return ret
    }
}

public class OctavePerlinNoise {
    private let octaves: [Octave]

    public init<R: Random>(random rng: inout R, firstOctave: Int, amplitudes: [Double], useModernInitialization: Bool) {
        if !useModernInitialization {
            debugPrint("WARNING: OctavePerlinNoise.init(useModernInitialization:false) is not tested. Proceed with caution.")
        }

        let numOctaves = amplitudes.count
        var octaves = Array<Octave>()
        octaves.reserveCapacity(numOctaves)
        let lastOctave = firstOctave + numOctaves - 1
        var amplitudeModifier = Double(1 << (numOctaves - 1)) / (Double(1 << numOctaves) - 1.0)
        var lacunarity = 1.0 / Double(1 << -firstOctave)
        if useModernInitialization {
            let splitter = rng.nextSplitter()
            for octaveIndex in 0..<numOctaves {
                if amplitudes[octaveIndex] != 0.0 {
                    octaves.append(Octave(noise: PerlinNoise(immutableRandom: splitter.split(usingString: "octave_" + String(firstOctave + octaveIndex))), amplitude: amplitudes[octaveIndex] * amplitudeModifier, lacunarity: lacunarity))
                }
                amplitudeModifier *= 0.5
                lacunarity *= 2.0
            }
        } else {
            let hasLastOctaveAtZero = lastOctave == 0
            if hasLastOctaveAtZero {
                octaves.append(Octave(noise: PerlinNoise(random: &rng), amplitude: amplitudes[lastOctave] * amplitudeModifier, lacunarity: lacunarity))
                amplitudeModifier *= 0.5
                lacunarity *= 2.0
            } else {
                rng.skip(calls: UInt(lastOctave * -262))
            }

            let range = hasLastOctaveAtZero ? 1..<numOctaves : 0..<numOctaves
            for octaveIndex in range {
                octaves.append(Octave(noise: PerlinNoise(random: &rng), amplitude: amplitudes[octaveIndex] * amplitudeModifier, lacunarity: lacunarity))
                amplitudeModifier *= 0.5
                lacunarity *= 2.0
            }
        }

        self.octaves = octaves
    }

    @inline(__always) public func sample(x: Double, y: Double, z: Double) -> Double {
        var out = 0.0
        for octave in self.octaves {
            out += octave.sample(x: x, y: y, z: z)
        }
        return out
    }

    private struct Octave {
        let noise: PerlinNoise
        let amplitude: Double
        let lacunarity: Double

        func sample(x: Double, y: Double, z: Double) -> Double {
            return self.amplitude * self.noise.sample(x: self.lacunarity * x, y: self.lacunarity * y, z: self.lacunarity * z)
        }
    }
}

public class DoublePerlinNoise {
    internal let firstSampler: OctavePerlinNoise
    internal let secondSampler: OctavePerlinNoise
    private let amplitude: Double
    private static let multiplier = 337.0 / 331.0

    public init<R: Random>(random rng: inout R, firstOctave: Int, amplitudes: [Double], useModernInitialization: Bool) {
        self.firstSampler = OctavePerlinNoise(random: &rng, firstOctave: firstOctave, amplitudes: amplitudes, useModernInitialization: useModernInitialization)
        self.secondSampler = OctavePerlinNoise(random: &rng, firstOctave: firstOctave, amplitudes: amplitudes, useModernInitialization: useModernInitialization)

        // remove amplitudes of zero from front and back
        var octaves = amplitudes.count - 1
        while amplitudes[octaves] == 0.0 { octaves -= 1 }
        // correct for removing the earlier octave
        octaves = octaves + 1
        var i = 0
        while amplitudes[i] == 0.0 { octaves -= 1; i += 1 }
        self.amplitude = (5.0 / 3.0) * Double(octaves) / Double(octaves + 1)
    }

    @inline(__always) public func sample(x: Double, y: Double, z: Double) -> Double {
        let firstOutput = self.firstSampler.sample(x: x, y: y, z: z)
        let secondOutput = self.secondSampler.sample(
            x: x * DoublePerlinNoise.multiplier,
            y: y * DoublePerlinNoise.multiplier,
            z: z * DoublePerlinNoise.multiplier
        )
        return self.amplitude * (firstOutput + secondOutput)
    }
}

public class InterpolatedNoise: DensityFunction {
    private let xzScale: Double, yScale: Double
    private let scaledXZScale: Double, scaledYScale: Double
    private let xzFactor: Double, yFactor: Double
    private let smearScaleMultiplier: Double
    private let lowerInterpolatedOctaves: [PerlinNoise]
    private let upperInterpolatedOctaves: [PerlinNoise]
    private let interpolationOctaves: [PerlinNoise]

    private static func initOctaves<R: Random>(random rng: inout R, count: UInt) -> [PerlinNoise] {
        var octaves: [PerlinNoise] = []
        for _ in 0..<count {
            octaves.append(PerlinNoise(random: &rng))
        }
        return octaves
    }

    public init<R: Random>(random rng: inout R, xzScale: Double, yScale: Double, xzFactor: Double, yFactor: Double, smearScaleMultiplier: Double) {
        self.xzScale = xzScale
        self.yScale = yScale
        self.xzFactor = xzFactor
        self.yFactor = yFactor
        self.smearScaleMultiplier = smearScaleMultiplier
        self.scaledXZScale = xzScale * 684.412
        self.scaledYScale = yScale * 684.412

        self.lowerInterpolatedOctaves = InterpolatedNoise.initOctaves(random: &rng, count: 16)
        self.upperInterpolatedOctaves = InterpolatedNoise.initOctaves(random: &rng, count: 16)
        self.interpolationOctaves = InterpolatedNoise.initOctaves(random: &rng, count: 8)
    }

    required public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.xzScale = try container.decode(Double.self, forKey: .xzScale)
        self.xzFactor = try container.decode(Double.self, forKey: .xzFactor)
        self.yScale = try container.decode(Double.self, forKey: .yScale)
        self.yFactor = try container.decode(Double.self, forKey: .yFactor)
        self.smearScaleMultiplier = try container.decode(Double.self, forKey: .smearScaleMultiplier)

        self.scaledXZScale = xzScale * 684.412
        self.scaledYScale = yScale * 684.412

        var rng: any Random = CheckedRandom(seed: 0)
        self.lowerInterpolatedOctaves = InterpolatedNoise.initOctaves(random: &rng, count: 16)
        self.upperInterpolatedOctaves = InterpolatedNoise.initOctaves(random: &rng, count: 16)
        self.interpolationOctaves = InterpolatedNoise.initOctaves(random: &rng, count: 8)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode("minecraft:old_blended_noise", forKey: .type)
        try container.encode(self.xzScale, forKey: .xzScale)
        try container.encode(self.xzFactor, forKey: .xzFactor)
        try container.encode(self.yScale, forKey: .yScale)
        try container.encode(self.yFactor, forKey: .yFactor)
        try container.encode(self.smearScaleMultiplier, forKey: .smearScaleMultiplier)
    }

    public func copy(withRandom rng: inout any Random) -> InterpolatedNoise {
        return InterpolatedNoise(
            random: &rng,
            xzScale: self.xzScale,
            yScale: self.yScale,
            xzFactor: self.xzFactor,
            yFactor: self.yFactor,
            smearScaleMultiplier: self.smearScaleMultiplier
        )
    }

    /// Because `InterpolatedNoise` is a density function, it uses ints instead of doubles.
    public func sample(at pos: PosInt3D) -> Double {
        let scaledX = Double(pos.x) * self.scaledXZScale
        let scaledY = Double(pos.y) * self.scaledYScale
        let scaledZ = Double(pos.z) * self.scaledXZScale
        let factoredX = scaledX / self.xzFactor
        let factoredY = scaledY / self.yFactor
        let factoredZ = scaledZ / self.xzFactor
        let smearedYScale = self.scaledYScale * self.smearScaleMultiplier
        let factoredYScale = smearedYScale / self.yFactor
        var lowerTotal = 0.0, upperTotal = 0.0, interpolationTotal = 0.0
        var factor = 1.0

        for sampler in self.interpolationOctaves {
            interpolationTotal += sampler.sample(x: factoredX * factor, y: factoredY * factor, z: factoredZ * factor, yScale: factoredYScale * factor, yMax: factoredY * factor) / factor
            factor *= 0.5
        }

        let rescaledInterpolationTotal = (interpolationTotal / 10.0 + 1.0) / 2.0
        let useLower = rescaledInterpolationTotal < 1.0, useUpper = rescaledInterpolationTotal > 0.0
        factor = 1.0

        for idx in 0..<16 {
            let samplingX = scaledX * factor, samplingY = scaledY * factor, samplingZ = scaledZ * factor
            let yScale = smearedYScale * factor

            if useLower {
                let sampler = self.lowerInterpolatedOctaves[idx]
                lowerTotal += sampler.sample(x: samplingX, y: samplingY, z: samplingZ, yScale: yScale, yMax: samplingY) / factor
            }
            if useUpper {
                let sampler = self.upperInterpolatedOctaves[idx]
                upperTotal += sampler.sample(x: samplingX, y: samplingY, z: samplingZ, yScale: yScale, yMax: samplingY) / factor
            }

            factor *= 0.5
        }

        // These are equivalent expressions, but only having to do one division is better than having to do three
        //return clampedLerp(delta: rescaledInterpolationTotal, start: lowerTotal / 512.0, end: upperTotal / 512.0) / 128.0
        return clampedLerp(delta: rescaledInterpolationTotal, start: lowerTotal, end: upperTotal) / 65536.0
    }

    public func bake(withBaker baker: any DensityFunctionBaker) throws -> any DensityFunction {
        return try baker.bake(interpolatedNoise: self)
    }

    private enum CodingKeys: String, CodingKey {
        case type = "type"
        case xzScale = "xz_scale"
        case yScale = "y_scale"
        case xzFactor = "xz_factor"
        case yFactor = "y_factor"
        case smearScaleMultiplier = "smear_scale_multiplier"
    }
}
