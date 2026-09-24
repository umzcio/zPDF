import SwiftUI

struct RecoveryView: View {
    @Bindable var recovery: RecoveryCoordinator
    let restore: (RecoveryCheckpoint) async -> Bool
    @State private var busyID: UUID?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Recover unsaved documents")
                .font(.title2.weight(.semibold))
            Text("These copies contain edits from a previous session. Restore a copy, then use Save As to keep it. Your original files have not been changed.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            ScrollView {
                VStack(spacing: 0) {
                    if recovery.items.isEmpty {
                        Text("No documents need recovery.")
                            .foregroundStyle(.secondary).padding(.vertical, 24)
                    }
                    ForEach(recovery.items) { item in
                        HStack(spacing: 12) {
                            Image(systemName: "doc.text")
                                .accessibilityHidden(true)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(item.displayName).lineLimit(2)
                                Text(item.updatedAt, format: .dateTime.month().day().hour().minute())
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 16)
                            if busyID == item.id { ProgressView().controlSize(.small) }
                            Button("Discard", role: .destructive) {
                                busyID = item.id
                                Task {
                                    _ = await recovery.discard(id: item.id)
                                    busyID = nil
                                }
                            }
                            .accessibilityLabel("Discard recovery for \(item.displayName)")
                            Button("Restore") {
                                busyID = item.id
                                Task {
                                    if await restore(item) { recovery.didRestore(item) }
                                    busyID = nil
                                }
                            }
                            .accessibilityLabel("Restore \(item.displayName)")
                        }
                        .padding(.vertical, 12)
                        Divider()
                    }
                }
            }
            .frame(maxHeight: 300)
            if let message = recovery.errorMessage {
                Text(message).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer()
                Button("Later") { recovery.showingRecovery = false }
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(24)
        .frame(width: 550)
        .disabled(busyID != nil)
        .interactiveDismissDisabled(busyID != nil)
    }
}
