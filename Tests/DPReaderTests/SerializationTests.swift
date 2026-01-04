import Foundation
import Testing
@testable import DPReader

@Test func testNoiseDefinition() async throws {
    let json = """
        {
            "amplitudes": [1.5, 1.0],
            "firstOctave": -10
        }
    """.data(using: String.Encoding.utf8)!
    let decoder = JSONDecoder()
    let value = try decoder.decode(NoiseDefinition.self, from: json)
    #expect(value.testingAttributes.amplitudes == [1.5, 1.0] && value.testingAttributes.firstOctave == -10)
}
