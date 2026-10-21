import SwiftUI

struct DDNSPreferencesView: View {
    @Bindable var store: DDNSStore
    let back: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var domain = ""
    @State private var token = ""
    @State private var plan = DDNSPlan()
    @State private var editingPlan = false
    @State private var operationError: String?
    @State private var detectingIP = false
    @State private var detectedObservation: PublicIPObservation?
    @State private var detectionError: String?
    @State private var detectionTask: Task<Void, Never>?
    @State private var showingDirectHelp = false
    @State private var verifying = false
    @State private var verification: Task<Void, Never>?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            SettingsHeading(title: "公网地址", back: back)
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if store.configuration.enabled {
                        Toggle("自动更新 Cloudflare DDNS", isOn: Binding(get: { store.configuration.enabled }, set: { enabled in
                            if !enabled { Task { await store.disable() } }
                        })).toggleStyle(.switch).controlSize(.small).disabled(store.isLoading || verifying)
                    }
                    if store.configuration.enabled { activeStatus } else { setupFields }
                    HStack(spacing: 12) {
                        Text("更新计划").frame(width: 72, alignment: .leading)
                        HStack(spacing: 8) {
                            TextField("更新计划", text: .constant(plan.summary))
                                .textFieldStyle(.roundedBorder).disabled(true)
                                .help(plan.summary)
                            Button("修改") { editingPlan = true }
                                .disabled(store.isLoading || store.busy || verifying)
                        }
                    }
                    Text("使用「仅 DNS」的 IPv4 A 记录。DDNS 不会自动完成路由器端口映射，也不能解决运营商共享公网地址。")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                        .padding(.leading, 84)
                    if let error = operationError ?? store.error {
                        VStack(alignment: .leading, spacing: 8) {
                            SettingsStatus(text: error, symbol: "exclamationmark.triangle.fill", color: .orange)
                            diagnosticCopyButton(error: error)
                        }.padding(.leading, 84)
                    }
                    Text("HomeLink 运行且 Mac 唤醒时执行检查，退出或睡眠时暂停。系统时区变化后按新的本地时间执行。")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                        .padding(.leading, 84)
                }.padding(.vertical, 1)
            }
            Divider()
            HStack {
                Spacer()
                if verifying || store.busy { ProgressView().controlSize(.small) }
                if store.configuration.enabled {
                    Button("完成") { dismiss() }.buttonBorderShape(.capsule).controlSize(.large).buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                } else {
                    Button("验证并启用", action: verify).buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                        .disabled(domain.isEmpty || detectedObservation == nil || store.isLoading || store.busy || verifying || detectingIP)
                }
            }
        }
        .font(.system(size: 13)).padding(24)
        .task {
            await store.prepare()
            domain = store.configuration.domain; plan = store.configuration.plan
        }
        .sheet(isPresented: $editingPlan) {
            DDNSPlanView(plan: plan) { candidate in try await store.savePlan(candidate); plan = candidate }
        }
        .onDisappear { verification?.cancel(); detectionTask?.cancel() }
    }

    private var setupFields: some View {
        VStack(alignment: .leading, spacing: 16) {
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 16) {
                GridRow {
                    Text("域名").frame(width: 72, alignment: .leading)
                    TextField("域名", text: $domain, prompt: Text("home.example.com"))
                        .textFieldStyle(.roundedBorder)
                }
                GridRow {
                    Text("API Token").frame(width: 72, alignment: .leading)
                    SecureField("API Token", text: $token, prompt: Text(store.configuration.domain.isEmpty ? "粘贴 API Token" : "留空以复用已保存令牌"))
                        .textFieldStyle(.roundedBorder)
                }
            }
            Text("令牌保存在本机钥匙串，仅需目标区域的 DNS 编辑及区域读取权限。首次验证只读取信息，确认后才更新记录。")
                .font(.system(size: 11)).foregroundStyle(.secondary)
                .padding(.leading, 84)
            HStack(spacing: 12) {
                publicIPLabel.frame(width: 72, alignment: .leading)
                HStack(spacing: 8) {
                    TextField("公网 IPv4", text: .constant(detectedObservation?.address ?? ""),
                              prompt: Text(detectingIP ? "正在检测" : "等待检测"))
                        .textFieldStyle(.roundedBorder).disabled(true)
                    if detectingIP { ProgressView().controlSize(.small) }
                    Button(detectingIP ? "检测中" : "检测", action: detectIP)
                        .disabled(detectingIP || store.isLoading)
                }
            }
            VStack(alignment: .leading, spacing: 4) {
                if let detectionError {
                    Label(detectionError, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                    Text("点击公网 IPv4 旁的说明图标，查看直连设置后重试。")
                    diagnosticCopyButton(error: detectionError)
                } else if let detectedObservation {
                    Text(sourceSummary(detectedObservation.sources))
                    Text("请确认这是家庭网络的公网 IP，然后点击「验证并启用」。")
                } else {
                    Text("先点击「检测」，获取这台 Mac 所在网络的公网 IP。")
                }
            }.font(.caption).foregroundStyle(.secondary).padding(.leading, 84)

        }.disabled(store.busy || verifying)
    }

    private var activeStatus: some View {
        VStack(alignment: .leading, spacing: 16) {
            SettingsCard {
                SettingsStatus(text: store.status, symbol: store.error != nil ? "exclamationmark.triangle.fill" : (store.status.hasPrefix("已同步") ? "checkmark.circle.fill" : "clock"), color: store.error != nil ? .orange : (store.status.hasPrefix("已同步") ? .green : .secondary))
                Text(store.sources.isEmpty ? "等待检测公网 IP" : sourceSummary(store.sources))
                    .font(.caption).foregroundStyle(.secondary)
                Text(store.configuration.domain).font(.system(size: 18, weight: .semibold)).textSelection(.enabled)
                LabeledContent { Text(store.currentIP ?? "等待检测") } label: { publicIPLabel }
                LabeledContent("DNS 记录", value: store.recordIP ?? "等待检测")
                Text("上次检查  \(dateLabel(store.configuration.lastCheck))\n上次更新  \(dateLabel(store.configuration.lastUpdate))")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                Button("立即检查") { store.checkNow() }.disabled(store.busy)
            }
            if let next = store.nextAttempt ?? store.configuration.nextCheck {
                Text("下次计划检查：" + next.formatted(date: .abbreviated, time: .shortened))
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            }
            Button("暂停并修改域名或令牌") { Task { await store.disable() } }.disabled(verifying)
        }
    }

    private var publicIPLabel: some View {
        HStack(spacing: 4) {
            Text("公网 IPv4")
            Button { showingDirectHelp.toggle() } label: {
                Image(systemName: "exclamationmark.circle")
                    .foregroundStyle(detectionError != nil || store.error != nil ? Color.orange : Color.secondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("公网 IP 直连设置说明")
            .help("查看代理直连设置说明")
            .popover(isPresented: $showingDirectHelp, arrowEdge: .bottom) {
                PublicIPDirectHelpView()
            }
        }.fixedSize()
    }

    private func sourceSummary(_ sources: String) -> String {
        let count = sources.split(separator: "、").count
        return "已通过 \(count) 个来源核对"
    }

    private func diagnosticCopyButton(error: String) -> some View {
        CopyButton(value: diagnosticInformation(error: error), title: "复制诊断信息", copiedTitle: "已复制诊断信息")
            .controlSize(.small)
    }

    private func diagnosticInformation(error: String) -> String {
        // Deliberately exclude the entered token and all Keychain contents.
        let sources = detectedObservation?.sources ?? store.sources
        return (["HomeLink DDNS 诊断", "时间：" + Date.now.formatted(),
                 "域名：" + domain, "状态：" + store.status, "错误：" + error,
                 "查询来源：" + sources, "更新计划：" + plan.summary] + store.logs).joined(separator: "\n")
    }

    private func detectIP() {
        detectingIP = true
        detectedObservation = nil
        detectionError = nil
        operationError = nil
        detectionTask = Task {
            defer { detectingIP = false }
            do {
                let result = try await PublicIPDetector().observe()
                try Task.checkCancellation()
                detectedObservation = result
            } catch is CancellationError { }
            catch { detectionError = error.localizedDescription }
        }
    }

    private func verify() {
        guard let detectedObservation else { return }
        verifying = true; operationError = nil
        verification = Task {
            defer { verifying = false }
            do {
                let (preview, resolvedToken) = try await store.preview(domain: domain, token: token)
                try Task.checkCancellation()
                guard preview.observation.address == detectedObservation.address,
                      preview.observation.network == detectedObservation.network else {
                    self.detectedObservation = nil
                    detectionError = "公网 IP 或本地网络已变化，请重新检测并确认。"
                    return
                }
                guard await SystemDialogs.confirm(title: "启用公网地址更新？",
                    message: "域名与读取权限验证通过。\n\n将 \(preview.record.domain) 的 A 记录更新为 \(preview.observation.address)。请确认这是家庭网络的公网地址，而非代理或 VPN 出口。",
                    action: "确认并启用") else { return }
                try await store.enable(preview: preview, token: resolvedToken, plan: plan)
                token = ""
            } catch { operationError = error.localizedDescription }
        }
    }
    private func dateLabel(_ date: Date?) -> String { date?.formatted(date: .abbreviated, time: .shortened) ?? "尚未执行" }
}
