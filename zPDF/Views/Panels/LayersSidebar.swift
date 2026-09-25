import SwiftUI

/// Layers (optional content) panel. Showing or hiding a layer updates the
/// document's default layer state, so the page redraws immediately and Save
/// keeps it as the visibility other viewers open with. Undo restores it.
/// Flatten merges visible layers into the page and discards hidden ones.
struct LayersSidebar: View {
    let tab: DocumentTab
    @Environment(AppState.self) private var appState
    @State private var items: [LayerModel] = []
    @State private var hasLayers = false
    @State private var loading = false
    @State private var error: String?
    @State private var confirmFlatten = false
    @State private var pending: Set<String> = []

    private var canEdit: Bool { tab.allowsSaveEdits && tab.editSource != nil }
    private var layers: [LayerModel] { items.filter { $0.kind == "layer" } }

    var body: some View {
        VStack(spacing: 0) {
            SidebarActionBar {
                SidebarIconButton(title: "Show all layers", symbol: "eye") { setAll(true) }
                    .disabled(!canEdit || layers.allSatisfy { $0.visible == true || $0.locked })
                SidebarIconButton(title: "Hide all layers", symbol: "eye.slash") { setAll(false) }
                    .disabled(!canEdit || layers.allSatisfy { $0.visible == false || $0.locked })
            } trailing: {
                SidebarMoreMenu {
                    Button("Flatten Layers…") { confirmFlatten = true }.disabled(!canEdit || !hasLayers)
                    Button("Refresh") { Task { await reload() } }
                }
            }
            content
        }
        .task(id: tab.editSource?.hash ?? tab.url?.path) { await reload() }
        .alert("Flatten layers?", isPresented: $confirmFlatten) {
            Button("Cancel", role: .cancel) {}
            Button("Flatten", role: .destructive) { flatten() }
        } message: {
            Text("Visible layers become ordinary page content and hidden layers are removed. The document will no longer have layers. You can undo this with ⌘Z.")
        }
    }

    @ViewBuilder
    private var content: some View {
        if loading && items.isEmpty {
            SidebarLoadingState(message: "Loading layers…")
        } else if let error {
            SidebarEmptyState(symbolName: "exclamationmark.triangle", message: "Layers couldn't be read.", detail: error,
                              actionTitle: "Try Again") { Task { await reload() } }
        } else if !hasLayers {
            SidebarEmptyState(symbolName: "square.3.layers.3d", message: "No layers",
                              detail: "This document doesn't use optional content layers.")
        } else {
            List(items, id: \.rowID) { item in
                if item.kind == "label" {
                    Text(item.name)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(DesignTokens.Colors.mutedText)
                        .padding(.leading, CGFloat(item.depth) * 14)
                        .accessibilityAddTraits(.isHeader)
                } else {
                    layerRow(item)
                }
            }
            .listStyle(.sidebar)
            SidebarNotice(symbol: "info.circle",
                          text: "Visibility changes are saved as the layers' default state. Undo reverts them.")
        }
    }

    private func layerRow(_ item: LayerModel) -> some View {
        let visible = item.visible ?? true
        return HStack(spacing: 8) {
            Button { toggle(item) } label: {
                Image(systemName: visible ? "eye" : "eye.slash")
                    .font(.system(size: 12))
                    .frame(width: 22, height: 22)
                    .foregroundStyle(visible ? DesignTokens.Colors.accent : DesignTokens.Colors.mutedText)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .modifier(KeyboardFocusRing())
            .disabled(!canEdit || item.locked || pending.contains(item.rowID))
            .help(item.locked ? "This layer is locked by the document" : visible ? "Hide “\(item.name)”" : "Show “\(item.name)”")
            .accessibilityLabel("\(item.name) visibility")
            .accessibilityValue(visible ? "Visible" : "Hidden")
            Text(item.name)
                .font(.system(size: 12))
                .foregroundStyle(visible ? DesignTokens.Colors.text : DesignTokens.Colors.mutedText)
                .lineLimit(1)
            Spacer(minLength: 0)
            if item.prints == false {
                Image(systemName: "printer.dotmatrix").font(.system(size: 10)).foregroundStyle(DesignTokens.Colors.mutedText)
                    .help("This layer doesn't print")
                    .accessibilityLabel("Doesn't print")
            }
            if item.locked {
                Image(systemName: "lock.fill").font(.system(size: 10)).foregroundStyle(DesignTokens.Colors.mutedText)
                    .help("Locked layer")
                    .accessibilityLabel("Locked")
            }
        }
        .padding(.leading, CGFloat(item.depth) * 14)
    }

    private func reload() async {
        guard appState.canQuery(tab) else { return }
        loading = true
        defer { loading = false }
        do {
            let result = try await appState.documentQuery("layers", in: tab, as: LayersResult.self)
            items = result.items
            hasLayers = result.hasLayers
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func toggle(_ item: LayerModel) {
        guard let id = item.id else { return }
        apply([id: !(item.visible ?? true)], action: (item.visible ?? true) ? "Hide Layer" : "Show Layer")
    }

    private func setAll(_ visible: Bool) {
        var states: [String: Bool] = [:]
        for layer in layers where !layer.locked { if let id = layer.id { states[id] = visible } }
        apply(states, action: visible ? "Show All Layers" : "Hide All Layers")
    }

    private func apply(_ states: [String: Bool], action: String) {
        guard !states.isEmpty else { return }
        pending.formUnion(states.keys)
        // Optimistic: update the eye immediately while the page re-renders.
        items = items.map { item in
            guard let id = item.id, let visible = states[id] else { return item }
            return LayerModel(id: item.id, name: item.name, visible: visible, locked: item.locked, depth: item.depth,
                              group: item.group, prints: item.prints, kind: item.kind)
        }
        Task {
            let ok = await appState.performDocumentEdit([["op": "set_layer_visibility", "states": states]],
                                                        actionName: action, in: tab)
            pending.subtract(states.keys)
            if !ok { await reload() }
        }
    }

    private func flatten() {
        Task { await appState.performDocumentEdit([["op": "flatten_layers"]], actionName: "Flatten Layers", in: tab) }
    }
}
