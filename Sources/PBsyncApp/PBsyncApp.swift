import SwiftUI
import PBsyncCore
#if os(macOS)
import AppKit
#endif

let pbsyncAccent = Color(red: 0.05, green: 0.48, blue: 0.43)

@main struct PBsyncApplication: App {
    @StateObject private var model = AppModel()
    @Environment(\.scenePhase) private var phase
    var body: some Scene {
        WindowGroup {
            MainView().id(model.sensitivePresentationID).environmentObject(model)
                .tint(pbsyncAccent)
                .onChange(of: phase) { _, newPhase in
                    if newPhase == .background { Task { await model.lockForInactivity() } }
                    else if newPhase == .active { model.touch(); model.resumeSync() }
                }
                .task(id: phase) {
                    while !Task.isCancelled {
                        try? await Task.sleep(nanoseconds: 30_000_000_000)
                        guard !Task.isCancelled else { return }
                        await model.checkIdle()
                        #if os(macOS)
                        if phase == .background { model.pollBookmarkFiles() }
                        else { model.pollSync() }
                        #else
                        if phase != .background { model.pollSync() }
                        #endif
                    }
                }
                #if os(macOS)
                .onReceive(DistributedNotificationCenter.default().publisher(for: Notification.Name("com.apple.screenIsLocked"))) { _ in Task { await model.lockAll() } }
                .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.willSleepNotification)) { _ in Task { await model.lockAll() } }
                .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.sessionDidResignActiveNotification)) { _ in Task { await model.lockAll() } }
                #endif
        }
        #if os(macOS)
        .defaultSize(width: 1180, height: 780)
        .commands {
            CommandGroup(replacing: .newItem) { Button("锁定全部空间") { Task { await model.lockAll() } }.keyboardShortcut("l", modifiers: [.command, .shift]) }
        }
        #endif
    }
}
