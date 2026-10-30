import XCTest
@testable import WhisperBoard

final class CallProbeLogicTests: XCTestCase {

    func testFrameRoundTrips() {
        let frame = ProbeFrame(seq: 0x0102_0304_0506_0708, capturedMs: 123_456_789, levelDb: -42.5)
        let data = frame.encoded()
        XCTAssertEqual(data.count, ProbeFrame.byteCount)
        XCTAssertEqual(ProbeFrame.decoded(from: data), frame)
    }

    func testFrameCarriesNothingButZerosAfterTheLevel() {
        let bytes = [UInt8](ProbeFrame(seq: 9, capturedMs: 9, levelDb: -3).encoded())
        XCTAssertTrue(bytes[24...].allSatisfy { $0 == 0 })
    }

    func testFrameWithAnythingInThePaddingIsRefused() {
        var bytes = [UInt8](ProbeFrame(seq: 1, capturedMs: 1, levelDb: 0).encoded())
        bytes[59] = 1
        XCTAssertNil(ProbeFrame.decoded(from: Data(bytes)))
    }

    func testWrongSizeOrMagicIsRefused() {
        XCTAssertNil(ProbeFrame.decoded(from: Data(repeating: 0, count: 59)))
        XCTAssertNil(ProbeFrame.decoded(from: Data(repeating: 0, count: 60)))
    }

    func testLinkGoesDeadAtThreeSecondsOfSilenceAndOnlyOnce() {
        var monitor = LinkMonitor(deadAfter: 3, now: 100)
        monitor.heard(now: 100)
        XCTAssertFalse(monitor.tick(now: 102.9))
        XCTAssertEqual(monitor.state, .alive)
        XCTAssertTrue(monitor.tick(now: 103))
        XCTAssertEqual(monitor.state, .dead)
        XCTAssertFalse(monitor.tick(now: 110))
    }

    func testAPongKeepsTheLinkAliveAndMeasuresTheRoundTrip() {
        var monitor = LinkMonitor(deadAfter: 3, now: 100)
        monitor.pong(now: 102.5, sentAt: 102.42)
        XCTAssertFalse(monitor.tick(now: 105))
        XCTAssertEqual(monitor.rttMs, 80)
    }

    func testAFailedConnectionAttemptAlsoGoesDead() {
        var monitor = LinkMonitor(deadAfter: 3, now: 100)
        XCTAssertEqual(monitor.state, .connecting)
        XCTAssertTrue(monitor.tick(now: 103.5))
    }

    func testBackoffCapsAtFourSecondsAndResets() {
        var backoff = ReconnectBackoff()
        XCTAssertEqual((0..<5).map { _ in backoff.nextDelay() }, [0.5, 1, 2, 4, 4])
        backoff.reset()
        XCTAssertEqual(backoff.nextDelay(), 0.5)
    }

    func testLevelOfSilenceIsTheFloorAndFullScaleIsZero() {
        let silence = [Float](repeating: 0, count: 960)
        let full = [Float](repeating: 1, count: 960)
        XCTAssertEqual(silence.withUnsafeBufferPointer(LevelMeter.decibels), LevelMeter.floorDb)
        XCTAssertEqual(full.withUnsafeBufferPointer(LevelMeter.decibels), 0, accuracy: 0.001)
    }

    func testSiriSpellingsOfTheLine() {
        for name in ["Number One", "number 1", "No. 1", "Ruminate"] {
            XCTAssertTrue(ProbeLine.isExactMatch(name), name)
        }
        XCTAssertFalse(ProbeLine.isExactMatch("Picard"))
    }
}
