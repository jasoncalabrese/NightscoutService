//
//  NightscoutService.swift
//  NightscoutServiceKit
//
//  Created by Darin Krauss on 6/20/19.
//  Copyright © 2019 LoopKit Authors. All rights reserved.
//

import os.log
import CryptoKit
import HealthKit
import LoopKit
import NightscoutKit

public enum NightscoutServiceError: Error {
    case incompatibleTherapySettings
    case missingCredentials
    case missingCommandSource
    case activityUploadFailed(statusCode: Int)  // (custom)
}


public final class NightscoutService: Service {

    public static let pluginIdentifier = "NightscoutService"

    public static let localizedTitle = LocalizedString("Nightscout", comment: "The title of the Nightscout service")
    
    public let objectIdCacheKeepTime = TimeInterval(24 * 60 * 60)

    public weak var serviceDelegate: ServiceDelegate?
    
    public weak var stateDelegate: StatefulPluggableDelegate?

    public var siteURL: URL?

    public var apiSecret: String?
    
    public var isOnboarded: Bool

    public let otpManager: OTPManager
    
    /// Maps loop syncIdentifiers to Nightscout objectIds
    var objectIdCache: ObjectIdCache {
        get {
            return lockedObjectIdCache.value
        }
        set {
            lockedObjectIdCache.value = newValue
        }
    }
    private let lockedObjectIdCache: Locked<ObjectIdCache>

    /// The open suspend (no end yet) last uploaded, re-uploaded each loop cycle so Nightscout
    /// shows a zero temp running a little past now, like a temp basal. (custom)
    var openSuspend: DoseEntry? {
        get {
            return lockedOpenSuspend.value
        }
        set {
            lockedOpenSuspend.value = newValue
        }
    }
    private let lockedOpenSuspend = Locked<DoseEntry?>(nil)

    /// Stop refreshing an open suspend after this long (custom)
    static let openSuspendRefreshLimit = TimeInterval(24 * 60 * 60)

    private var _uploader: NightscoutClient?

    private var uploader: NightscoutClient? {
        if _uploader == nil {
            guard let siteURL = siteURL, let apiSecret = apiSecret else {
                return nil
            }
            _uploader = NightscoutClient(siteURL: siteURL, apiSecret: apiSecret)
        }
        return _uploader
    }
    
    private let commandSourceV1: RemoteCommandSourceV1

    private let log = OSLog(category: "NightscoutService")

    public init() {
        self.isOnboarded = false
        self.lockedObjectIdCache = Locked(ObjectIdCache())
        self.otpManager = OTPManager(secretStore: KeychainManager())
        self.commandSourceV1 = RemoteCommandSourceV1(otpManager: otpManager)
        self.commandSourceV1.delegate = self
    }

    public required init?(rawState: RawStateValue) {
        self.isOnboarded = rawState["isOnboarded"] as? Bool ?? true   // Backwards compatibility

        if let objectIdCacheRaw = rawState["objectIdCache"] as? ObjectIdCache.RawValue,
            let objectIdCache = ObjectIdCache(rawValue: objectIdCacheRaw)
        {
            self.lockedObjectIdCache = Locked(objectIdCache)
        } else {
            self.lockedObjectIdCache = Locked(ObjectIdCache())
        }
        
        self.otpManager = OTPManager(secretStore: KeychainManager())
        self.commandSourceV1 = RemoteCommandSourceV1(otpManager: otpManager)
        self.commandSourceV1.delegate = self
        
        restoreCredentials()

        if let startDate = rawState["openSuspendStartDate"] as? Date {
            self.openSuspend = DoseEntry(type: .suspend, startDate: startDate, value: 0, unit: .units,
                                         syncIdentifier: rawState["openSuspendSyncIdentifier"] as? String)
        }
    }

    public var rawState: RawStateValue {
        var rawState: RawStateValue = [
            "isOnboarded": isOnboarded,
            "objectIdCache": objectIdCache.rawValue
        ]
        if let openSuspend {
            rawState["openSuspendStartDate"] = openSuspend.startDate
            rawState["openSuspendSyncIdentifier"] = openSuspend.syncIdentifier
        }
        return rawState
    }

    /// Tracks the latest open suspend from a batch of dose uploads. (custom)
    func trackOpenSuspend(from doses: [DoseEntry]) {
        for dose in doses.sorted(by: { $0.startDate < $1.startDate }) {
            switch dose.type {
            case .suspend where dose.isOpenSuspend:
                if openSuspend.map({ dose.startDate >= $0.startDate }) ?? true {
                    openSuspend = dose
                }
            case .suspend, .resume, .tempBasal, .basal:
                // Anything that closes or follows the suspend ends it
                if let suspend = openSuspend, dose.syncIdentifier == suspend.syncIdentifier || dose.startDate >= suspend.startDate {
                    openSuspend = nil
                }
            case .bolus:
                break
            }
        }
        if let suspend = openSuspend, Date().timeIntervalSince(suspend.startDate) > Self.openSuspendRefreshLimit {
            openSuspend = nil
        }
    }

    /// Re-uploads the open suspend with a refreshed duration. (custom)
    private func refreshOpenSuspend(using uploader: NightscoutClient, completion: @escaping () -> Void) {
        trackOpenSuspend(from: [])
        guard let suspend = openSuspend else {
            completion()
            return
        }
        uploader.createDoses([suspend], usingObjectIdCache: objectIdCache) { result in
            if case .failure(let error) = result {
                self.log.error("Failed to refresh open suspend: %{public}@", String(describing: error))
            }
            completion()
        }
    }

    public var lastDosingDecisionForAutomaticDose: StoredDosingDecision?

    public var hasConfiguration: Bool { return siteURL != nil && apiSecret?.isEmpty == false }

    public func verifyConfiguration(completion: @escaping (Error?) -> Void) {
        guard hasConfiguration, let siteURL = siteURL, let apiSecret = apiSecret else {
            completion(NightscoutServiceError.missingCredentials)
            return
        }

        let uploader = NightscoutClient(siteURL: siteURL, apiSecret: apiSecret)
        uploader.checkAuth(completion)
    }

    public func completeCreate() {
        saveCredentials()
    }

    public func completeOnboard() {
        isOnboarded = true

        saveCredentials()
        stateDelegate?.pluginDidUpdateState(self)
    }

    public func completeUpdate() {
        saveCredentials()
        stateDelegate?.pluginDidUpdateState(self)
    }

    public func completeDelete() {
        clearCredentials()
        stateDelegate?.pluginWantsDeletion(self)
    }

    private func saveCredentials() {
        try? KeychainManager().setNightscoutCredentials(siteURL: siteURL, apiSecret: apiSecret)
    }

    public func restoreCredentials() {
        if let credentials = try? KeychainManager().getNightscoutCredentials() {
            self.siteURL = credentials.siteURL
            self.apiSecret = credentials.apiSecret
        }
    }

    public func clearCredentials() {
        siteURL = nil
        apiSecret = nil
        try? KeychainManager().setNightscoutCredentials()
    }
    
}

extension NightscoutService: RemoteDataService {

    public func uploadTemporaryOverrideData(updated: [LoopKit.TemporaryScheduleOverride], deleted: [LoopKit.TemporaryScheduleOverride], completion: @escaping (Result<Bool, Error>) -> Void) {
        guard let uploader = uploader else {
            completion(.success(true))
            return
        }

        let updates = updated.map { OverrideTreatment(override: $0) }

        let deletions = deleted.map { $0.syncIdentifier.uuidString }

        uploader.deleteTreatmentsById(deletions, completionHandler: { (error) in
            if let error = error {
                self.log.error("Overrides deletions failed to delete %{public}@: %{public}@", String(describing: deletions), String(describing: error))
            } else {
                if deletions.count > 0 {
                    self.log.debug("Deleted ids: %@", deletions)
                }
                uploader.upload(updates) { (result) in
                    switch result {
                    case .failure(let error):
                        self.log.error("Failed to upload overrides %{public}@: %{public}@", String(describing: updates.map {$0.dictionaryRepresentation}), String(describing: error))
                        completion(.failure(error))
                    case .success:
                        self.log.debug("Uploaded overrides %@", String(describing: updates.map {$0.dictionaryRepresentation}))
                        completion(.success(true))
                    }
                }
            }
        })
    }


    public var alertDataLimit: Int? { return 1000 }

    public func uploadAlertData(_ stored: [SyncAlertObject], completion: @escaping (Result<Bool, Error>) -> Void) {
        completion(.success(false))
    }

    public var carbDataLimit: Int? { return 1000 }

    public func uploadCarbData(created: [SyncCarbObject], updated: [SyncCarbObject], deleted: [SyncCarbObject], completion: @escaping (Result<Bool, Error>) -> Void) {
        guard hasConfiguration, let uploader = uploader else {
            completion(.success(true))
            return
        }
        
        uploader.createCarbData(created) { result in
            switch result {
            case .failure(let error):
                completion(.failure(error))
            case .success(let createdObjectIds):
                let createdUploaded = !created.isEmpty
                let syncIdentifiers = created.map { $0.syncIdentifier }
                for (syncIdentifier, objectId) in zip(syncIdentifiers, createdObjectIds) {
                    if let syncIdentifier = syncIdentifier {
                        self.objectIdCache.add(syncIdentifier: syncIdentifier, objectId: objectId)
                    }
                }
                self.stateDelegate?.pluginDidUpdateState(self)
                
                uploader.updateCarbData(updated, usingObjectIdCache: self.objectIdCache) { result in
                    switch result {
                    case .failure(let error):
                        completion(.failure(error))
                    case .success(let updatedUploaded):
                        uploader.deleteCarbData(deleted, usingObjectIdCache: self.objectIdCache) { result in
                            switch result {
                            case .failure(let error):
                                completion(.failure(error))
                            case .success(let deletedUploaded):
                                self.objectIdCache.purge(before: Date().addingTimeInterval(-self.objectIdCacheKeepTime))
                                self.stateDelegate?.pluginDidUpdateState(self)
                                completion(.success(createdUploaded || updatedUploaded || deletedUploaded))
                            }
                        }
                    }
                }
            }
        }
    }

    public var doseDataLimit: Int? { return 1000 }

    public func uploadDoseData(created: [DoseEntry], deleted: [DoseEntry], completion: @escaping (_ result: Result<Bool, Error>) -> Void) {
        guard hasConfiguration, let uploader = uploader else {
            completion(.success(true))
            return
        }

        uploader.createDoses(created, usingObjectIdCache: self.objectIdCache) { (result) in
            switch (result) {
            case .failure(let error):
                completion(.failure(error))
            case .success(let createdObjectIds):
                self.trackOpenSuspend(from: created)
                let createdUploaded = !created.isEmpty
                let syncIdentifiers = created.map { $0.syncIdentifier }
                for (syncIdentifier, objectId) in zip(syncIdentifiers, createdObjectIds) {
                    if let syncIdentifier = syncIdentifier {
                        self.objectIdCache.add(syncIdentifier: syncIdentifier, objectId: objectId)
                    }
                }
                self.stateDelegate?.pluginDidUpdateState(self)

                uploader.deleteDoses(deleted.filter { !$0.isMutable }, usingObjectIdCache: self.objectIdCache) { result in
                    switch result {
                    case .failure(let error):
                        completion(.failure(error))
                    case .success(let deletedUploaded):
                        self.objectIdCache.purge(before: Date().addingTimeInterval(-self.objectIdCacheKeepTime))
                        self.stateDelegate?.pluginDidUpdateState(self)
                        completion(.success(createdUploaded || deletedUploaded))
                    }
                }
            }
        }
    }

    public var dosingDecisionDataLimit: Int? { return 50 }  // Each can be up to 20K bytes of serialized JSON, target ~1M or less

    public func uploadDosingDecisionData(_ stored: [StoredDosingDecision], completion: @escaping (Result<Bool, Error>) -> Void) {
        guard hasConfiguration, let uploader = uploader else {
            completion(.success(true))
            return
        }

        var uploadPairs: [(StoredDosingDecision, StoredDosingDecision?)] = []

        for decision in stored {
            switch decision.reason {
            case "loop":
                lastDosingDecisionForAutomaticDose = decision
            case "updateRemoteRecommendation", "normalBolus", "simpleBolus", "watchBolus":
                uploadPairs.append((decision, lastDosingDecisionForAutomaticDose))
            default:
                break
            }
        }

        let statuses = uploadPairs.map { (decision, automaticDoseDecision) in
            return decision.deviceStatus(automaticDoseDecision: automaticDoseDecision)
        }

        // Each loop cycle, keep an open suspend's zero temp running ahead of now (custom)
        guard statuses.count > 0 else {
            refreshOpenSuspend(using: uploader) {
                completion(.success(false))
            }
            return
        }
        refreshOpenSuspend(using: uploader) {}

        uploader.uploadDeviceStatuses(statuses) { result in
            switch result {
            case .success:
                self.lastDosingDecisionForAutomaticDose = nil
            default:
                break
            }
            completion(result)
        }
    }

    public var glucoseDataLimit: Int? { return 1000 }

    public func uploadGlucoseData(_ stored: [StoredGlucoseSample], completion: @escaping (Result<Bool, Error>) -> Void) {
        guard hasConfiguration, let uploader = uploader else {
            completion(.success(true))
            return
        }

        uploader.uploadGlucoseSamples(stored, completion: completion)
    }

    public var pumpEventDataLimit: Int? { return 1000 }

    public func uploadPumpEventData(_ stored: [PersistedPumpEvent], completion: @escaping (Result<Bool, Error>) -> Void) {

        guard hasConfiguration, let uploader = uploader else {
            completion(.success(true))
            return
        }

        let source = "loop://\(UIDevice.current.name)"

        let treatments = stored.compactMap { (event) -> NightscoutTreatment? in
            // ignore doses; we'll get those via uploadDoseData
            guard event.dose == nil else {
                return nil
            }
            return event.treatment(source: source)
        }

        uploader.upload(treatments) { (result) in
            switch result {
            case .failure(let error):
                self.log.error("Failed to upload pump events %{public}@: %{public}@", String(describing: treatments.map {$0.dictionaryRepresentation}), String(describing: error))
                completion(.failure(error))
            case .success:
                self.log.debug("Uploaded overrides %@", String(describing: treatments.map {$0.dictionaryRepresentation}))
                completion(.success(true))
            }
        }

        completion(.success(false))
    }

    public var settingsDataLimit: Int? { return 400 }  // Each can be up to 2.5K bytes of serialized JSON, target ~1M or less

    public func uploadSettingsData(_ stored: [StoredSettings], completion: @escaping (Result<Bool, Error>) -> Void) {
        guard hasConfiguration, let uploader = uploader else {
            completion(.success(true))
            return
        }

        uploader.uploadProfiles(stored.compactMap { $0.profileSet }, completion: completion)
    }
    
    public func fetchStoredTherapySettings(completion: @escaping (Result<(TherapySettings,Date), Error>) -> Void) {
        guard let uploader = uploader else {
            completion(.failure(NightscoutServiceError.missingCredentials))
            return
        }

        uploader.fetchCurrentProfile(completion: { result in
            switch result {
            case .success(let profileSet):
                if let therapySettings = profileSet.therapySettings {
                    completion(.success((therapySettings,profileSet.startDate)))
                } else {
                    completion(.failure(NightscoutServiceError.incompatibleTherapySettings))
                }
                break
            case .failure(let error):
                completion(.failure(error))
            }
        })
    }

    public var exerciseDataLimit: Int? { return 100 }

    public var exerciseDataDescription: String? {
        LocalizedString("Nightscout receives your workouts as Exercise treatments, and your steps and physical effort as activity records.", comment: "What Nightscout does with exercise data, shown with the exercise data setting")
    }

    public func uploadExerciseData(added: [StoredWorkout], deleted: [UUID]) async throws {
        guard hasConfiguration, let uploader = uploader else {
            return
        }

        let source = "loop://\(await UIDevice.current.name)"
        let treatments = added.map { $0.treatment(enteredBy: source) }
        let deletions = deleted.map(\.uuidString)

        try await withCheckedThrowingContinuation({ (continuation: CheckedContinuation<Void, Error>) -> Void in
            uploader.deleteTreatmentsById(deletions) { error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                uploader.upload(treatments) { result in
                    switch result {
                    case .failure(let error):
                        continuation.resume(throwing: error)
                    case .success:
                        continuation.resume()
                    }
                }
            }
        })
    }

    // MARK: - Steps and physical effort (custom)

    public var healthSampleDataLimit: Int? { return 500 }

    /// Steps and physical effort go to Nightscout's activity collection, one record per sample.
    /// Other kinds are skipped. Deletions aren't sent: activity records can only be deleted by
    /// their Nightscout id.
    public func uploadHealthSamples(kind: StoredHealthSample.Kind, added: [StoredHealthSample], deleted: [UUID]) async throws {
        guard hasConfiguration, let siteURL, let apiSecret, StoredHealthSample.nightscoutActivityKinds.contains(kind) else {
            return
        }

        let records = added.nightscoutActivity(enteredBy: "loop://\(await UIDevice.current.name)")
        guard !records.isEmpty else {
            return
        }

        // Nightscout's activity API rejects large bodies (413), so post at most 100 records at a time
        let hashedSecret = Insecure.SHA1.hash(data: Data(apiSecret.utf8)).map { String(format: "%02hhx", $0) }.joined()
        for start in stride(from: 0, to: records.count, by: 100) {
            var request = URLRequest(url: siteURL.appendingPathComponent("api/v1/activity"))
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            request.setValue(hashedSecret, forHTTPHeaderField: "api-secret")
            request.httpBody = try JSONSerialization.data(withJSONObject: Array(records[start..<Swift.min(start + 100, records.count)]))

            let (_, response) = try await URLSession.shared.data(for: request)
            if let httpResponse = response as? HTTPURLResponse, !(200..<300).contains(httpResponse.statusCode) {
                throw NightscoutServiceError.activityUploadFailed(statusCode: httpResponse.statusCode)
            }
        }
    }

    public func uploadCgmEventData(_ stored: [LoopKit.PersistedCgmEvent], completion: @escaping (Result<Bool, Error>) -> Void) {
        guard hasConfiguration, let uploader = uploader else {
            completion(.success(true))
            return
        }

        uploader.uploadCgmEvents(stored, completion: completion)
    }

    
    public func remoteNotificationWasReceived(_ notification: [String: AnyObject]) async throws {
        let commandSource = try commandSource(notification: notification)
        await commandSource.remoteNotificationWasReceived(notification)
    }
    
    private func commandSource(notification: [String: AnyObject]) throws -> RemoteCommandSource {
        return commandSourceV1
    }

}

extension NightscoutService: RemoteCommandSourceV1Delegate {
    
    func commandSourceV1(_: RemoteCommandSourceV1, handleAction action: Action, remoteNotification: RemoteNotification) async throws {
        
        let returnInfo = remoteNotification.getReturnNotificationInfo()
        if returnInfo == nil {
            os_log("No return notification info available, response will not be sent", log: .default, type: .info)
        } else {
            os_log("Return notification info available, will send response after command processing", log: .default, type: .info)
        }
        
        var commandType: RemoteNotificationResponseManager.CommandType = .bolus // Default, will be set in switch
        var success = false
        var message = ""
        
        do {
            switch action {
            case .temporaryScheduleOverride(let overrideCommand):
                commandType = .override
                try await self.serviceDelegate?.enactRemoteOverride(
                    name: overrideCommand.name,
                    durationTime: overrideCommand.durationTime,
                    remoteAddress: overrideCommand.remoteAddress
                )
                success = true
                message = "Override '\(overrideCommand.name)' enacted successfully"
                
            case .cancelTemporaryOverride:
                commandType = .cancelOverride
                try await self.serviceDelegate?.cancelRemoteOverride()
                success = true
                message = "Override cancelled successfully"
                
            case .bolusEntry(let bolusCommand):
                commandType = .bolus
                try await self.serviceDelegate?.deliverRemoteBolus(amountInUnits: bolusCommand.amountInUnits)
                success = true
                message = String(format: "Bolus of %.2f units delivered successfully", bolusCommand.amountInUnits)
                
            case .carbsEntry(let carbCommand):
                commandType = .carbs
                try await self.serviceDelegate?.deliverRemoteCarbs(
                    amountInGrams: carbCommand.amountInGrams,
                    absorptionTime: carbCommand.absorptionTime,
                    foodType: carbCommand.foodType,
                    startDate: carbCommand.startDate
                )
                success = true
                message = String(format: "Carbs entry of %.1f g delivered successfully", carbCommand.amountInGrams)
            }
        } catch {
            message = "Command failed: \(error.localizedDescription)"
            // Send failure response before rethrowing
            if let returnInfo = returnInfo {
                await RemoteNotificationResponseManager.shared.sendResponseNotification(
                    to: returnInfo,
                    commandType: commandType,
                    success: false,
                    message: message
                )
            }
            throw error
        }
        
        // Send success response
        if let returnInfo = returnInfo {
            await RemoteNotificationResponseManager.shared.sendResponseNotification(
                to: returnInfo,
                commandType: commandType,
                success: success,
                message: message
            )
        }
    }
    
    func commandSourceV1(_: RemoteCommandSourceV1, uploadError error: Error, notification: [String: AnyObject]) async throws {
        
        guard let uploader = self.uploader else {throw NightscoutServiceError.missingCredentials}
        var commandDescription = "Loop Remote Action Error"
        if let remoteNotification = try? notification.toRemoteNotification() {
            commandDescription = remoteNotification.toRemoteAction().description
        }
        
        let notificationJSON = try JSONSerialization.data(withJSONObject: notification)
        let notificationJSONString = String(data: notificationJSON, encoding: .utf8) ?? ""
        
        let noteBody = """
        \(error.localizedDescription)
        \(notificationJSONString)
        """

        let treatment = NightscoutTreatment(
            timestamp: Date(),
            enteredBy: commandDescription,
            notes: noteBody,
            eventType: .note
        )
        
        return try await withCheckedThrowingContinuation { continuation in
            uploader.upload([treatment], completionHandler: { result in
                switch result {
                case .success:
                    continuation.resume()
                case .failure(let error):
                    continuation.resume(throwing: error)
                }
            })
        }
    }
}

extension KeychainManager {

    func setNightscoutCredentials(siteURL: URL? = nil, apiSecret: String? = nil) throws {
        let credentials: InternetCredentials?

        if let siteURL = siteURL, let apiSecret = apiSecret {
            credentials = InternetCredentials(username: NightscoutAPIAccount, password: apiSecret, url: siteURL)
        } else {
            credentials = nil
        }

        try replaceInternetCredentials(credentials, forAccount: NightscoutAPIAccount)
    }

    func getNightscoutCredentials() throws -> (siteURL: URL, apiSecret: String) {
        let credentials = try getInternetCredentials(account: NightscoutAPIAccount)

        return (siteURL: credentials.url, apiSecret: credentials.password)
    }

}

fileprivate let NightscoutAPIAccount = "NightscoutAPI"
