import SwiftUI
#if os(iOS)
import ContactsUI
#endif

struct CreateRoomView: View {
    let store: SofterStore
    @Binding var isPresented: Bool
    var onCreated: ((String) -> Void)? = nil

    // Form state
    @State private var myNickname = ""
    @State private var otherParticipants: [ParticipantEntry] = []
    @State private var selectedTier: PaymentTier = Self.lastUsedTier

    // Creation state
    @State private var isCreating = false
    @State private var errorMessage: String?

    // Contact picker
    #if os(iOS)
    @State private var showContactPicker = false
    #endif

    // Focus state
    @FocusState private var nicknameFieldFocused: Bool
    @FocusState private var focusedParticipantID: UUID?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    // Self - profile pic style
                    HStack(spacing: 12) {
                        Image(systemName: "person.circle.fill")
                            .resizable()
                            .frame(width: 36, height: 36)
                            .foregroundStyle(Color.accentColor)
                        TextField("Your nickname", text: $myNickname)
                            .textContentType(.givenName)
                            .focused($nicknameFieldFocused)
                    }

                    // Lightward - sparkle in circle style
                    HStack(spacing: 12) {
                        ZStack {
                            Circle()
                                .fill(Color.softerGray5)
                                .frame(width: 36, height: 36)
                            Image(systemName: "sparkles")
                                .font(.system(size: 16))
                                .foregroundStyle(.secondary)
                        }
                        Text("Lightward")
                            .foregroundStyle(.secondary)
                    }
                    .alignmentGuide(.listRowSeparatorLeading) { _ in 0 }

                    ForEach($otherParticipants) { $entry in
                        ParticipantEntryRow(entry: $entry) {
                            otherParticipants.removeAll { $0.id == entry.id }
                        }
                        .focused($focusedParticipantID, equals: entry.id)
                    }

                    #if os(iOS)
                    Button {
                        showContactPicker = true
                    } label: {
                        Label("Add someone else", systemImage: "plus")
                    }
                    #else
                    Button {
                        let entry = ParticipantEntry()
                        otherParticipants.append(entry)
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                            focusedParticipantID = entry.id
                        }
                    } label: {
                        Label("Add someone else", systemImage: "plus")
                    }
                    #endif
                } header: {
                    Text("Participants")
                }

                Section {
                    Picker("Amount", selection: $selectedTier) {
                        ForEach(PaymentTier.allCases, id: \.self) { tier in
                            Text(tier.displayString).tag(tier)
                        }
                    }
                    .pickerStyle(.segmented)
                } header: {
                    Text("How much does \"new\" cost for you?")
                } footer: {
                    Text("Your choice will be visible to all participants.")
                }

            }
            .navigationTitle("New Room")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .onAppear {
                nicknameFieldFocused = true
            }
            #if os(iOS)
            .sheet(isPresented: $showContactPicker) {
                ContactPicker { contact in
                    // Add participant with contact info
                    let entry = ParticipantEntry(
                        identifier: contact.emailAddresses.first?.value as String?
                            ?? contact.phoneNumbers.first?.value.stringValue
                            ?? "",
                        nickname: contact.givenName,
                        contact: contact
                    )
                    otherParticipants.append(entry)
                    // Auto-focus the nickname field after a brief delay
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                        focusedParticipantID = entry.id
                    }
                }
            }
            #endif
            .alert("Error", isPresented: .init(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )) {
                Button("OK") { errorMessage = nil }
            } message: {
                Text(errorMessage ?? "")
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        isPresented = false
                    }
                    .disabled(isCreating)
                }

                ToolbarItem(placement: .confirmationAction) {
                    if isCreating {
                        ProgressView()
                    } else {
                        Button("Create") {
                            Task {
                                await createRoom()
                            }
                        }
                        .disabled(!isValid)
                    }
                }
            }
        }
    }

    private var isValid: Bool {
        !myNickname.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private func createRoom() async {
        isCreating = true
        errorMessage = nil
        nicknameFieldFocused = false
        focusedParticipantID = nil

        // Build participant list
        var participants: [ParticipantSpec] = []

        // Add self (resolves to current user's CloudKit record ID)
        let selfSpec = ParticipantSpec(
            identifier: .currentUser,
            nickname: myNickname.trimmingCharacters(in: .whitespaces)
        )
        participants.append(selfSpec)

        // Add Lightward (always "Lightward")
        participants.append(ParticipantSpec.lightward(nickname: "Lightward"))

        // Add other participants
        for entry in otherParticipants {
            guard !entry.identifier.isEmpty, !entry.nickname.isEmpty else { continue }

            let identifier: ParticipantIdentifier
            if entry.identifier.contains("@") {
                identifier = .email(entry.identifier)
            } else {
                identifier = .phone(entry.identifier)
            }

            participants.append(ParticipantSpec(
                identifier: identifier,
                nickname: entry.nickname.trimmingCharacters(in: .whitespaces)
            ))
        }

        do {
            let lifecycle = try await store.createRoom(
                participants: participants,
                tier: selectedTier,
                originatorNickname: myNickname
            )
            UserDefaults.standard.set(selectedTier.rawValue, forKey: Self.lastTierKey)
            isPresented = false
            onCreated?(lifecycle.spec.id)
            // Don't reset isCreating on success — sheet is dismissing
            return
        } catch let error as RoomLifecycleError {
            errorMessage = describeError(error)
        } catch {
            errorMessage = error.localizedDescription
        }

        isCreating = false
    }

    private static let lastTierKey = "lastSelectedPaymentTier"

    private static var lastUsedTier: PaymentTier {
        let raw = UserDefaults.standard.integer(forKey: lastTierKey)
        return PaymentTier(rawValue: raw) ?? .ten
    }

    private func describeError(_ error: RoomLifecycleError) -> String {
        switch error {
        case .resolutionFailed(let participantID, _):
            return "Couldn't find participant: \(participantID)"
        case .paymentFailed(let paymentError):
            switch paymentError {
            case .notConfigured:
                return "Payment failed: product not available. Check that the Paid Apps agreement is active in App Store Connect."
            case .declined:
                return "Payment failed: transaction was not verified."
            case .cancelled:
                return "Payment was cancelled."
            case .networkError(let detail):
                return "Payment failed: \(detail)"
            }
        case .cancelled:
            return "Room creation was cancelled."
        case .expired:
            return "Room creation expired."
        case .invalidState:
            return "Something went wrong. Please try again."
        }
    }
}

// MARK: - Supporting Types

struct ParticipantEntry: Identifiable {
    let id: UUID
    var identifier: String  // email or phone
    var nickname: String
    #if os(iOS)
    var contact: CNContact?  // Original contact for thumbnail and verification
    #endif

    #if os(iOS)
    init(id: UUID = UUID(), identifier: String = "", nickname: String = "", contact: CNContact? = nil) {
        self.id = id
        self.identifier = identifier
        self.nickname = nickname
        self.contact = contact
    }
    #else
    init(id: UUID = UUID(), identifier: String = "", nickname: String = "") {
        self.id = id
        self.identifier = identifier
        self.nickname = nickname
    }
    #endif
}

struct ParticipantEntryRow: View {
    @Binding var entry: ParticipantEntry
    var onFocus: () -> Void = {}
    let onDelete: () -> Void
    #if os(iOS)
    @State private var showContactCard = false
    #endif

    var body: some View {
        HStack(spacing: 12) {
            #if os(iOS)
            // Contact thumbnail (tappable to view contact card)
            Button {
                showContactCard = true
            } label: {
                contactThumbnail
            }
            .buttonStyle(.plain)
            #else
            // Person icon + identifier field on macOS
            Image(systemName: "person.circle.fill")
                .resizable()
                .frame(width: 36, height: 36)
                .foregroundStyle(.secondary)

            TextField("Email or phone", text: $entry.identifier)
                .textContentType(.emailAddress)
            #endif

            // Nickname field (primary control)
            TextField("Nickname", text: $entry.nickname)
                .textContentType(.name)

            // Remove button
            Button(role: .destructive, action: onDelete) {
                Image(systemName: "minus.circle.fill")
                    .foregroundStyle(.red)
            }
            .buttonStyle(.plain)
        }
        #if os(iOS)
        .sheet(isPresented: $showContactCard) {
            if let contact = entry.contact {
                ContactCardView(contact: contact)
                    .ignoresSafeArea(edges: .bottom)
            }
        }
        #endif
    }

    #if os(iOS)
    @ViewBuilder
    private var contactThumbnail: some View {
        if let contact = entry.contact,
           let imageData = contact.thumbnailImageData,
           let uiImage = UIImage(data: imageData) {
            Image(uiImage: uiImage)
                .resizable()
                .scaledToFill()
                .frame(width: 36, height: 36)
                .clipShape(Circle())
        } else {
            // Default person icon
            Image(systemName: "person.circle.fill")
                .resizable()
                .frame(width: 36, height: 36)
                .foregroundStyle(.secondary)
        }
    }
    #endif
}

struct SuggestionChip: View {
    let text: String
    let action: () -> Void

    init(_ text: String, action: @escaping () -> Void) {
        self.text = text
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Text(text)
                .font(.subheadline)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(Color.softerGray5)
                .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Contact Card View

#if os(iOS)

struct ContactCardView: UIViewControllerRepresentable {
    let contact: CNContact
    @Environment(\.dismiss) private var dismiss

    func makeUIViewController(context: Context) -> UINavigationController {
        let contactVC = CNContactViewController(for: contact)
        contactVC.allowsEditing = false
        contactVC.allowsActions = true
        contactVC.edgesForExtendedLayout = .all

        // Add close button
        contactVC.navigationItem.rightBarButtonItem = UIBarButtonItem(
            barButtonSystemItem: .close,
            target: context.coordinator,
            action: #selector(Coordinator.close)
        )

        let nav = UINavigationController(rootViewController: contactVC)
        nav.navigationBar.prefersLargeTitles = false
        return nav
    }

    func updateUIViewController(_ uiViewController: UINavigationController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(dismiss: dismiss)
    }

    class Coordinator: NSObject {
        let dismiss: DismissAction

        init(dismiss: DismissAction) {
            self.dismiss = dismiss
        }

        @objc func close() {
            dismiss()
        }
    }
}

// MARK: - Contact Picker

struct ContactPicker: UIViewControllerRepresentable {
    let onSelectContact: (CNContact) -> Void

    func makeUIViewController(context: Context) -> CNContactPickerViewController {
        let picker = CNContactPickerViewController()
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: CNContactPickerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(onSelectContact: onSelectContact)
    }

    class Coordinator: NSObject, CNContactPickerDelegate {
        let onSelectContact: (CNContact) -> Void

        init(onSelectContact: @escaping (CNContact) -> Void) {
            self.onSelectContact = onSelectContact
        }

        func contactPicker(_ picker: CNContactPickerViewController, didSelect contact: CNContact) {
            onSelectContact(contact)
        }
    }
}

#endif
