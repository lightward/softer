import SwiftUI

struct CreateRoomView: View {
    let cloudKitManager: CloudKitManager
    let onRoomCreated: ((String) -> Void)?
    @Environment(\.dismiss) private var dismiss
    @State private var roomName = ""
    @State private var creatorName = ""
    @State private var isCreating = false

    init(cloudKitManager: CloudKitManager, onRoomCreated: ((String) -> Void)? = nil) {
        self.cloudKitManager = cloudKitManager
        self.onRoomCreated = onRoomCreated
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Room") {
                    TextField("Room name", text: $roomName)
                }

                Section("Your Name") {
                    TextField("Display name", text: $creatorName)
                }
            }
            .navigationTitle("New Room")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Create") {
                        Task { await create() }
                    }
                    .disabled(!isValid || isCreating)
                }
            }
        }
    }

    private var isValid: Bool {
        !roomName.trimmingCharacters(in: .whitespaces).isEmpty &&
        !creatorName.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private func create() async {
        isCreating = true
        let roomID = await cloudKitManager.createRoom(
            name: roomName.trimmingCharacters(in: .whitespaces),
            creatorName: creatorName.trimmingCharacters(in: .whitespaces)
        )

        if let roomID = roomID, let onRoomCreated = onRoomCreated {
            onRoomCreated(roomID)
        } else {
            dismiss()
        }
    }
}
