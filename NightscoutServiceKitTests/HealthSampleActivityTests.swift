//
//  HealthSampleActivityTests.swift
//  NightscoutServiceKitTests
//
//  Step and physical effort samples become Nightscout activity records (custom)
//

import XCTest
import LoopKit
@testable import NightscoutServiceKit

class HealthSampleActivityTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func sample(_ kind: StoredHealthSample.Kind, value: Double, endingAgo: TimeInterval = .minutes(5)) -> StoredHealthSample {
        let end = now.addingTimeInterval(-endingAgo)
        return StoredHealthSample(uuid: UUID(), kind: kind, startDate: end.addingTimeInterval(-TimeInterval.minutes(4)), endDate: end, value: value, source: .init(bundleIdentifier: "com.apple.health", name: "Andrew's iPhone", operatingSystemVersion: "27.2"))
    }

    func testStepSampleBecomesStepsRecord() throws {
        let steps = sample(.stepCount, value: 109.4)
        let record = try XCTUnwrap(steps.nightscoutActivity(enteredBy: "loop://iPhone"))

        XCTAssertEqual(record["type"] as? String, "steps")
        XCTAssertEqual(record["steps"] as? Int, 109)
        XCTAssertEqual(record["identifier"] as? String, steps.uuid.uuidString)
        XCTAssertEqual(record["duration"] as? Double, 4)
        XCTAssertEqual(record["timeStamp"] as? Int, Int(steps.startDate.timeIntervalSince1970 * 1000))
        XCTAssertEqual(record["created_at"] as? String, ISO8601DateFormatter().string(from: steps.startDate))
        XCTAssertEqual(record["endDate"] as? String, ISO8601DateFormatter().string(from: steps.endDate))
        XCTAssertEqual(record["enteredBy"] as? String, "loop://iPhone")
        XCTAssertEqual(record["source"] as? String, "Andrew's iPhone")
    }

    func testPhysicalEffortSampleBecomesEffortRecord() throws {
        let record = try XCTUnwrap(sample(.physicalEffort, value: 6.2).nightscoutActivity(enteredBy: "loop://iPhone"))

        XCTAssertEqual(record["type"] as? String, "physical-effort")
        XCTAssertEqual(record["physicalEffort"] as? Double, 6.2)
        XCTAssertEqual(record["units"] as? String, "kcal/hr/kg")
    }

    func testOtherKindsAreNotUploaded() {
        XCTAssertNil(sample(.heartRate, value: 120).nightscoutActivity(enteredBy: "loop://iPhone"))
        XCTAssertTrue([sample(.bodyMass, value: 50)].nightscoutActivity(enteredBy: "loop://iPhone", now: now).isEmpty)
    }

    func testBackfillReachesThirtyDays() {
        let records = [
            sample(.stepCount, value: 10, endingAgo: .hours(24 * 29)),
            sample(.stepCount, value: 20, endingAgo: .hours(24 * 31)),
        ].nightscoutActivity(enteredBy: "loop://iPhone", now: now)

        XCTAssertEqual(records.map { $0["steps"] as? Int }, [10])
    }
}
