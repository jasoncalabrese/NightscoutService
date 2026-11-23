//
//  OpenSuspendTestCase.swift
//  NightscoutServiceKitTests
//
//  An open suspend (pod failed, no replacement) shows as a zero temp running past now,
//  re-uploaded each cycle until the real end arrives. (custom)
//

import XCTest
import LoopKit
import NightscoutKit
@testable import NightscoutServiceKit

class OpenSuspendTestCase: XCTestCase {

    private func suspend(startedAgo age: TimeInterval, duration: TimeInterval? = nil, syncIdentifier: String = "suspend-1") -> DoseEntry {
        let start = Date().addingTimeInterval(-age)
        return DoseEntry(type: .suspend, startDate: start, endDate: duration.map { start.addingTimeInterval($0) }, value: 0, unit: .units, syncIdentifier: syncIdentifier)
    }

    private func duration(of dose: DoseEntry) -> TimeInterval? {
        return (dose.treatment(enteredBy: "test", withObjectId: nil) as? TempBasalNightscoutTreatment)?.duration
    }

    func testOpenSuspendUploadsAsZeroTempRunningPastNow() {
        let dose = suspend(startedAgo: 60 * 60)
        XCTAssertTrue(dose.isOpenSuspend)
        XCTAssertEqual(duration(of: dose) ?? 0, 60 * 60 + DoseEntry.openSuspendLookahead, accuracy: 5)
    }

    func testClosedSuspendKeepsItsDuration() {
        let dose = suspend(startedAgo: 60 * 60, duration: 20 * 60)
        XCTAssertFalse(dose.isOpenSuspend)
        XCTAssertEqual(duration(of: dose) ?? 0, 20 * 60, accuracy: 0.001)
    }

    func testTrackOpenSuspendSetAndCleared() {
        let service = NightscoutService()
        let open = suspend(startedAgo: 60 * 60)

        service.trackOpenSuspend(from: [open])
        XCTAssertEqual(service.openSuspend?.syncIdentifier, open.syncIdentifier)

        // The same suspend arriving closed (resumed) ends it
        service.trackOpenSuspend(from: [suspend(startedAgo: 60 * 60, duration: 30 * 60)])
        XCTAssertNil(service.openSuspend)

        // A later dose ends it too
        service.trackOpenSuspend(from: [open])
        let resume = DoseEntry(resumeDate: Date().addingTimeInterval(-5 * 60))
        service.trackOpenSuspend(from: [resume])
        XCTAssertNil(service.openSuspend)

        // Earlier doses don't
        service.trackOpenSuspend(from: [open])
        let earlierTempBasal = DoseEntry(type: .tempBasal, startDate: Date().addingTimeInterval(-2 * 60 * 60), endDate: Date().addingTimeInterval(-90 * 60), value: 1, unit: .unitsPerHour)
        service.trackOpenSuspend(from: [earlierTempBasal])
        XCTAssertNotNil(service.openSuspend)
    }

    func testTrackOpenSuspendStopsAfterRefreshLimit() {
        let service = NightscoutService()
        service.trackOpenSuspend(from: [suspend(startedAgo: NightscoutService.openSuspendRefreshLimit + 60)])
        XCTAssertNil(service.openSuspend)
    }

    func testOpenSuspendSurvivesRestart() {
        let service = NightscoutService()
        let open = suspend(startedAgo: 60 * 60)
        service.trackOpenSuspend(from: [open])

        let restored = NightscoutService(rawState: service.rawState)
        XCTAssertEqual(restored?.openSuspend?.startDate, open.startDate)
        XCTAssertEqual(restored?.openSuspend?.syncIdentifier, open.syncIdentifier)
        XCTAssertTrue(restored?.openSuspend?.isOpenSuspend ?? false)
    }
}
