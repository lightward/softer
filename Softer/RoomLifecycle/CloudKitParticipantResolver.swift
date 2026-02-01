import Foundation
import CloudKit

/// Resolves participant identifiers to CloudKit user identities.
/// Uses CKUserIdentityLookupInfo to find users by email or phone.
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
                return .failure(.networkError("Could not get current user: \(error.localizedDescription)"))
            }
        }

        // Create lookup info based on identifier type
        let lookupInfo: CKUserIdentity.LookupInfo
        switch spec.identifier {
        case .email(let email):
            lookupInfo = CKUserIdentity.LookupInfo(emailAddress: email)
        case .phone(let phone):
            lookupInfo = CKUserIdentity.LookupInfo(phoneNumber: phone)
        case .lightward, .currentUser:
            // Already handled above, but Swift requires exhaustive switch
            return .success(ResolvedParticipant(spec: spec, userRecordID: nil))
        }

        do {
            // Use CKDiscoverUserIdentitiesOperation to look up user by email/phone
            let identity = try await discoverUserIdentity(lookupInfo: lookupInfo)

            // User must have a record ID to be usable
            guard let userRecordID = identity?.userRecordID else {
                return .failure(.notDiscoverable)
            }

            return .success(ResolvedParticipant(spec: spec, userRecordID: userRecordID.recordName))
        } catch let ckError as CKError {
            switch ckError.code {
            case .unknownItem:
                // User not found in CloudKit
                return .failure(.notFound)
            case .networkUnavailable, .networkFailure:
                return .failure(.networkError(ckError.localizedDescription))
            case .notAuthenticated:
                return .failure(.networkError("Not signed in to iCloud"))
            default:
                return .failure(.networkError(ckError.localizedDescription))
            }
        } catch {
            return .failure(.networkError(error.localizedDescription))
        }
    }

    private func discoverUserIdentity(lookupInfo: CKUserIdentity.LookupInfo) async throws -> CKUserIdentity? {
        try await withCheckedThrowingContinuation { continuation in
            let operation = CKDiscoverUserIdentitiesOperation(userIdentityLookupInfos: [lookupInfo])

            var foundIdentity: CKUserIdentity?

            operation.userIdentityDiscoveredBlock = { identity, _ in
                foundIdentity = identity
            }

            operation.discoverUserIdentitiesResultBlock = { result in
                switch result {
                case .success:
                    continuation.resume(returning: foundIdentity)
                case .failure(let error):
                    continuation.resume(throwing: error)
                }
            }

            container.add(operation)
        }
    }
}
