import Foundation
import CloudKit

/// Resolves participant identifiers to CloudKit user identities.
/// Uses CKFetchShareParticipantsOperation to verify users can receive shares.
/// This is the right validation for "eigenstate commitment" - we verify that
/// the person exists and can participate before the room is created.
struct CloudKitParticipantResolver: ParticipantResolver {
    private let container: CKContainer

    init(container: CKContainer) {
        self.container = container
    }

    func resolve(_ spec: ParticipantSpec) async -> Result<ResolvedParticipant, ResolutionError> {
        // Lightward always resolves successfully with nil userRecordID
        if spec.isLightward {
            return .success(ResolvedParticipant(spec: spec, userRecordID: nil))
        }

        // Current user resolves to the local user's record ID
        if spec.identifier.isCurrentUser {
            do {
                let userRecordID = try await container.userRecordID()
                return .success(ResolvedParticipant(spec: spec, userRecordID: userRecordID.recordName))
            } catch {
                print("CloudKitParticipantResolver: Failed to get current user: \(error)")
                return .failure(.networkError("Could not get current user: \(error.localizedDescription)"))
            }
        }

        // Create lookup info based on identifier type
        let lookupInfo: CKUserIdentity.LookupInfo
        switch spec.identifier {
        case .email(let email):
            print("CloudKitParticipantResolver: Looking up email: \(email)")
            lookupInfo = CKUserIdentity.LookupInfo(emailAddress: email)
        case .phone(let phone):
            print("CloudKitParticipantResolver: Looking up phone: \(phone)")
            lookupInfo = CKUserIdentity.LookupInfo(phoneNumber: phone)
        case .lightward, .currentUser:
            // Already handled above, but Swift requires exhaustive switch
            return .success(ResolvedParticipant(spec: spec, userRecordID: nil))
        }

        do {
            // Use CKFetchShareParticipantsOperation to verify user can receive shares
            // This is more permissive than CKDiscoverUserIdentitiesOperation -
            // it just needs a valid iCloud account, not "Look Me Up" enabled
            let participant = try await fetchShareParticipant(lookupInfo: lookupInfo)

            guard let participant = participant else {
                print("CloudKitParticipantResolver: No participant returned for \(spec.nickname)")
                return .failure(.notFound)
            }

            // Get user record ID from participant's identity
            let userRecordID = participant.userIdentity.userRecordID?.recordName
            print("CloudKitParticipantResolver: Resolved \(spec.nickname) -> userRecordID: \(userRecordID ?? "nil")")

            return .success(ResolvedParticipant(spec: spec, userRecordID: userRecordID))
        } catch let ckError as CKError {
            print("CloudKitParticipantResolver: CKError \(ckError.code.rawValue): \(ckError.localizedDescription)")
            switch ckError.code {
            case .unknownItem:
                return .failure(.notFound)
            case .networkUnavailable, .networkFailure:
                return .failure(.networkError(ckError.localizedDescription))
            case .notAuthenticated:
                return .failure(.networkError("Not signed in to iCloud"))
            default:
                return .failure(.networkError(ckError.localizedDescription))
            }
        } catch {
            print("CloudKitParticipantResolver: Error: \(error)")
            return .failure(.networkError(error.localizedDescription))
        }
    }

    /// Fetch a share participant for the given lookup info.
    /// Returns nil if the user cannot be found as a share participant.
    private func fetchShareParticipant(lookupInfo: CKUserIdentity.LookupInfo) async throws -> CKShare.Participant? {
        try await withCheckedThrowingContinuation { continuation in
            var foundParticipant: CKShare.Participant?
            var operationError: Error?

            let operation = CKFetchShareParticipantsOperation(userIdentityLookupInfos: [lookupInfo])

            operation.perShareParticipantResultBlock = { _, result in
                switch result {
                case .success(let participant):
                    print("CloudKitParticipantResolver: Found participant: \(participant)")
                    foundParticipant = participant
                case .failure(let error):
                    print("CloudKitParticipantResolver: Per-participant error: \(error)")
                    operationError = error
                }
            }

            operation.fetchShareParticipantsResultBlock = { result in
                switch result {
                case .success:
                    if let error = operationError {
                        continuation.resume(throwing: error)
                    } else {
                        continuation.resume(returning: foundParticipant)
                    }
                case .failure(let error):
                    continuation.resume(throwing: error)
                }
            }

            container.add(operation)
        }
    }
}
