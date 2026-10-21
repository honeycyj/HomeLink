import AppKit
import Network
import Observation

@MainActor @Observable
final class DDNSStore {
    private(set) var configuration = DDNSConfiguration()
    private(set) var isLoading = true
    private(set) var busy = false
    private(set) var status = "未启用"
    private(set) var error: String?
    private(set) var logs: [String] = []
    private(set) var currentIP: String?
    private(set) var recordIP: String?
    private(set) var sources = ""
    private(set) var nextAttempt: Date?
    @ObservationIgnored private let storage: DDNSConfigurationStorage
    @ObservationIgnored private let backend: any DDNSBackend
    @ObservationIgnored private let tokens: any DDNSTokenStorage
    @ObservationIgnored private var startup: Task<Void, Never>?
    @ObservationIgnored private var checkTask: Task<Void, Never>?
    @ObservationIgnored private var timer: Task<Void, Never>?
    @ObservationIgnored private var generation = UUID()
    @ObservationIgnored private var writeRevision: UInt64 = 0
    @ObservationIgnored private var failureCount = 0
    @ObservationIgnored private var loadFailed = false
    @ObservationIgnored private var sleeping = false
    @ObservationIgnored private var networkAvailable = true
    @ObservationIgnored private var monitor: NWPathMonitor?
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    @ObservationIgnored private var clockObserver: NSObjectProtocol?

    init(directory: URL? = nil, backend: any DDNSBackend = LiveDDNSBackend(), tokens: any DDNSTokenStorage = KeychainDDNSTokenStorage(), observeLifecycle: Bool = true) {
        storage = DDNSConfigurationStorage(directory: directory ?? HomeLinkStorage.directory)
        self.backend = backend; self.tokens = tokens
        if observeLifecycle { installObservers() }
        startup = Task { [weak self] in
            guard let self else { return }
            do {
                var saved = try await self.storage.load()
                try saved.plan.validate()
                if saved.plan.mode == .scheduled && saved.timeZoneIdentifier != TimeZone.current.identifier {
                    saved.nextCheck = saved.plan.next(after: .now)
                }
                saved.timeZoneIdentifier = TimeZone.current.identifier
                self.configuration = saved
                self.currentIP = saved.lastIP
                self.isLoading = false
                self.resume()
            } catch {
                self.isLoading = false; self.loadFailed = true
                self.error = "无法读取 DDNS 设置，未启用自动更新。原配置文件已保留。"
            }
        }
    }

    func prepare() async { await startup?.value }

    func preview(domain: String, token: String) async throws -> (DDNSPreview, String) {
        await prepare()
        guard !loadFailed else { throw HomeLinkError.message("原 DDNS 配置无法读取，请先保留原文件并检查，未覆盖设置。") }
        guard !busy, !configuration.enabled else { throw HomeLinkError.message("请先暂停自动更新，再修改域名和令牌。") }
        let domain = try DDNSConfiguration.normalizedDomain(domain)
        let token = token.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolved = token.isEmpty ? try await tokens.load() : token
        guard !resolved.contains(where: \.isWhitespace), resolved.utf8.count <= 1024 else { throw HomeLinkError.message("请填写有效的 API Token。") }
        try Task.checkCancellation()
        busy = true; defer { busy = false }
        let result = try await backend.preview(domain: domain, token: resolved)
        try Task.checkCancellation()
        currentIP = result.observation.address; recordIP = result.record.address; sources = result.observation.sources
        return (result, resolved)
    }

    /// Called only after the native confirmation explicitly identifies the domain and candidate IP.
    func enable(preview: DDNSPreview, token: String, plan: DDNSPlan) async throws {
        guard !loadFailed, !busy, !configuration.enabled else { throw HomeLinkError.message("当前状态无法启用，请稍后重试。") }
        try plan.validate()
        try Task.checkCancellation()
        let operation = generation
        busy = true
        do {
            var candidate = configuration
            candidate.domain = preview.record.domain; candidate.zoneID = preview.record.zoneID
            candidate.recordID = preview.record.recordID; candidate.trustedNetwork = preview.observation.network
            candidate.plan = plan
            candidate.timeZoneIdentifier = TimeZone.current.identifier
            let current = try await backend.inspect(candidate, token: token)
            try Task.checkCancellation()
            guard generation == operation else { throw CancellationError() }
            guard current.observation == preview.observation, current.record == preview.record else {
                throw HomeLinkError.message("确认期间公网地址、网络或 DNS 记录已变化，请重新验证后确认。")
            }
            try await tokens.save(token)
            try Task.checkCancellation()
            guard generation == operation else { throw CancellationError() }
            candidate.enabled = true; candidate.nextCheck = .now
            try await persist(candidate)
            guard generation == operation else { throw CancellationError() }
            if Task.isCancelled {
                candidate.enabled = false; candidate.nextCheck = nil
                try await persist(candidate)
                configuration = candidate; status = "已暂停"
                throw CancellationError()
            }
            configuration = candidate; failureCount = 0; error = nil; busy = false
            checkNow()
        } catch { if generation == operation { busy = false }; throw error }
    }

    func disable() async {
        await prepare()
        cancelWork(); configuration.enabled = false; configuration.nextCheck = nil
        status = "已暂停"; error = nil; nextAttempt = nil
        guard !loadFailed else {
            error = "原 DDNS 配置无法读取，自动更新未运行。原文件已保留。"
            return
        }
        do { try await persist(configuration) }
        catch { self.error = "本次已暂停，但无法保存暂停状态。退出前请重试。" }
    }

    func savePlan(_ plan: DDNSPlan) async throws {
        await prepare()
        try plan.validate()
        guard !loadFailed else { throw HomeLinkError.message("原 DDNS 配置无法读取，未覆盖设置。") }
        guard !busy else { throw HomeLinkError.message("正在检查，请稍后修改计划。") }
        let operation = generation
        timer?.cancel(); timer = nil
        busy = true
        defer { if generation == operation { busy = false; arm() } }
        var candidate = configuration
        candidate.plan = plan
        candidate.timeZoneIdentifier = TimeZone.current.identifier
        candidate.nextCheck = candidate.enabled ? plan.next(after: .now) : nil
        try await persist(candidate)
        guard generation == operation else { throw CancellationError() }
        configuration = candidate
    }

    func checkNow() {
        guard !isLoading, configuration.enabled, !busy, !sleeping, networkAvailable else { return }
        timer?.cancel(); timer = nil
        let currentGeneration = generation
        let snapshot = configuration
        busy = true; status = "正在检查"
        checkTask = Task { [weak self] in
            guard let self else { return }
            var retry: TimeInterval?
            var attemptedUpdate = false
            do {
                let token = try await self.tokens.load()
                try Task.checkCancellation()
                let result = try await self.backend.inspect(snapshot, token: token)
                try Task.checkCancellation()
                guard self.generation == currentGeneration else { return }
                self.currentIP = result.observation.address; self.recordIP = result.record.address; self.sources = result.observation.sources
                guard result.observation.network == snapshot.trustedNetwork else {
                    throw HomeLinkError.message("网络出口与首次确认时不同，已暂停写入。请在当前家庭网络重新验证。")
                }
                let changed = result.record.address != result.observation.address
                if changed {
                    attemptedUpdate = true
                    try await self.backend.update(snapshot, address: result.observation.address, token: token)
                    try Task.checkCancellation()
                }
                guard self.generation == currentGeneration else { return }
                self.configuration.lastCheck = .now
                self.configuration.lastIP = result.observation.address
                if changed { self.configuration.lastUpdate = .now }
                self.recordIP = result.observation.address
                self.configuration.nextCheck = snapshot.plan.next(after: .now)
                self.status = changed ? "已同步 · 公网地址已更新" : "已同步 · 地址没有变化"
                self.error = nil; self.failureCount = 0
                self.appendLog(self.status)
                try await self.persist(self.configuration)
            } catch {
                guard self.generation == currentGeneration, !Task.isCancelled else { return }
                self.failureCount = min(self.failureCount + 1, 8)
                retry = min(3600, 60 * pow(2, Double(self.failureCount - 1)))
                if let failure = error as? DDNSHTTP.Failure, let requested = failure.retryAfter {
                    retry = max(retry!, min(max(requested, 60), 86_400))
                }
                self.status = attemptedUpdate ? "更新结果待确认" : "需要处理 · 暂停写入"
                if attemptedUpdate { self.recordIP = nil }
                self.error = error.localizedDescription
                self.appendLog(error.localizedDescription)
            }
            guard self.generation == currentGeneration else { return }
            self.busy = false; self.checkTask = nil
            self.arm(retryAfter: retry)
        }
    }

    func waitForCheck() async { await checkTask?.value }

    func shutdown() async {
        let active = checkTask
        cancelWork()
        await active?.value
        monitor?.cancel()
        for observer in observers { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
        observers.removeAll()
        if let clockObserver { NotificationCenter.default.removeObserver(clockObserver) }
        clockObserver = nil
    }

    private func persist(_ value: DDNSConfiguration) async throws {
        writeRevision += 1
        try await storage.save(value, revision: writeRevision)
    }

    private func arm(retryAfter: TimeInterval? = nil) {
        timer?.cancel(); timer = nil
        guard configuration.enabled, !sleeping, networkAvailable else { return }
        let deadline = retryAfter.map { Date.now.addingTimeInterval($0) } ?? configuration.nextCheck ?? configuration.plan.next(after: .now)
        guard let deadline else { return }
        nextAttempt = deadline
        timer = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(max(0.1, deadline.timeIntervalSinceNow))) }
            catch { return }
            guard !Task.isCancelled else { return }
            self?.checkNow()
        }
    }

    private func resume() {
        guard !isLoading, configuration.enabled, !sleeping, networkAvailable else { return }
        let overdue = (configuration.nextCheck ?? .distantPast) <= .now
        if configuration.plan.catchUp && (configuration.plan.mode == .interval || overdue) {
            checkNow()
        } else {
            if overdue { configuration.nextCheck = configuration.plan.next(after: .now) }
            status = "等待下次检查"; arm()
        }
    }

    private func cancelWork() {
        generation = UUID(); timer?.cancel(); timer = nil
        checkTask?.cancel(); checkTask = nil; busy = false
    }
    private func appendLog(_ message: String) {
        logs.append(Date.now.formatted(date: .omitted, time: .standard) + "  " + message)
        if logs.count > 30 { logs.removeFirst(logs.count - 30) }
    }
    private func installObservers() {
        let monitor = NWPathMonitor(); self.monitor = monitor
        monitor.pathUpdateHandler = { [weak self] path in
            let available = path.status == .satisfied
            Task { @MainActor [weak self] in
                guard let self else { return }
                let recovered = !self.networkAvailable && available
                self.networkAvailable = available
                if !available && self.configuration.enabled { self.cancelWork(); self.status = "等待网络 · 恢复后继续" }
                else if recovered { self.resume() }
            }
        }
        monitor.start(queue: DispatchQueue(label: "local.homelink.ddns.network"))
        let center = NSWorkspace.shared.notificationCenter
        observers.append(center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in self?.sleeping = true; self?.cancelWork() }
        })
        observers.append(center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in self?.sleeping = false; self?.resume() }
        })
        clockObserver = NotificationCenter.default.addObserver(forName: .NSSystemTimeZoneDidChange, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.configuration.enabled, !self.busy else { return }
                self.configuration.nextCheck = self.configuration.plan.next(after: .now)
                self.configuration.timeZoneIdentifier = TimeZone.current.identifier
                self.arm()
            }
        }
    }
}
