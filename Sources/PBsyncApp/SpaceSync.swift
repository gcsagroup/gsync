import Foundation
import PBsyncCore

@MainActor extension AppModel {
    // 队列只保存空间身份。持久化历史在重启后仍可补传。
    func cancelScheduledSync(_ id: UUID) {
        syncTimers.removeValue(forKey: id)?.cancel()
        syncAgain.remove(id)
        retryDelay.removeValue(forKey: id)
    }

    func resumeSync() {
        for id in states.keys { requestSync(id, immediately: true) }
    }

    func pollSync() {
        #if os(macOS)
        pollSourceLinks()
        pollBookmarkFiles()
        #endif
        for id in states.keys where !syncInFlight.contains(id) { requestSync(id) }
    }

    func requestSync(_ id: UUID, immediately: Bool = false, after delay: UInt64 = 350_000_000) {
        guard states[id] != nil, !syncSuspended.contains(id) else { return }
        if syncInFlight.contains(id) { syncAgain.insert(id); return }
        if immediately { syncTimers.removeValue(forKey: id)?.cancel() }
        guard syncTimers[id] == nil else { return }
        syncTimers[id] = Task { [weak self] in
            if !immediately { try? await Task.sleep(nanoseconds: delay) }
            guard !Task.isCancelled, let self else { return }
            self.syncTimers[id] = nil
            await self.runSync(id, manual: false)
        }
    }

    func runSync(_ id: UUID, manual: Bool) async {
        guard states[id] != nil, let store = stores[id], !syncSuspended.contains(id) else { return }
        guard syncInFlight.insert(id).inserted else { syncAgain.insert(id); return }
        let session = spaceSession(id)
        var retry: UInt64?
        defer {
            syncInFlight.remove(id)
            if syncAgain.remove(id) != nil { requestSync(id) }
            else if let retry { requestSync(id, after: retry) }
        }
        do {
            // 后台任务读取目标空间已保存的配置，界面可能正在编辑另一个空间。
            let account = settingsAccount(id)
            let data: Data?
            do {
                data = try await Task.detached { try Keychain.read(account: account, allowInteraction: manual) }.value
            } catch {
                guard spaceSession(id) == session, states[id] != nil else { return }
                if (error as? PBError) == .unavailable {
                    // 本机钥匙串正被其他任务使用，不应显示为远端连接失败。
                    retry = 1_000_000_000
                    status[id] = "正在等待读取本机同步设置"
                } else {
                    status[id] = "无法读取同步位置，请打开连接来源检查钥匙串授权"
                }
                if manual { report(error) }
                return
            }
            guard spaceSession(id) == session, states[id] != nil else { return }
            let config = try data.map { try Coding.decode(StorageConfiguration.self, from: $0) } ?? StorageConfiguration()
            guard config.kind != .local else {
                retryDelay[id] = nil
                status[id] = "仅保存在本机 · 尚未设置设备间同步位置"
                if manual { report(PBError.invalid("请先选择主要同步位置。")) }
                return
            }
            status[id] = "正在与存储核对…"
            let result = try await store.synchronize(with: config.storage())
            guard spaceSession(id) == session, states[id] != nil else { return }
            try await refresh(id, userActivity: false)
            status[id] = result.message
            retryDelay[id] = nil
            if result.pending > 0 { syncAgain.insert(id) }
        } catch {
            guard spaceSession(id) == session, states[id] != nil else { return }
            let transient = (error as? PBError) == .unavailable || (error as NSError).domain == NSCocoaErrorDomain
            if transient {
                let seconds = min(60, (retryDelay[id] ?? 1) * 2)
                retryDelay[id] = seconds
                retry = seconds * 1_000_000_000
                status[id] = "本机数据已保留 · 访问同步位置失败，\(seconds) 秒后重试"
            } else {
                status[id] = (error as? PBError)?.localizedDescription ?? "请检查同步位置和权限"
            }
            if manual { report(error) }
        }
    }
}
