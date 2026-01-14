import Foundation
import Testing
@testable import DPReader

private func checkDouble(_ actualValue: Double, _ roundedExpectedValue: Int) -> Bool {
    let roundedActualValue = Int((actualValue * 1_000_000).rounded(FloatingPointRoundingRule.toNearestOrEven))
    guard roundedExpectedValue == roundedActualValue else {
        print("Error in checkDouble: expected value", roundedExpectedValue, "did not match actual value", actualValue, "(rounded to", roundedActualValue, ")!")
        return false
    }
    return true
}

@Test func testCheckedRandom() async throws {
    let seed: UInt64 = 329532170530278
    var cr = CheckedRandom(seed: seed)
    #expect(cr.compareForTest(expectedSeed: 48038959352715))
    #expect(cr.next(bits: 32) == 1964217917)
    #expect(cr.next(bound: 47) == 13)
    // somewhat redundant test, but good to have
    #expect(cr.compareForTest(expectedSeed: 167197105033405))
}

@Test func testXoroshiroRandom() async throws {
    let seed: UInt64 = 167197105033405
    var xr = XoroshiroRandom(seed: seed)
    #expect(xr.compareForTest(expectedState: XoroshiroRandom(seedLo: 8976544753920022419, seedHi: 12811240938255007451)))
    #expect(xr.nextLong() == 279250396330390606)
    #expect(xr.next(bound: 47) == 35)
    // round to 6 significant figures
    #expect(checkDouble(xr.nextDouble(), 819772))
}

@Test func testMD5() async throws {
    let hashBytes = "octave_-11".bytes.md5()
    let combinedLowBytes = hashBytes[0..<8].reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
    let combinedHighBytes = hashBytes[8..<16].reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
    #expect(combinedLowBytes == 0x0fd787bfbc403ec3)
    #expect(combinedHighBytes == 0x74a4a31ca21b48b8)
}

@Test func testXoroshiroSplitterUsingString() async throws {
    let seed: UInt64 = 167197105033405
    var xr = XoroshiroRandom(seed: seed)
    let splitter = xr.nextSplitter()
    let xr2 = splitter.split(usingString: "octave_-11") as! XoroshiroRandom
    #expect(xr2.compareForTest(expectedState: XoroshiroRandom(seedLo: 880347616643697293, seedHi: 3017999465556954343)))
}

@Test func testPerlinNoise() async throws {
    let seed: UInt64 = 103582038203
    var xr = XoroshiroRandom(seed: seed)
    let noise = PerlinNoise(random: &xr)
    #expect(noise.compareForTest(permutation: [209, 132, 245, 123, 20, 90, 242, 94, 166, 173, 255, 200, 45, 224, 250, 55, 103, 140, 172, 3, 111, 50, 67, 29, 175, 31, 100, 60, 36, 30, 70, 47, 157, 189, 0, 222, 32, 27, 141, 52, 254, 75, 186, 133, 210, 89, 109, 139, 153, 11, 164, 202, 81, 71, 80, 227, 142, 46, 68, 43, 159, 243, 193, 167, 38, 236, 40, 120, 58, 121, 24, 158, 83, 203, 97, 12, 225, 138, 190, 18, 198, 54, 246, 128, 99, 13, 42, 1, 113, 151, 144, 145, 125, 44, 104, 114, 135, 233, 217, 170, 85, 220, 34, 62, 116, 180, 9, 163, 171, 82, 182, 63, 15, 10, 5, 127, 204, 156, 102, 22, 134, 41, 146, 136, 51, 39, 8, 177, 37, 91, 124, 92, 196, 137, 65, 98, 168, 148, 118, 218, 78, 244, 223, 253, 28, 154, 95, 23, 26, 130, 174, 105, 162, 208, 216, 184, 230, 169, 187, 213, 107, 147, 86, 179, 165, 211, 221, 7, 199, 48, 150, 108, 231, 73, 88, 252, 249, 155, 117, 25, 247, 201, 49, 21, 188, 76, 152, 16, 19, 207, 212, 194, 59, 214, 122, 6, 149, 251, 205, 57, 181, 143, 215, 129, 101, 69, 84, 248, 235, 33, 206, 161, 79, 238, 237, 112, 131, 176, 53, 64, 61, 229, 192, 17, 14, 241, 115, 87, 185, 93, 56, 234, 66, 226, 119, 74, 126, 110, 195, 2, 77, 96, 106, 239, 160, 240, 219, 35, 178, 4, 191, 72, 197, 232, 183, 228],
        originX: 7.4859, originY: 243.3, originZ: 56.8863))
    #expect(checkDouble(noise.sample(x: 67, y: 41, z: -32), 173011))
    // This was tested against cubiomes, not vanilla
    #expect(checkDouble(noise.sample(x: -16391203, y: 32105323, z: 25392892), 234528))
}

@Test func testOctavePerlinNoise() async throws {
    let seed: UInt64 = 135701357103567
    var xr = XoroshiroRandom(seed: seed)
    let noise = OctavePerlinNoise(random: &xr, firstOctave: -12, amplitudes: [1.0, 0.5, 0.0, 0.0, 0.0, 0.5], useModernInitialization: true)
    #expect(checkDouble(noise.sample(x: 67, y: 41, z: 32), 122127))
    #expect(checkDouble(noise.sample(x: 67, y: 41, z: -32), 130615))
    #expect(checkDouble(noise.sample(x: -99, y: -43, z: 62), 105898))
    // This was tested against cubiomes, not vanilla
    #expect(checkDouble(noise.sample(x: -28353269, y: -32516609, z: 18239509), 176828))
}

@Test func testDoublePerlinNoise() async throws {
    let seed: UInt64 = 317205307159031
    var xr = XoroshiroRandom(seed: seed)
    let noise = DoublePerlinNoise(random: &xr, firstOctave: -12, amplitudes: [1.0, 0.5, 0.0, 0.0, 0.0, 0.5], useModernInitialization: true)
    #expect(checkDouble(noise.sample(x: -67, y: 41, z: 32), -10581))
    #expect(checkDouble(noise.sample(x: 67, y: -41, z: -32), 5572))
    #expect(checkDouble(noise.sample(x: -99, y: 43, z: -62), -33107))
    // This was tested against cubiomes, not vanilla
    #expect(checkDouble(noise.sample(x: 14253532, y: -3512332, z: -25321807), -99810))
}

@Test func testSimplexNoise() async throws {
    let seed: UInt64 = 103582038203
    var xr = XoroshiroRandom(seed: seed)
    let noise = SimplexNoise(random: &xr)
    #expect(noise.compareForTest(permutation: [209, 132, 245, 123, 20, 90, 242, 94, 166, 173, 255, 200, 45, 224, 250, 55, 103, 140, 172, 3, 111, 50, 67, 29, 175, 31, 100, 60, 36, 30, 70, 47, 157, 189, 0, 222, 32, 27, 141, 52, 254, 75, 186, 133, 210, 89, 109, 139, 153, 11, 164, 202, 81, 71, 80, 227, 142, 46, 68, 43, 159, 243, 193, 167, 38, 236, 40, 120, 58, 121, 24, 158, 83, 203, 97, 12, 225, 138, 190, 18, 198, 54, 246, 128, 99, 13, 42, 1, 113, 151, 144, 145, 125, 44, 104, 114, 135, 233, 217, 170, 85, 220, 34, 62, 116, 180, 9, 163, 171, 82, 182, 63, 15, 10, 5, 127, 204, 156, 102, 22, 134, 41, 146, 136, 51, 39, 8, 177, 37, 91, 124, 92, 196, 137, 65, 98, 168, 148, 118, 218, 78, 244, 223, 253, 28, 154, 95, 23, 26, 130, 174, 105, 162, 208, 216, 184, 230, 169, 187, 213, 107, 147, 86, 179, 165, 211, 221, 7, 199, 48, 150, 108, 231, 73, 88, 252, 249, 155, 117, 25, 247, 201, 49, 21, 188, 76, 152, 16, 19, 207, 212, 194, 59, 214, 122, 6, 149, 251, 205, 57, 181, 143, 215, 129, 101, 69, 84, 248, 235, 33, 206, 161, 79, 238, 237, 112, 131, 176, 53, 64, 61, 229, 192, 17, 14, 241, 115, 87, 185, 93, 56, 234, 66, 226, 119, 74, 126, 110, 195, 2, 77, 96, 106, 239, 160, 240, 219, 35, 178, 4, 191, 72, 197, 232, 183, 228],
        originX: 7.4859, originY: 243.3, originZ: 56.8863))
    #expect(checkDouble(noise.sample(x: 67, y: -41), 449178))
    // This was tested against cubiomes, not vanilla
    #expect(checkDouble(noise.sample(x: 14253532, y: -3512332), 165524))
}

@Test func testInterpolatedNoise() async throws {
    var rng = XoroshiroRandom(seedLo: 15722969251820966311, seedHi: 6104536322537472173)
    let noise = InterpolatedNoise(random: &rng, xzScale: 0.25, yScale: 0.125, xzFactor: 80.0, yFactor: 160.0, smearScaleMultiplier: 8.0)
    #expect(checkDouble(noise.sample(x: 67, y: 41, z: 32), -126696))
    #expect(checkDouble(noise.sample(x: -67, y: -41, z: 32), -043314))
    #expect(checkDouble(noise.sample(x: 84, y: 96, z: -3), -234940))
}