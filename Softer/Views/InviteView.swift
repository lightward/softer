import SwiftUI
import CloudKit
import UIKit

/// Wraps UICloudSharingController for inviting people to a room.
///
/// Two modes:
/// - **Preparation mode**: Pass `roomRecord` to create a new share and invite
/// - **Management mode**: Pass `existingShare` to manage an already-shared room
struct InviteView: UIViewControllerRepresentable {
    let container: CKContainer

    // For preparation mode (new share)
    var roomRecord: CKRecord?
    var onShareCreated: ((CKShare) -> Void)?

    // For management mode (existing share)
    var existingShare: CKShare?

    func makeUIViewController(context: Context) -> UICloudSharingController {
        let controller: UICloudSharingController

        if let existingShare = existingShare {
            // Management mode - share already exists
            controller = UICloudSharingController(share: existingShare, container: container)
        } else if let roomRecord = roomRecord {
            // Preparation mode - create share when user invites
            controller = UICloudSharingController { sharingController, completion in
                Task {
                    do {
                        let share = CKShare(rootRecord: roomRecord)
                        share[CKShare.SystemFieldKey.title] = roomRecord["name"] as? String ?? "Softer Room"
                        share.publicPermission = .none

                        let database = self.container.privateCloudDatabase
                        let operation = CKModifyRecordsOperation(recordsToSave: [roomRecord, share])
                        operation.savePolicy = .ifServerRecordUnchanged

                        operation.modifyRecordsResultBlock = { result in
                            switch result {
                            case .success:
                                self.onShareCreated?(share)
                                completion(share, self.container, nil)
                            case .failure(let error):
                                completion(nil, nil, error)
                            }
                        }

                        database.add(operation)
                    }
                }
            }
        } else {
            fatalError("InviteView requires either roomRecord or existingShare")
        }

        controller.availablePermissions = [.allowReadWrite]
        controller.delegate = context.coordinator
        return controller
    }

    func updateUIViewController(_ uiViewController: UICloudSharingController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    class Coordinator: NSObject, UICloudSharingControllerDelegate {
        func cloudSharingController(_ csc: UICloudSharingController, failedToSaveShareWithError error: Error) {
            print("Failed to save share: \(error)")
        }

        func itemTitle(for csc: UICloudSharingController) -> String? {
            return "Softer Room"
        }
    }
}

// MARK: - Convenience initializers

extension InviteView {
    /// Create a new share and invite someone
    static func forNewShare(
        roomRecord: CKRecord,
        container: CKContainer = CKContainer(identifier: Constants.containerIdentifier),
        onShareCreated: ((CKShare) -> Void)? = nil
    ) -> InviteView {
        InviteView(
            container: container,
            roomRecord: roomRecord,
            onShareCreated: onShareCreated,
            existingShare: nil
        )
    }

    /// Manage an existing share (add more people, remove people, stop sharing)
    static func forExistingShare(
        share: CKShare,
        container: CKContainer = CKContainer(identifier: Constants.containerIdentifier)
    ) -> InviteView {
        InviteView(
            container: container,
            roomRecord: nil,
            onShareCreated: nil,
            existingShare: share
        )
    }
}
