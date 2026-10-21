import SwiftUI
import Charts

struct UsageView: View {
    @Environment(Client.self) private var client
    @Environment(\.dismiss) private var dismiss
    @State private var days = 14
    @State private var metric = Metric.output
    @State private var report: UsageReport?
    @State private var plan: PlanUsage?
    @State private var error: String?

    enum Metric: String, CaseIterable {
        case output = "Output", input = "Input"
        func value(_ d: UsageReport.Day) -> Int { self == .output ? d.output : d.input + d.cacheRead + d.cacheWrite }
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    if let plan, plan.available {
                        PlanMeter(plan: plan)
                    } else {
                        Text(plan == nil ? "Loading…" : "Plan limits show when Claude Code on your Mac is logged in with a Claude subscription.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                } header: {
                    Text("Plan limits\(plan?.subscription.map { " · \($0.capitalized)" } ?? "")")
                }
                if let report {
                    Section {
                        HStack {
                            stat("Today", report.days.last.map(metric.value) ?? 0)
                            Divider()
                            stat("Last 7 days", report.days.suffix(7).map(metric.value).reduce(0, +))
                            Divider()
                            stat("\(days) days", report.days.map(metric.value).reduce(0, +))
                        }
                        .frame(maxWidth: .infinity)
                        Chart(report.days) { d in
                            BarMark(x: .value("Day", d.day, unit: .day), y: .value("Tokens", metric.value(d)))
                                .foregroundStyle(Color.accentColor.gradient)
                                .cornerRadius(3)
                        }
                        .chartYAxis { AxisMarks { v in AxisGridLine(); AxisValueLabel { if let n = v.as(Int.self) { Text(short(n)) } } } }
                        .overlay {
                            if report.days.allSatisfy({ metric.value($0) == 0 }) {
                                Text("No usage in this period").font(.callout).foregroundStyle(.secondary)
                            }
                        }
                        .frame(height: 200)
                        .padding(.vertical, 8)
                        Picker("Tokens", selection: $metric) {
                            ForEach(Metric.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                        }
                        .pickerStyle(.segmented)
                    } footer: {
                        Text(metric == .output ? "Tokens Claude wrote." : "Tokens Claude read, including cached context.")
                    }
                    if !report.projects.isEmpty {
                        Section("By project") {
                            let top = report.projects.map { metric == .output ? $0.output : $0.input + $0.cacheRead + $0.cacheWrite }.max() ?? 1
                            ForEach(report.projects) { p in
                                let v = metric == .output ? p.output : p.input + p.cacheRead + p.cacheWrite
                                VStack(alignment: .leading, spacing: 4) {
                                    HStack { Text(p.name).lineLimit(1); Spacer(); Text(short(v)).foregroundStyle(.secondary).monospacedDigit() }
                                    ProgressView(value: Double(v), total: Double(max(top, 1))).tint(.accentColor)
                                }
                                .accessibilityElement(children: .combine)
                            }
                        }
                    }
                    if !report.models.isEmpty {
                        Section("Output by model") {
                            ForEach(report.models) { m in
                                LabeledContent(prettyModel(m.name), value: short(m.output))
                            }
                        }
                    }
                } else if let error {
                    ContentUnavailableView("Couldn't load usage", systemImage: "chart.bar.xaxis", description: Text(error))
                } else {
                    ProgressView().frame(maxWidth: .infinity)
                }
            }
            .navigationTitle("Usage")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Picker("Range", selection: $days) {
                        Text("7 days").tag(7)
                        Text("14 days").tag(14)
                        Text("30 days").tag(30)
                        Text("90 days").tag(90)
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 280)
                }
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
            .refreshable { await load() }
            .task(id: days) { await load() }
        }
    }

    private func stat(_ label: String, _ value: Int) -> some View {
        VStack {
            Text(short(value)).font(.title2.bold()).monospacedDigit().contentTransition(.numericText())
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
    }

    private func load() async {
        do {
            async let p = try? client.plan()
            let r = try await client.usage(days: days)
            plan = await p ?? PlanUsage(available: false, subscription: nil, fiveHour: nil, sevenDay: nil)
            withAnimation { report = r }
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }
}

/// Plan limits (5-hour and weekly windows) as two thin bars.
struct PlanMeter: View {
    let plan: PlanUsage

    var body: some View {
        HStack(spacing: 16) {
            if let w = plan.fiveHour { bar("5-hour", w) }
            if let w = plan.sevenDay { bar("Week", w) }
        }
        .padding(.vertical, 6)
        .accessibilityElement(children: .combine)
    }

    private func bar(_ name: String, _ w: PlanUsage.Window) -> some View {
        let color: Color = w.utilization >= 90 ? .red : w.utilization >= 70 ? .orange : .accentColor
        return VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(name).font(.caption.bold())
                Spacer()
                Text("\(Int(w.utilization.rounded()))%").font(.caption.monospacedDigit()).foregroundStyle(color)
            }
            ProgressView(value: min(w.utilization, 100), total: 100).tint(color)
            if let reset = w.resetDate {
                Text("Resets \(reset, format: .relative(presentation: .named))").font(.caption2).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity)
    }
}
