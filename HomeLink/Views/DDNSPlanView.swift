import SwiftUI

struct DDNSPlanView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var plan: DDNSPlan
    @State private var interval: String
    @State private var unit = 1
    @State private var saving = false
    @State private var error: String?
    let save: (DDNSPlan) async throws -> Void

    init(plan: DDNSPlan, save: @escaping (DDNSPlan) async throws -> Void) {
        _plan = State(initialValue: plan)
        let hours = plan.intervalMinutes >= 60 && plan.intervalMinutes % 60 == 0
        _interval = State(initialValue: String(hours ? plan.intervalMinutes / 60 : plan.intervalMinutes))
        _unit = State(initialValue: hours ? 60 : 1)
        self.save = save
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("更新计划").font(.system(size: 18, weight: .semibold))
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Picker("检查方式", selection: $plan.mode) {
                        Text("按间隔检查").tag(DDNSPlan.Mode.interval)
                        Text("定时检查").tag(DDNSPlan.Mode.scheduled)
                    }.pickerStyle(.menu)
                    if plan.mode == .interval { intervalFields } else { scheduledFields }
                    Toggle(plan.mode == .interval ? "启动、唤醒或网络恢复后检查一次" : "错过任务时，在恢复后补查一次", isOn: $plan.catchUp)
                        .toggleStyle(.checkbox)
                    Text("使用这台 Mac 的本地时区。HomeLink 需要保持运行；睡眠或退出期间暂停。错过多个时间点只补查一次。")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                    if let error { Text(error).font(.system(size: 12)).foregroundStyle(.red) }
                }.padding(.vertical, 1)
            }
            Divider()
            HStack {
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("保存计划") {
                    do {
                        if plan.mode == .interval {
                            guard let value = Int(interval), (1...(10_080 / unit)).contains(value) else {
                                throw HomeLinkError.message("请输入有效的整数，间隔应在 1 分钟到 7 天之间。")
                            }
                            plan.intervalMinutes = value * unit
                        }
                        try plan.validate(); saving = true
                        Task {
                            defer { saving = false }
                            do { try await save(plan); dismiss() } catch { self.error = error.localizedDescription }
                        }
                    } catch { self.error = error.localizedDescription }
                }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
            }
        }.buttonStyle(SecondaryActionButtonStyle()).controlSize(.regular)
        .buttonBorderShape(.roundedRectangle)
        .font(.system(size: 13)).padding(24).frame(width: 520, height: 570).disabled(saving)
        .interactiveDismissDisabled(saving)
    }

    private var intervalFields: some View {
        SettingsCard {
            HStack {
                Text("每隔")
                TextField("间隔", text: $interval).textFieldStyle(.roundedBorder).frame(width: 72)
                Picker("单位", selection: $unit) { Text("分钟").tag(1); Text("小时").tag(60) }.labelsHidden().frame(width: 100)
                Text("检查一次").foregroundStyle(.secondary)
            }
            Text("可自定义数值，最短 1 分钟。只有公网 IP 改变时才更新 DNS。")
                .font(.system(size: 12)).foregroundStyle(.secondary)
        }
    }

    private var scheduledFields: some View {
        VStack(alignment: .leading, spacing: 16) {
            Picker("重复", selection: $plan.repetition) {
                Text("每天").tag(DDNSPlan.Repetition.daily)
                Text("工作日").tag(DDNSPlan.Repetition.weekdays)
                Text("每周").tag(DDNSPlan.Repetition.weekly)
            }.pickerStyle(.menu)
            if plan.repetition == .weekly {
                SettingsCard {
                    Text("选择星期").fontWeight(.medium)
                    HStack(spacing: 12) { ForEach([2, 3, 4, 5], id: \.self) { weekday($0) } }
                    HStack(spacing: 12) { ForEach([6, 7, 1], id: \.self) { weekday($0) } }
                }
            }
            SettingsCard {
                ForEach(Array(plan.times.indices), id: \.self) { index in
                    HStack {
                        Text("时间 \(index + 1)").frame(width: 64, alignment: .leading)
                        DatePicker("时间 \(index + 1)", selection: timeBinding(index), displayedComponents: .hourAndMinute).labelsHidden()
                        Spacer()
                        Button("移除") { plan.times.remove(at: index) }.disabled(plan.times.count == 1)
                    }
                }
                Button("添加时间") {
                    let used = Set(plan.times.map(\.id))
                    let start = ((plan.times.last?.id ?? 420) + 60) % 1440
                    if let available = (0..<48).map({ (start + $0 * 30) % 1440 }).first(where: { !used.contains($0) }) {
                        plan.times.append(CheckTime(hour: available / 60, minute: available % 60))
                    }
                }
                Text(plan.summary).font(.system(size: 12)).foregroundStyle(.secondary)
            }
        }
    }

    private func weekday(_ day: Int) -> some View {
        let names = [1: "周日", 2: "周一", 3: "周二", 4: "周三", 5: "周四", 6: "周五", 7: "周六"]
        return Toggle(names[day]!, isOn: Binding(get: { plan.weekdays.contains(day) }, set: { on in
            if on { plan.weekdays.insert(day) } else { plan.weekdays.remove(day) }
        })).toggleStyle(.checkbox)
    }
    private func timeBinding(_ index: Int) -> Binding<Date> {
        Binding(get: {
            guard plan.times.indices.contains(index) else { return .now }
            let t = plan.times[index]
            return Calendar.current.date(from: DateComponents(year: 2001, month: 1, day: 1, hour: t.hour, minute: t.minute)) ?? .now
        }, set: { date in
            guard plan.times.indices.contains(index) else { return }
            let c = Calendar.current.dateComponents([.hour, .minute], from: date)
            plan.times[index] = CheckTime(hour: c.hour ?? 0, minute: c.minute ?? 0)
        })
    }
}
