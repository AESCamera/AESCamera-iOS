import AESCore
import PhotosUI
import SwiftUI

/// Settings → Duress password: set up, change, add decoy photos, remove. The same flows
/// as Android's SettingsActivity. Only the owner fields of the vault's verifier are
/// shown, so inside a decoy vault this reads "not set" like any other vault.
///
/// The section only shows the buttons; its sheet, alerts and photo picker hang off the
/// whole form (`duressFlow(_:)`), since presentations attached to a form row are unreliable.
struct DuressSection: View {
    @Environment(AppSession.self) private var session
    let flow: DuressFlow

    private var isSet: Bool { session.vaultPayload?.duressVault != nil }

    var body: some View {
        Section {
            Button(isSet ? "Change Duress Password…" : "Set Up Duress Password…") { flow.showingSetup = true }
            if isSet {
                Button("Add Decoy Photos…") {
                    flow.enteredPassword = ""
                    flow.askingPassword = true
                }
                Button("Remove Duress Password", role: .destructive) { flow.confirmingRemove = true }
            }
        } header: {
            Text("Duress password")
        } footer: {
            Text(status)
        }
    }

    private var status: String {
        guard isSet else {
            return "A second password for when someone forces you to unlock AES Camera. Entering it at the unlock prompt quietly wipes your photos and videos, then opens a harmless decoy vault."
        }
        return session.vaultPayload?.duressScope == .allOthers
            ? "A duress password is set. Entering it at the unlock prompt wipes this vault and every other vault, then opens its decoy vault."
            : "A duress password is set. Entering it at the unlock prompt wipes this vault, then opens its decoy vault."
    }
}

/// The state of the duress flows on the Settings screen.
@MainActor @Observable
final class DuressFlow {
    var showingSetup = false
    var confirmingRemove = false
    var askingPassword = false
    var enteredPassword = ""
    var offeringDecoy = false
    var pickingPhotos = false
    var pickedPhotos: [PhotosPickerItem] = []
    /// The duress password and its decoy vault while photos are being picked for it.
    /// Never stored; dropped on lock and after each import.
    @ObservationIgnored var decoyTarget: DecoyTarget?

    func dropDecoyTarget() {
        decoyTarget?.secret.wipe()
        decoyTarget = nil
    }
}

extension View {
    func duressFlow(_ flow: DuressFlow, progress: Binding<TransferProgress?>, message: Binding<String?>) -> some View {
        modifier(DuressFlowModifier(flow: flow, progress: progress, message: message))
    }
}

private struct DuressFlowModifier: ViewModifier {
    @Environment(AppSession.self) private var session
    @Bindable var flow: DuressFlow
    @Binding var progress: TransferProgress?
    @Binding var message: String?
    @State private var lockHandler: UUID?

    func body(content: Content) -> some View {
        content
            .sheet(isPresented: $flow.showingSetup) {
                DuressSetupSheet(isChange: session.vaultPayload?.duressVault != nil) { duress, scope in
                    flow.showingSetup = false
                    setUp(duress, scope: scope)
                }
            }
            .alert("Duress password set", isPresented: $flow.offeringDecoy) {
                Button("Later", role: .cancel) { flow.dropDecoyTarget() }
                Button("Add Photos") { flow.pickingPhotos = true }
            } message: {
                Text("Add a few harmless photos to the decoy vault now, so it doesn't look empty when it opens? Don't unlock with the duress password unless you mean to wipe.")
            }
            .alert("Enter the duress password", isPresented: $flow.askingPassword) {
                SecureField("Duress password", text: $flow.enteredPassword)
                Button("Cancel", role: .cancel) { flow.enteredPassword = "" }
                Button("OK") { checkPassword() }
            }
            .confirmationDialog("Remove the duress password?", isPresented: $flow.confirmingRemove, titleVisibility: .visible) {
                Button("Remove", role: .destructive) { remove() }
            } message: {
                Text("The decoy vault and its photos are deleted. Your photos and videos in this vault stay as they are.")
            }
            .photosPicker(isPresented: $flow.pickingPhotos, selection: $flow.pickedPhotos, matching: .images)
            .onChange(of: flow.pickingPhotos) { _, picking in
                // Closed without picking anything.
                if !picking && flow.pickedPhotos.isEmpty { flow.dropDecoyTarget() }
            }
            .onChange(of: flow.pickedPhotos) { _, items in
                guard !items.isEmpty else { return }
                flow.pickedPhotos = []
                importDecoys(items)
            }
            .onAppear {
                let flow = flow
                lockHandler = session.onLock { flow.dropDecoyTarget() }
            }
            .onDisappear {
                if let lockHandler { session.removeLockHandler(lockHandler) }
                flow.dropDecoyTarget()
            }
    }

    private func setUp(_ duress: Secret, scope: WipeScope) {
        progress = TransferProgress(title: "Setting up…", cancellable: false)
        Task {
            do {
                let decoy = try await session.setDuress(duress, scope: scope)
                flow.decoyTarget = DecoyTarget(secret: duress, vault: decoy)
                progress = nil
                flow.offeringDecoy = true
            } catch is VaultLocator.DuressPasswordInUse {
                duress.wipe()
                progress = nil
                message = "This password already opens a vault. Choose a different one."
            } catch {
                duress.wipe()
                progress = nil
                message = "Couldn't set up the duress password."
            }
        }
    }

    private func checkPassword() {
        let entered = flow.enteredPassword
        flow.enteredPassword = ""
        guard !entered.isEmpty else { return }
        let duress = Secret(entered)
        progress = TransferProgress(title: "Checking…", cancellable: false)
        Task {
            let decoy = try? await session.duressVault(for: duress)
            progress = nil
            if let decoy {
                flow.decoyTarget = DecoyTarget(secret: duress, vault: decoy)
                flow.pickingPhotos = true
            } else {
                duress.wipe()
                message = "That isn't this vault's duress password."
            }
        }
    }

    private func importDecoys(_ items: [PhotosPickerItem]) {
        guard let target = flow.decoyTarget else { return }
        flow.decoyTarget = nil
        let tracker = TransferProgress(title: "Adding decoy photos…", cancellable: false)
        progress = tracker
        let report = tracker.reporter
        Task {
            var summary = DecoyImporter.Summary()
            for (index, item) in items.enumerated() {
                // Locked meanwhile: the duress password must not outlive the session.
                guard session.isUnlocked else { break }
                if let data = try? await item.loadTransferable(type: Data.self),
                   (try? await Task.detached {
                       try DecoyImporter.add(data, to: target.vault, secret: target.secret, options: .completeFileProtection)
                   }.value) == true {
                    summary.added += 1
                } else {
                    summary.skipped += 1
                }
                report(index + 1, items.count)
            }
            target.secret.wipe()
            progress = nil
            if session.isUnlocked {
                let photos = summary.added == 1 ? "1 photo" : "\(summary.added) photos"
                message = "Added \(photos) to the decoy vault. \(summary.skipped) skipped."
            }
        }
    }

    private func remove() {
        progress = TransferProgress(title: "Removing…", cancellable: false)
        Task {
            do {
                try await session.removeDuress()
                message = "Duress password removed."
            } catch {
                message = "Couldn't remove the duress password."
            }
            progress = nil
        }
    }
}

struct DecoyTarget {
    let secret: Secret
    let vault: URL
}

/// Set up (or change) a duress password: the password twice, what it wipes, the limits
/// and an acknowledgement.
struct DuressSetupSheet: View {
    let isChange: Bool
    let onSet: (Secret, WipeScope) -> Void

    @Environment(AppSession.self) private var session
    @Environment(\.dismiss) private var dismiss
    @State private var password = ""
    @State private var confirmation = ""
    @State private var scope = WipeScope.thisVault
    @State private var acknowledged = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text("If someone forces you to unlock AES Camera, enter this password instead of your real one. AES Camera then wipes what you choose below and opens a decoy vault, as if it were your normal vault. There is no sign that anything was wiped.")
                    if isChange {
                        Text("Your current decoy vault and its photos are deleted.")
                            .foregroundStyle(.red)
                    }
                }

                Section {
                    // No password content type: iOS must never offer to save it.
                    SecureField("Duress password", text: $password)
                    SecureField("Repeat the duress password", text: $confirmation)
                } footer: {
                    if let error {
                        Text(error).foregroundStyle(.red)
                    }
                }

                Section {
                    Picker("When it is entered, wipe", selection: $scope) {
                        Text("This vault").tag(WipeScope.thisVault)
                        Text("This vault and every other vault").tag(WipeScope.allOthers)
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                } header: {
                    Text("When it is entered, wipe")
                } footer: {
                    Text("Every other vault includes vaults opened by your other passwords. Only the decoy vault is kept.")
                }

                Section {
                    Toggle("I understand wiped photos and videos can't be recovered", isOn: $acknowledged)
                } footer: {
                    Text("Limits: it can't help if someone copies your phone's storage before you enter it. Exported backups and files you shared are not wiped.")
                }
            }
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .navigationTitle(isChange ? "Change Duress Password" : "Set Up Duress Password")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Set", action: submit).disabled(!acknowledged)
                }
            }
            .onChange(of: session.isUnlocked) { _, unlocked in
                if !unlocked { dismiss() }
            }
        }
        .interactiveDismissDisabled(!password.isEmpty)
    }

    private func submit() {
        if password.isEmpty {
            error = "Enter a password."
        } else if password != confirmation {
            error = "The passwords don't match."
        } else if let owner = session.secret, Secret(password).matches(owner) {
            error = "Choose a password different from this vault's."
        } else {
            let duress = Secret(password)
            password = ""
            confirmation = ""
            onSet(duress, scope)
        }
    }
}
