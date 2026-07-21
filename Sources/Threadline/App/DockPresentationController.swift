import AppKit
import Observation
import SwiftUI

enum DockPresentationPolicy {
    static func activationPolicy(
        hasLibraryWindow: Bool,
        isPreparingToOpenLibrary: Bool,
        showsMenuBarItem: Bool
    ) -> NSApplication.ActivationPolicy {
        if !showsMenuBarItem || hasLibraryWindow || isPreparingToOpenLibrary {
            return .regular
        }
        return .accessory
    }
}

@MainActor
@Observable
final class DockPresentationController {
    private final class WeakWindow {
        weak var value: NSWindow?

        init(_ value: NSWindow) {
            self.value = value
        }
    }

    private var libraryWindows: [ObjectIdentifier: WeakWindow] = [:]
    private var closeObservers: [ObjectIdentifier: NSObjectProtocol] = [:]
    private var isPreparingToOpenLibrary = false
    private var openRequestGeneration = 0
    private var showsMenuBarItem: Bool

    init(defaults: UserDefaults = .standard) {
        if defaults.object(forKey: "showMenuBarItem") == nil {
            showsMenuBarItem = true
        } else {
            showsMenuBarItem = defaults.bool(forKey: "showMenuBarItem")
        }
    }

    func registerLibraryWindow(_ window: NSWindow) {
        let identifier = ObjectIdentifier(window)
        let shouldFocusForExplicitOpen = isPreparingToOpenLibrary
        if libraryWindows[identifier]?.value == nil {
            libraryWindows[identifier] = WeakWindow(window)
        }
        if closeObservers[identifier] == nil {
            closeObservers[identifier] = NotificationCenter.default.addObserver(
                forName: NSWindow.willCloseNotification,
                object: window,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.libraryWindowDidClose(identifier)
                }
            }
        }

        isPreparingToOpenLibrary = false
        reconcileActivationPolicy()
        if shouldFocusForExplicitOpen {
            focus(window)
        }
    }

    func setMenuBarItemVisible(_ isVisible: Bool) {
        guard showsMenuBarItem != isVisible else { return }
        showsMenuBarItem = isVisible
        reconcileActivationPolicy()
    }

    func prepareToOpenLibrary() async {
        openRequestGeneration += 1
        let generation = openRequestGeneration
        isPreparingToOpenLibrary = true
        reconcileActivationPolicy()
        NSApp.activate(ignoringOtherApps: true)
        await Task.yield()

        // If SwiftUI cannot satisfy the open request, do not pin the Dock
        // forever. A successfully attached bridge clears this state earlier.
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard let self,
                  self.openRequestGeneration == generation,
                  self.liveLibraryWindows.isEmpty else { return }
            self.isPreparingToOpenLibrary = false
            self.reconcileActivationPolicy()
        }
    }

    @discardableResult
    func focusLibraryWindowIfAvailable() -> Bool {
        guard let window = liveLibraryWindows.first else { return false }
        isPreparingToOpenLibrary = false
        reconcileActivationPolicy()
        focus(window)
        return true
    }

    private var liveLibraryWindows: [NSWindow] {
        var windows: [NSWindow] = []
        var staleIdentifiers: [ObjectIdentifier] = []
        for (identifier, weakWindow) in libraryWindows {
            if let window = weakWindow.value {
                windows.append(window)
            } else {
                staleIdentifiers.append(identifier)
            }
        }
        for identifier in staleIdentifiers {
            removeTracking(for: identifier)
        }
        return windows
    }

    private func libraryWindowDidClose(_ identifier: ObjectIdentifier) {
        removeTracking(for: identifier)
        reconcileActivationPolicy()
    }

    private func removeTracking(for identifier: ObjectIdentifier) {
        libraryWindows.removeValue(forKey: identifier)
        if let observer = closeObservers.removeValue(forKey: identifier) {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    private func reconcileActivationPolicy() {
        let desired = DockPresentationPolicy.activationPolicy(
            hasLibraryWindow: !liveLibraryWindows.isEmpty,
            isPreparingToOpenLibrary: isPreparingToOpenLibrary,
            showsMenuBarItem: showsMenuBarItem
        )
        guard NSApp.activationPolicy() != desired else { return }
        NSApp.setActivationPolicy(desired)
    }

    private func focus(_ window: NSWindow) {
        if window.isMiniaturized {
            window.deminiaturize(nil)
        }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

/// Embedded only in the `library` scene, so Settings and menu-bar windows can
/// never be mistaken for the main library window.
struct LibraryWindowRegistrationView: NSViewRepresentable {
    let controller: DockPresentationController

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        registerWindow(of: view)
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        registerWindow(of: nsView)
    }

    private func registerWindow(of view: NSView) {
        DispatchQueue.main.async { [weak view, weak controller] in
            guard let window = view?.window else { return }
            controller?.registerLibraryWindow(window)
        }
    }
}

struct DockMenuBarPreferenceObserver: View {
    let controller: DockPresentationController
    @AppStorage("showMenuBarItem") private var showMenuBarItem = true

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .task {
                controller.setMenuBarItemVisible(showMenuBarItem)
            }
            .onChange(of: showMenuBarItem) { _, isVisible in
                controller.setMenuBarItemVisible(isVisible)
            }
            .accessibilityHidden(true)
    }
}
