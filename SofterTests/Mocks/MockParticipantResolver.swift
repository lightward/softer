import Foundation
@testable import Softer

/// Mock participant resolver for testing.
final class MockParticipantResolver: ParticipantResolver, @unchecked Sendable {
    var results: [String: Result<ResolvedParticipant, ResolutionError>] = [:]
    var resolveCallCount = 0
    var resolvedSpecs: [ParticipantSpec] = []

    func resolve(_ spec: ParticipantSpec) async -> Result<ResolvedParticipant, ResolutionError> {
        resolveCallCount += 1
        resolvedSpecs.append(spec)

        // Lightward always resolves
        if spec.isLightward {
            return .success(ResolvedParticipant(spec: spec, userRecordID: nil))
        }

        // Check for configured result
        if let result = results[spec.id] {
            return result
        }

        // Default: resolve successfully with a fake user record ID
        return .success(ResolvedParticipant(spec: spec, userRecordID: "user-\(spec.id)"))
    }

    /// Configure a spec to fail resolution.
    func setFailure(for specID: String, error: ResolutionError) {
        results[specID] = .failure(error)
    }

    /// Configure a spec to resolve successfully.
    func setSuccess(for specID: String, userRecordID: String) {
        results[specID] = .success(ResolvedParticipant(
            spec: ParticipantSpec(id: specID, identifier: .email("test@test.com"), nickname: "Test"),
            userRecordID: userRecordID
        ))
    }
}
