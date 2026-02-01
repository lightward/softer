import Foundation

/// A participant whose identity has been resolved via CloudKit.
struct ResolvedParticipant: Sendable, Equatable {
    let spec: ParticipantSpec
    let userRecordID: String?  // nil for Lightward

    var isLightward: Bool {
        spec.isLightward
    }
}

/// Errors that can occur during participant resolution.
enum ResolutionError: Error, Sendable, Equatable {
    case notFound
    case notDiscoverable
    case networkError(String)
}

/// Error when resolving multiple participants - includes which one failed.
struct ParticipantResolutionError: Error, Sendable, Equatable {
    let participantSpec: ParticipantSpec
    let error: ResolutionError
}

/// Resolves participant identifiers to CloudKit user identities.
protocol ParticipantResolver: Sendable {
    /// Resolve a single participant identifier.
    /// Lightward always resolves successfully with nil userRecordID.
    func resolve(_ spec: ParticipantSpec) async -> Result<ResolvedParticipant, ResolutionError>

    /// Resolve all participants. Returns on first failure.
    func resolveAll(_ specs: [ParticipantSpec]) async -> Result<[ResolvedParticipant], ParticipantResolutionError>
}

/// Default implementation of resolveAll that calls resolve for each spec.
extension ParticipantResolver {
    func resolveAll(_ specs: [ParticipantSpec]) async -> Result<[ResolvedParticipant], ParticipantResolutionError> {
        var resolved: [ResolvedParticipant] = []
        for spec in specs {
            switch await resolve(spec) {
            case .success(let participant):
                resolved.append(participant)
            case .failure(let error):
                return .failure(ParticipantResolutionError(participantSpec: spec, error: error))
            }
        }
        return .success(resolved)
    }
}
