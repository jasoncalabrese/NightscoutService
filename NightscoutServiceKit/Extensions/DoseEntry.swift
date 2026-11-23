//
//  DoseEntry.swift
//  NightscoutServiceKit
//
//  Created by Darin Krauss on 6/20/19.
//  Copyright © 2019 LoopKit Authors. All rights reserved.
//

import LoopKit
import NightscoutKit

extension DoseEntry {

    /// How far past now an open suspend's zero temp is shown (custom)
    static let openSuspendLookahead = TimeInterval(30 * 60)

    /// A suspend with no end yet (custom)
    var isOpenSuspend: Bool {
        return type == .suspend && endDate <= startDate
    }

    func treatment(enteredBy source: String, withObjectId objectId: String?) -> NightscoutTreatment? {
        let duration = endDate.timeIntervalSince(startDate)

        switch type {
        case .basal:
            return nil
        case .bolus:
            return BolusNightscoutTreatment(
                timestamp: startDate,
                enteredBy: source,
                bolusType: duration >= TimeInterval(minutes: 30) ? .Square : .Normal,
                amount: deliveredUnits ?? programmedUnits,
                programmed: programmedUnits,  // Persisted pump events are always completed
                unabsorbed: 0,  // The pump's reported IOB isn't relevant, nor stored
                duration: duration,
                automatic: automatic ?? false,
                /* id: objectId, */ /// Specifying _id only works when doing a put (modify); all dose uploads are currently posting so they can be either create or update
                syncIdentifier: syncIdentifier,
                insulinType: insulinType?.brandName
            )
        case .resume:
            return nil
        case .suspend:
            // An open suspend has no end yet; show it running 30 min past now, like a temp basal,
            // and re-upload to extend it until the real end arrives. (custom)
            let suspendDuration = isOpenSuspend ? max(0, Date().timeIntervalSince(startDate)) + DoseEntry.openSuspendLookahead : duration
            // Nightscout does not have a separate "Suspend" treatment. Record a suspend as a temp basal with a reason of "suspend"
            return TempBasalNightscoutTreatment(
                timestamp: startDate,
                enteredBy: source,
                temp: .Absolute,  // DoseEntry only supports .absolute types
                rate: 0,
                absolute: unitsPerHour,
                duration: suspendDuration,
                amount: deliveredUnits,
                automatic: automatic ?? true,
                syncIdentifier: syncIdentifier,
                insulinType: nil,
                reason: "suspend"
            )
        case .tempBasal:
            return TempBasalNightscoutTreatment(
                timestamp: startDate,
                enteredBy: source,
                temp: .Absolute,  // DoseEntry only supports .absolute types
                rate: unitsPerHour,
                absolute: unitsPerHour,
                duration: endDate.timeIntervalSince(startDate),
                amount: deliveredUnits,
                automatic: automatic ?? true,
                /* id: objectId, */ /// Specifying _id only works when doing a put (modify); all dose uploads are currently posting so they can be either create or update
                syncIdentifier: syncIdentifier,
                insulinType: insulinType?.brandName
            )
        }
    }

}
