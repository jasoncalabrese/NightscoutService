//
//  StoredHealthSample.swift
//  NightscoutServiceKit
//
//  Nightscout activity records for step and physical effort samples (custom)
//

import Foundation
import LoopKit

extension StoredHealthSample {
    /// The kinds uploaded to Nightscout's activity collection
    static let nightscoutActivityKinds: Set<Kind> = [.stepCount, .physicalEffort]

    /// How far back a first upload reaches
    static let nightscoutActivityBackfill: TimeInterval = .hours(24 * 30)

    /// One record per HealthKit sample. `identifier` is the sample's UUID, so a record can be
    /// matched to its sample; HealthKit anchors make sure each sample is sent once.
    func nightscoutActivity(enteredBy: String) -> [String: Any]? {
        guard Self.nightscoutActivityKinds.contains(kind) else {
            return nil
        }
        let formatter = ISO8601DateFormatter()
        var record: [String: Any] = [
            "identifier": uuid.uuidString,
            "created_at": formatter.string(from: startDate),
            "timeStamp": Int((startDate.timeIntervalSince1970 * 1000).rounded()),
            "startDate": formatter.string(from: startDate),
            "endDate": formatter.string(from: endDate),
            "duration": endDate.timeIntervalSince(startDate) / 60,  // minutes
            "enteredBy": enteredBy,
            "source": source.name,
        ]
        switch kind {
        case .stepCount:
            record["type"] = "steps"
            record["steps"] = Int(value.rounded())
        case .physicalEffort:
            record["type"] = "physical-effort"
            record["physicalEffort"] = value
            record["units"] = kind.unitString
        default:
            return nil
        }
        if let deviceName = device?.name {
            record["device"] = deviceName
        }
        return record
    }
}

extension Array where Element == StoredHealthSample {
    /// Records for the uploaded kinds that end within the backfill window
    func nightscoutActivity(enteredBy: String, now: Date = Date()) -> [[String: Any]] {
        let earliest = now.addingTimeInterval(-StoredHealthSample.nightscoutActivityBackfill)
        return filter { $0.endDate >= earliest }.compactMap { $0.nightscoutActivity(enteredBy: enteredBy) }
    }
}
