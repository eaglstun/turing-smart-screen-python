import SwiftUI

/// The menu bar window: status, live preview of the display, brightness, theme, pause, settings.
struct MenuView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Circle().fill(model.status.color).frame(width: 8, height: 8)
                Text(model.status.label).font(.headline)
                Spacer()
                Text("3.5\" display").font(.caption).foregroundStyle(.secondary)
            }

            preview

            VStack(alignment: .leading, spacing: 4) {
                Label("Brightness", systemImage: "sun.max").font(.caption).foregroundStyle(.secondary)
                Slider(value: Binding(get: { model.brightness }, set: { model.setBrightness($0) }), in: 0...100)
            }

            Picker("Theme", selection: $model.themeName) {
                ForEach(model.themes) { theme in Text(theme.name).tag(theme.name) }
            }

            Divider()

            HStack {
                Button(model.isPaused ? "Resume" : "Pause") { model.togglePause() }
                Spacer()
                Button("Settings…") {
                    openSettings()
                    NSApp.activate(ignoringOtherApps: true)
                }
                Button("Quit") { model.quit() }
            }
        }
        .padding(14)
        .frame(width: 300)
        .onAppear { model.previewActive = true }
        .onDisappear { model.previewActive = false }
    }

    @ViewBuilder private var preview: some View {
        let landscape = model.currentTheme?.landscape ?? false
        ZStack {
            RoundedRectangle(cornerRadius: 6).fill(.black)
            if let image = model.preview {
                Image(nsImage: image).resizable().interpolation(.medium).aspectRatio(contentMode: .fit).padding(4)
            } else {
                ProgressView().controlSize(.small)
            }
        }
        .frame(width: landscape ? 272 : 136, height: landscape ? 181 : 204)
        .frame(maxWidth: .infinity)
    }
}
