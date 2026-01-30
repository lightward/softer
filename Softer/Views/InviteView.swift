import SwiftUI
import CloudKit
import UIKit

/// Button that creates a share and presents the standard iOS share sheet with the share URL
struct InviteButton: View {
    let roomRecord: CKRecord
    let container: CKContainer
    var onShareCreated: ((CKShare) -> Void)?

    @State private var isCreatingShare = false
    @State private var error: String?

    var body: some View {
        Button {
            Task { await createAndShareURL() }
        } label: {
            HStack {
                Image(systemName: "person.badge.plus")
                Text("Invite Someone")
                if isCreatingShare {
                    Spacer()
                    ProgressView()
                }
            }
        }
        .disabled(isCreatingShare)

        if let error = error {
            Text(error)
                .font(.caption)
                .foregroundStyle(.red)
        }
    }

    private func createAndShareURL() async {
        isCreatingShare = true
        error = nil
        defer { isCreatingShare = false }

        print("[InviteButton] Creating share for room: \(roomRecord.recordID.recordName)")

        do {
            // First, fetch the latest version of the record
            let freshRecord = try await container.privateCloudDatabase.record(for: roomRecord.recordID)
            print("[InviteButton] Fetched fresh record")

            // Create the share
            let share = CKShare(rootRecord: freshRecord)
            share[CKShare.SystemFieldKey.title] = freshRecord["name"] as? String ?? "Softer Room"
            share.publicPermission = .none

            // Save both
            let operation = CKModifyRecordsOperation(recordsToSave: [freshRecord, share])
            operation.savePolicy = .changedKeys

            let savedShare: CKShare = try await withCheckedThrowingContinuation { continuation in
                operation.modifyRecordsResultBlock = { result in
                    switch result {
                    case .success:
                        print("[InviteButton] Share saved successfully")
                        print("[InviteButton] Share URL: \(share.url?.absoluteString ?? "nil")")
                        continuation.resume(returning: share)
                    case .failure(let error):
                        print("[InviteButton] Failed to save share: \(error)")
                        continuation.resume(throwing: error)
                    }
                }
                container.privateCloudDatabase.add(operation)
            }

            await MainActor.run {
                onShareCreated?(savedShare)
                presentShareSheet(for: savedShare)
            }

        } catch {
            print("[InviteButton] Error: \(error)")
            await MainActor.run {
                self.error = error.localizedDescription
            }
        }
    }

    @MainActor
    private func presentShareSheet(for share: CKShare) {
        guard let url = share.url else {
            print("[InviteButton] Share has no URL")
            error = "Share URL not available"
            return
        }

        guard let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
              let rootVC = windowScene.windows.first?.rootViewController else {
            return
        }

        var topVC = rootVC
        while let presented = topVC.presentedViewController {
            topVC = presented
        }

        let roomName = roomRecord["name"] as? String ?? "a Softer room"
        let message = "Join me in \(roomName)"

        let activityVC = UIActivityViewController(
            activityItems: [message, url],
            applicationActivities: nil
        )

        if let popover = activityVC.popoverPresentationController {
            popover.sourceView = topVC.view
            popover.sourceRect = CGRect(x: topVC.view.bounds.midX, y: topVC.view.bounds.midY, width: 0, height: 0)
        }

        print("[InviteButton] Presenting share sheet with URL: \(url)")
        topVC.present(activityVC, animated: true)
    }
}

/// Button to share an existing share's URL or manage it
struct ManageShareButton: View {
    let share: CKShare
    let container: CKContainer
    let roomName: String

    var body: some View {
        Button {
            presentShareSheet()
        } label: {
            HStack {
                Image(systemName: "square.and.arrow.up")
                Text("Share Invite Link")
            }
        }
    }

    private func presentShareSheet() {
        guard let url = share.url else {
            print("[ManageShareButton] Share has no URL")
            return
        }

        guard let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
              let rootVC = windowScene.windows.first?.rootViewController else {
            return
        }

        var topVC = rootVC
        while let presented = topVC.presentedViewController {
            topVC = presented
        }

        let message = "Join me in \(roomName)"
        let activityVC = UIActivityViewController(
            activityItems: [message, url],
            applicationActivities: nil
        )

        if let popover = activityVC.popoverPresentationController {
            popover.sourceView = topVC.view
            popover.sourceRect = CGRect(x: topVC.view.bounds.midX, y: topVC.view.bounds.midY, width: 0, height: 0)
        }

        topVC.present(activityVC, animated: true)
    }
}
