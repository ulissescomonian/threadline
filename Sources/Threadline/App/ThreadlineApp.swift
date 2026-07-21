import AppKit
import SwiftUI

@main
struct ThreadlineApp: App {
    @State private var model = AppModel()
    @State private var dockPresentation = DockPresentationController()
    @AppStorage("showMenuBarItem") private var showMenuBarItem = true

    var body: some Scene {
        WindowGroup("Threadline", id: "library") {
            AppContainerView(model: model, dockPresentation: dockPresentation)
        }
        .defaultSize(width: 1240, height: 780)
        .windowToolbarStyle(.unified(showsTitle: true))
        .commands {
            // The library is conceptually a singleton. WindowGroup keeps a
            // menu-bar-disabled app alive after its last window closes, while
            // removing New Window prevents accidental duplicate libraries.
            CommandGroup(replacing: .newItem) { }

            CommandGroup(after: .sidebar) {
                Button("Refresh Library") {
                    Task { await model.refresh() }
                }
                .disabled(model.isReconciliationBusy)
                .keyboardShortcut("r", modifiers: [.command])

                Button("Sync Now") {
                    Task { await model.syncNow() }
                }
                .disabled(model.isReconciliationBusy)
                .keyboardShortcut("r", modifiers: [.command, .shift])
            }
        }

        MenuBarExtra(isInserted: $showMenuBarItem) {
            MenuBarSceneContent(model: model, dockPresentation: dockPresentation)
        } label: {
            ThreadlineMenuBarLabel(model: model)
        }
        .menuBarExtraStyle(.window)

        Settings {
            ThreadlineSettingsView(model: model)
                .background {
                    DockMenuBarPreferenceObserver(controller: dockPresentation)
                }
        }
        .defaultSize(width: 600, height: 480)
        .windowResizability(.contentSize)
    }

}

private struct ThreadlineMenuBarLabel: View {
    @Bindable var model: AppModel

    var body: some View {
        Image(nsImage: ThreadlineMenuBarIcon.image)
            .accessibilityLabel("Threadline")
            .accessibilityValue(statusDescription)
            .help("Threadline")
    }

    private var statusDescription: String {
        if model.isSyncing {
            guard let progress = model.syncProgress else { return "Preparing sync" }
            return "\(progress.phase.threadlineTitle), \(progress.threadlineCompactProgress)"
        }
        if model.automaticReconciliationError != nil { return "Needs attention" }
        if model.health.hasActionableIssues { return "Needs attention" }
        return "Ready"
    }
}

private struct AppContainerView: View {
    @Bindable var model: AppModel
    let dockPresentation: DockPresentationController

    var body: some View {
        RootView(model: model)
            .background {
                LibraryWindowRegistrationView(controller: dockPresentation)
                    .frame(width: 0, height: 0)
                DockMenuBarPreferenceObserver(controller: dockPresentation)
            }
    }
}

private struct MenuBarSceneContent: View {
    @Bindable var model: AppModel
    let dockPresentation: DockPresentationController
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        MenuBarContent(
            model: model,
            openMainWindow: {
                Task { @MainActor in
                    if dockPresentation.focusLibraryWindowIfAvailable() {
                        return
                    }
                    await dockPresentation.prepareToOpenLibrary()
                    openWindow(id: "library")
                    await Task.yield()
                    dockPresentation.focusLibraryWindowIfAvailable()
                }
            },
            openSettings: {
                openSettings()
                NSApp.activate(ignoringOtherApps: true)
            },
            quit: {
                NSApp.terminate(nil)
            }
        )
    }
}
