import SwiftUI

/// Settings window: theme gallery, display and network options.
struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettings().tabItem { Label("General", systemImage: "gearshape") }
            ThemeGallery().tabItem { Label("Themes", systemImage: "square.grid.2x2") }
            DisplaySettings().tabItem { Label("Display", systemImage: "display") }
            NetworkSettings().tabItem { Label("Network", systemImage: "network") }
        }
        .frame(width: 640, height: 520)
    }
}

struct GeneralSettings: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        Form {
            Toggle("Open at login", isOn: Binding(get: { model.launchAtLogin }, set: { model.launchAtLogin = $0 }))
            if let error = model.loginItemError {
                Text(error).font(.caption).foregroundStyle(.red)
            }
            Toggle("Turn the display off while the Mac sleeps", isOn: $model.sleepWithMac)
            Text("Also when the Mac's displays sleep. On wake the display reconnects and redraws.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
        .padding()
    }
}

struct ThemeGallery: View {
    @EnvironmentObject var model: AppModel
    private let columns = [GridItem(.adaptive(minimum: 130), spacing: 16)]

    var body: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 16) {
                ForEach(model.themes) { theme in
                    Button { model.themeName = theme.name } label: { ThemeTile(theme: theme, selected: theme.name == model.themeName) }
                        .buttonStyle(.plain)
                }
            }
            .padding()
        }
    }
}

struct ThemeTile: View {
    let theme: ThemeInfo
    let selected: Bool

    var body: some View {
        VStack(spacing: 6) {
            ZStack {
                RoundedRectangle(cornerRadius: 6).fill(.black)
                if let url = theme.preview, let image = NSImage(contentsOf: url) {
                    Image(nsImage: image).resizable().aspectRatio(contentMode: .fit).padding(3)
                } else {
                    Image(systemName: "photo").foregroundStyle(.secondary)
                }
            }
            .frame(height: 150)
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(selected ? Color.accentColor : .clear, lineWidth: 3))
            Text(theme.name).font(.caption).lineLimit(1).truncationMode(.middle)
        }
        .contentShape(Rectangle())
    }
}

struct DisplaySettings: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        Form {
            Slider(value: Binding(get: { model.brightness }, set: { model.setBrightness($0) }), in: 0...100) {
                Text("Brightness")
            }
            Toggle("Display mounted upside down", isOn: $model.reverse)
            LabeledContent("Status") { Text(model.status.label) }
        }
        .formStyle(.grouped)
        .padding()
    }
}

struct NetworkSettings: View {
    @EnvironmentObject var model: AppModel
    private let interfaces = AppModel.networkInterfaces

    var body: some View {
        Form {
            Picker("Wi-Fi interface", selection: $model.wifi) {
                Text("None").tag("")
                ForEach(interfaces, id: \.self) { Text($0).tag($0) }
            }
            Picker("Ethernet interface", selection: $model.ethernet) {
                Text("None").tag("")
                ForEach(interfaces, id: \.self) { Text($0).tag($0) }
            }
            TextField("Ping host", text: $model.pingHost)
            Text("Themes show these as the Wi-Fi (WLO) and Ethernet (ETH) sections. Interfaces are listed busiest first.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
        .padding()
    }
}
