import XCTest
@testable import Nod

final class SpeakerClustererTests: XCTestCase {
    private let a: [Float] = [1, 0, 0, 0]
    private let b: [Float] = [0, 1, 0, 0]
    private let aNoisy: [Float] = [0.9, 0.1, 0, 0]

    func testAssignMatchesSameVoiceAndOpensNewForDifferent() {
        let clusterer = SpeakerClusterer()
        XCTAssertEqual(clusterer.assign(a), 0)
        XCTAssertEqual(clusterer.assign(a), 0, "identical voiceprint must reuse the speaker")
        XCTAssertEqual(clusterer.assign(b), 1, "orthogonal voiceprint must open a new speaker")
        XCTAssertEqual(clusterer.assign(aNoisy), 0, "a near match must fold into the existing speaker")
        XCTAssertEqual(clusterer.speakerCount, 2)
    }

    func testClusterGroupsByVoiceAndNumbersByFirstAppearance() {
        XCTAssertEqual(SpeakerClusterer.cluster([a, a, b, b]), [0, 0, 1, 1])
        // First voice heard is "speaker 0" regardless of input ordering.
        XCTAssertEqual(SpeakerClusterer.cluster([b, a, a]), [0, 1, 1])
    }

    func testClusterSingleSpeakerStaysOne() {
        XCTAssertEqual(SpeakerClusterer.cluster([a, aNoisy, a]), [0, 0, 0])
    }

    func testClusterEmptyInput() {
        XCTAssertEqual(SpeakerClusterer.cluster([]), [])
    }

    func testDotAndNormalize() {
        XCTAssertEqual(SpeakerClusterer.dot(a, b), 0, accuracy: 1e-6)
        XCTAssertEqual(SpeakerClusterer.dot(a, a), 1, accuracy: 1e-6)
        let n = SpeakerClusterer.normalized([3, 4, 0, 0])
        XCTAssertEqual(n[0], 0.6, accuracy: 1e-6)
        XCTAssertEqual(n[1], 0.8, accuracy: 1e-6)
    }
}
