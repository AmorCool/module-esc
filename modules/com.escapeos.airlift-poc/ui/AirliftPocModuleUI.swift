//
//  AirliftPocModuleUI.swift
//  EscapeSpace · airlift-poc 模块自带
//
//  ## 视觉：**完全跟随主程序**（用户明确要求：「UI 界面要像主程序那样好看」）
//  复用 `EscapeOS/Views/DesignSystem.swift` 那套，不自造：
//  · `AppTheme.accent`（系统蓝）、`AppRowIcon`、`SizePill`
//  · `List` + `.listStyle(.insetGrouped)`、`Section { } header/footer`、`LabeledContent`
//  · 强调动作 `.buttonStyle(.borderedProminent)` + `.controlSize(.small/.large)`
//  · **忙碌时的材质 HUD 遮罩**（主程序 AppDetailView / DeviceControlView / ReclaimTabView 同款）
//    —— airlift 一次十几秒，这个遮罩正好用得上，也是主程序最显眼的那处质感
//  · 主操作固定在底部：`.safeAreaInset(edge: .bottom)` + `.regularMaterial`
//
//  ## 外壳约定
//  `ModuleHostShell` 已经给了顶栏标题与底部 tab 栏 ⇒ 这里**不套 NavigationStack、
//  不设 navigationTitle**（套了会变成双层栏）.
//
//  ## 三条硬规则（用户明确要求）
//  1. 不用黄色感叹号
//  2. 代码注释是给开发者看的，**界面上一个字都不显示**（`StepText.clean` 负责清）
//  3. 句号一律英文 `.`，给用户看的描述要精简
//
//  ## 这个模块为什么这么写
//  它只声明 requires，然后调宿主能力（`HostCapabilityService.call`）. 将来漏洞链被替换
//  （airlift -> 下一个），本文件一行都不用改.
//

import SwiftUI
import UIKit
import UniformTypeIdentifiers

// MARK: - 忙碌遮罩（主程序同款）

/// 主程序的「工作中」遮罩：压暗背景 + 材质圆角卡 + 转圈 + 标题.
///
/// 抄自 `AppDetailView` / `DeviceControlView` / `ReclaimTabView` —— 这是主程序里
/// 最显眼的一处质感，模块的长时间操作（airlift 一次 10~20 秒）正好该用它.
private struct BusyOverlay: ViewModifier {
    let isBusy: Bool
    let title: String

    func body(content: Content) -> some View {
        content.overlay {
            if isBusy {
                ZStack {
                    Color.black.opacity(0.28).ignoresSafeArea()
                    VStack(spacing: 14) {
                        ProgressView().scaleEffect(1.15)
                        Text(title).font(.headline)
                    }
                    .padding(.horizontal, 28)
                    .padding(.vertical, 22)
                    .background(.regularMaterial,
                                in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                }
            }
        }
    }
}

private extension View {
    func busyOverlay(_ isBusy: Bool, title: String) -> some View {
        modifier(BusyOverlay(isBusy: isBusy, title: title))
    }
}

/// 底部主操作条（主程序 `safeAreaInset(edge: .bottom)` 同款）.
private struct BottomActionBar<Content: View>: View {
    @ViewBuilder var content: () -> Content

    var body: some View {
        HStack(spacing: 10) { content() }
            .padding(.horizontal, AppTheme.pageInset)
            .padding(.vertical, 10)
            .background(.regularMaterial)
    }
}

// MARK: - 步骤文本清洗

/// 把能力返回的「步骤」原文清成**给人看的短句**.
///
/// 能力返回的步骤里带大量给开发者的解释：`⚠️`、`★`、markdown 的 `**` 与反引号、
/// 以及括号里那串「为什么 / 判据 / 边界」. 那些在**日志**里有用，在**界面**上是噪音.
/// 这里只留「做了什么、成没成」；原文照样能在展开后的「全部行」和日志里看到.
private enum StepText {
    static func clean(_ raw: String) -> String {
        var text = raw
        for junk in ["⚠️", "\u{FE0F}", "★", "**", "`", "❌", "✅"] {
            text = text.replacingOccurrences(of: junk, with: "")
        }
        for pair in [("（", "）"), ("(", ")")] {
            while let open = text.firstIndex(of: Character(pair.0)),
                  let close = text[text.index(after: open)...].firstIndex(of: Character(pair.1)) {
                text.removeSubrange(open...close)
            }
        }
        return text.split(separator: " ").joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// 步骤区块：默认只显示关键行，技术判据折起来. 用普通 `Section`（不自造卡片）.
private struct StepsSection: View {
    let steps: [String]
    var title: String = "执行步骤"
    @State private var expanded = false

    private static let noise: [String] = [
        "判据①", "判据②", "判据③", "books staging", "Grappa 实验",
        "Media 根前若干项", "规范化 base", "linkIdentifier", "targetIdentifier",
        "清单第", "帧前32字节", "响应 #", "已发 ", "攻击标识符",
        "AssetID =", "linkDestination =", "读目标（", "搬回的条目（",
        "【Grappa", "结论 下一步", "结论 本次",
    ]

    private var keySteps: [String] {
        steps.filter { line in !Self.noise.contains { line.contains($0) } }
    }

    var body: some View {
        if !steps.isEmpty {
            Section {
                ForEach(Array((expanded ? steps : keySteps).enumerated()), id: \.offset) { _, step in
                    HStack(alignment: .top, spacing: 8) {
                        Circle()
                            .fill(isBad(step) ? Color.orange
                                  : (isGood(step) ? Color.green : Color.secondary.opacity(0.4)))
                            .frame(width: 6, height: 6)
                            .padding(.top, 6)
                        Text(expanded ? step : StepText.clean(step))
                            .font(.caption)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                if keySteps.count < steps.count {
                    Button {
                        withAnimation(.easeInOut(duration: 0.18)) { expanded.toggle() }
                    } label: {
                        Label(expanded ? "收起技术细节" : "显示全部 \(steps.count) 行",
                              systemImage: expanded ? "chevron.up" : "chevron.down")
                            .font(.caption)
                    }
                }
            } header: {
                Text(title)
            }
        }
    }

    private func isBad(_ text: String) -> Bool {
        text.contains("失败") || text.contains("拒绝") || text.contains("未成立")
    }
    private func isGood(_ text: String) -> Bool {
        text.contains("已") || text.contains("成立")
    }
}

// MARK: - 调用记录器

/// 宿主能力调用的内存记录（日志 tab 的兜底；主来源是 CapabilityLog/run.log）.
@MainActor
private final class AirliftPocLog: ObservableObject {
    static let shared = AirliftPocLog()

    struct Entry: Identifiable {
        let id = UUID()
        let time: Date
        let capability: String
        let args: String
        let result: String
        let ok: Bool
    }

    @Published private(set) var entries: [Entry] = []

    private static let maxTextLength = 4000

    private init() {}

    func record(capability: String, args: String, result: String, ok: Bool) {
        entries.insert(Entry(time: Date(), capability: capability,
                             args: Self.clip(args), result: Self.clip(result), ok: ok), at: 0)
        if entries.count > 200 { entries.removeLast(entries.count - 200) }
    }

    func clear() { entries.removeAll() }

    private static func clip(_ text: String) -> String {
        guard text.count > maxTextLength else { return text }
        return String(text.prefix(maxTextLength)) + "\n…（已截断，原文 \(text.count) 字符）"
    }

    /// 统一的调用入口：调宿主能力并自动记一条内存日志.
    /// 同步阻塞：沙盒外操作走 airlift，一次 10~20 秒，调用方必须在后台线程调.
    nonisolated static func callRaw(_ capability: String, _ jsonArgs: String) -> (rc: Int32, json: String) {
        let result = HostCapabilityService.call(capability: capability, jsonArgs: jsonArgs)
        let ok = result.0 == 0
        Task { @MainActor in
            AirliftPocLog.shared.record(capability: capability, args: jsonArgs,
                                        result: result.1, ok: ok)
        }
        return (result.0, result.1)
    }
}

// MARK: - JSON 小工具

private enum AirliftJSON {
    static func dict(_ text: String) -> [String: Any]? {
        guard let data = text.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return obj
    }
    static func bool(_ dict: [String: Any]?, _ key: String) -> Bool? { dict?[key] as? Bool }
    static func string(_ dict: [String: Any]?, _ key: String) -> String? { dict?[key] as? String }
    static func int(_ dict: [String: Any]?, _ key: String) -> Int? { dict?[key] as? Int }
    static func strings(_ dict: [String: Any]?, _ key: String) -> [String] {
        dict?[key] as? [String] ?? []
    }
    static func json(_ obj: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys]),
              let text = String(data: data, encoding: .utf8) else { return "{}" }
        return text
    }
}

private func airliftCall(_ capability: String, _ args: String) async -> String {
    await withCheckedContinuation { continuation in
        DispatchQueue.global(qos: .userInitiated).async {
            let (_, json) = AirliftPocLog.callRaw(capability, args)
            continuation.resume(returning: json)
        }
    }
}

/// 字节数格式化（等宽数字，避免行宽跳动）.
private func byteText(_ size: Int) -> String {
    if size >= 1_048_576 { return String(format: "%.1f MB", Double(size) / 1_048_576) }
    if size >= 1024 { return String(format: "%.1f KB", Double(size) / 1024) }
    return "\(size) B"
}

// MARK: - 注册入口

/// 把 airlift-poc 的原生界面注册进宿主.
/// 调用点：`registerBuiltinModuleUIs()`（`EscapeSpaceApp.init()` 里触发）.
@MainActor
func registerAirliftPocModuleUI() {
    ModuleUIRegistry.shared.register("airlift-poc") { module in
        [
            ModuleUITab(id: "overview", title: "概览",
                        systemImage: "gauge.with.dots.needle.33percent") { m in
                AirliftOverviewTab(module: m)
            },
            ModuleUITab(id: "files", title: "文件", systemImage: "folder") { m in
                AirliftFilesTab(module: m)
            },
            ModuleUITab(id: "overwrite", title: "写入",
                        systemImage: "square.and.arrow.down") { m in
                AirliftOverwriteTab(module: m)
            },
            ModuleUITab(id: "theme", title: "主题", systemImage: "keyboard") { m in
                AirliftThemeTab(module: m)
            },
            // ★ v0.3.512：监督 / 日志 收进「更多」——
            //   iOS 的 TabView 超过 5 个 tab 会**自动**加一个系统「更多」溢出项，
            //   那个页面长得跟主程序完全不一样（用户反馈过）. 自己做一个 5 个 tab
            //   的布局就没有溢出项了，而且「更多」页能照主程序 MoreView 的样子做.
            ModuleUITab(id: "more", title: "更多", systemImage: "ellipsis") { m in
                AirliftMoreTab(module: m)
            },
        ]
    }
}

// MARK: - 概览

private struct AirliftOverviewTab: View {
    let module: EscapeModule

    @State private var hostVersion = "…"
    @State private var hostBuild = ""
    @State private var airliftRunnable: Bool?
    @State private var airliftEnabled: Bool?
    @State private var exploitNote = ""
    @State private var supportedCapabilities: [String] = []
    @State private var loading = false

    var body: some View {
        List {
            Section {
                HStack(spacing: 12) {
                    AppRowIcon(systemName: "bolt.horizontal.circle.fill",
                               tint: .purple, symbolSize: 20, frameSize: 40)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(module.name).font(.headline)
                        Text("v\(module.version)").font(.caption).foregroundColor(.secondary)
                    }
                    Spacer()
                    SizePill(text: module.isUsable ? "可用" : "不可用",
                             tint: module.isUsable ? .green : .orange)
                }
            }

            if !module.blockingIssues.isEmpty {
                Section("为什么不可用") {
                    ForEach(module.blockingIssues, id: \.self) { issue in
                        Label(issue, systemImage: "info.circle")
                            .font(.caption).foregroundColor(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }

            Section {
                LabeledContent("版本",
                               value: hostBuild.isEmpty ? hostVersion : "\(hostVersion) (\(hostBuild))")
                LabeledContent("airlift（本模块读写）") {
                    Text(airliftRunnable == nil ? "查询中…" : (airliftRunnable! ? "可用" : "不可用"))
                        .foregroundColor(airliftRunnable == nil ? .secondary
                                         : (airliftRunnable! ? .green : .orange))
                }
                LabeledContent("「漏洞利用」里的 airlift") {
                    Text(airliftEnabled == nil ? "查询中…" : (airliftEnabled! ? "已启用" : "未启用"))
                        .foregroundColor(airliftEnabled == nil ? .secondary
                                         : (airliftEnabled! ? .green : .orange))
                }
            } header: {
                Text("宿主")
            } footer: {
                if !exploitNote.isEmpty { Text(exploitNote) }
            }

            Section {
                if supportedCapabilities.isEmpty {
                    Text(loading ? "查询中…" : "未取到能力清单").foregroundColor(.secondary)
                } else {
                    ForEach(module.requires ?? [], id: \.self) { cap in
                        HStack(spacing: 8) {
                            Image(systemName: supportedCapabilities.contains(cap)
                                  ? "checkmark.circle.fill" : "xmark.circle.fill")
                                .foregroundColor(supportedCapabilities.contains(cap) ? .green : .red)
                            Text(cap).font(.system(.caption, design: .monospaced))
                            Spacer()
                            if !supportedCapabilities.contains(cap) {
                                Text("缺失").font(.caption).foregroundColor(.red)
                            }
                        }
                    }
                }
            } header: {
                Text("本模块声明的能力")
            } footer: {
                Text("本模块只声明能力、调宿主接口，不自己实现漏洞利用.")
            }

            Section {
                Button {
                    Task { await refresh() }
                } label: {
                    Label("刷新", systemImage: "arrow.clockwise")
                }
                .disabled(loading)
            }
        }
        .listStyle(.insetGrouped)
        .busyOverlay(loading, title: "读取中…")
        .task { await refresh() }
    }

    private func refresh() async {
        loading = true
        defer { loading = false }
        let versionDict = AirliftJSON.dict(await airliftCall("host.version", "{}"))
        hostVersion = AirliftJSON.string(versionDict, "version") ?? "未知"
        hostBuild = AirliftJSON.string(versionDict, "build") ?? ""

        supportedCapabilities = AirliftJSON.strings(
            AirliftJSON.dict(await airliftCall("host.capabilities", "{}")), "list")

        let exploitDict = AirliftJSON.dict(await airliftCall("exploit.status", "{}"))
        airliftRunnable = AirliftJSON.bool(exploitDict, "airliftRunnable")
        airliftEnabled = AirliftJSON.bool(exploitDict, "airliftEnabled")
        exploitNote = AirliftJSON.string(exploitDict, "note") ?? ""
    }
}

// MARK: - 文件（AFC 两个根）

private struct AirliftFilesTab: View {
    let module: EscapeModule

    @State private var root = "media"
    @State private var path = "/"
    @State private var entries: [AfcEntry] = []
    @State private var loading = false
    @State private var errorText: String?
    @State private var previewEntry: AfcEntry?
    @State private var previewText = ""
    @State private var previewLoading = false
    @State private var deleteEntry: AfcEntry?
    @State private var confirmingDelete = false
    @State private var newFolderName = ""
    @State private var statPath = ""
    @State private var statResult = ""
    /// ★ v0.3.512：批量选择模式（用户要求「不能批量选择/全选删除操作吗」）
    @State private var selecting = false
    @State private var picked = Set<String>()      // entry.path
    @State private var confirmingBatchDelete = false

    private struct AfcEntry: Identifiable {
        let name: String
        let path: String
        let isDir: Bool
        let size: Int
        var id: String { path }
    }

    private var rootDisplay: String {
        root == "crash" ? "/var/mobile/Library/Logs/CrashReporter" : "/var/mobile/Media"
    }

    var body: some View {
        List {
            Section {
                Picker("根", selection: $root) {
                    Text("/var/mobile/Media").tag("media")
                    Text("CrashReporter").tag("crash")
                }
                .pickerStyle(.segmented)
                .onChange(of: root) { _ in
                    path = "/"
                    Task { await load() }
                }

                HStack(spacing: 8) {
                    AppRowIcon(systemName: "externaldrive.fill", symbolSize: 14, frameSize: 28)
                    Text(path == "/" ? rootDisplay : path)
                        .font(.system(.caption, design: .monospaced))
                        .lineLimit(1)
                        .truncationMode(.head)
                }

                Button {
                    Task { await goUp() }
                } label: {
                    Label("上一级", systemImage: "arrow.up")
                }
                .disabled(path == "/" || loading)
            } header: {
                Text("位置")
            } footer: {
                Text("本页走 AFC（不是 airlift），在这两个根上是完整文件管理器.")
            }

            if let errorText {
                Section("错误") {
                    Text(errorText).font(.caption).foregroundColor(.red)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Section {
                if entries.isEmpty && !loading {
                    Text("目录为空").foregroundColor(.secondary)
                }
                ForEach(entries) { entry in
                    Button {
                        if selecting {
                            togglePick(entry)
                        } else if entry.isDir {
                            Task { await enter(entry) }
                        } else {
                            Task { await preview(entry) }
                        }
                    } label: {
                        HStack(spacing: 10) {
                            if selecting {
                                Image(systemName: picked.contains(entry.path)
                                      ? "checkmark.circle.fill" : "circle")
                                    .foregroundColor(picked.contains(entry.path)
                                                     ? AppTheme.accent : .secondary)
                            }
                            Image(systemName: entry.isDir ? "folder.fill" : "doc")
                                .foregroundColor(entry.isDir ? AppTheme.accent : .secondary)
                            Text(entry.name)
                                .font(.callout).foregroundColor(.primary).lineLimit(1)
                            Spacer()
                            if !selecting {
                                if entry.isDir {
                                    Image(systemName: "chevron.right")
                                        .font(.caption).foregroundColor(.secondary)
                                } else {
                                    SizePill(text: byteText(entry.size), tint: .secondary)
                                }
                            }
                        }
                    }
                    .swipeActions(edge: .trailing) {
                        Button(role: .destructive) {
                            deleteEntry = entry
                            confirmingDelete = true
                        } label: {
                            Label("删除", systemImage: "trash")
                        }
                    }
                }
            } header: {
                HStack {
                    Text("内容（\(entries.count) 项）")
                    Spacer()
                    if !entries.isEmpty {
                        Button(selecting ? "完成" : "选择") {
                            withAnimation(.easeInOut(duration: 0.18)) {
                                selecting.toggle()
                                if !selecting { picked.removeAll() }
                            }
                        }
                        .font(.footnote.weight(.semibold))
                        .textCase(nil)
                    }
                }
            }

            Section("新建目录") {
                HStack(spacing: 8) {
                    TextField("目录名", text: $newFolderName)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Button("创建") { Task { await makeFolder() } }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .tint(AppTheme.accent)
                        .disabled(newFolderName.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }

            Section {
                TextField("相对当前根的路径，可含 ..", text: $statPath)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .font(.system(.caption, design: .monospaced))
                Button("查一下") { Task { await doStat() } }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .tint(AppTheme.accent)
                if !statResult.isEmpty {
                    Text(statResult).font(.caption).foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } header: {
                Text("探测任意路径")
            } footer: {
                Text("Media 之外读 / 写 / 列都会被沙盒拒，但 stat 能过 —— 一次 AFC 往返、几十毫秒.")
            }
        }
        .listStyle(.insetGrouped)
        .busyOverlay(loading, title: "读取中…")
        .safeAreaInset(edge: .bottom) {
            if selecting {
                HStack(spacing: 10) {
                    Button {
                        if picked.count == entries.count {
                            picked.removeAll()
                        } else {
                            picked = Set(entries.map(\.path))
                        }
                    } label: {
                        Label(picked.count == entries.count ? "取消全选" : "全选",
                              systemImage: picked.count == entries.count
                                  ? "circle.dashed" : "checkmark.circle")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.large)

                    Button(role: .destructive) {
                        confirmingBatchDelete = true
                    } label: {
                        Label("删除所选（\(picked.count)）", systemImage: "trash")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .tint(.red)
                    .disabled(picked.isEmpty)
                }
                .padding(.horizontal, AppTheme.pageInset)
                .padding(.vertical, 10)
                .background(.regularMaterial)
            }
        }
        .confirmationDialog("删除选中的 \(picked.count) 项？",
                            isPresented: $confirmingBatchDelete, titleVisibility: .visible) {
            Button("删除", role: .destructive) { Task { await deletePicked() } }
            Button("取消", role: .cancel) {}
        } message: {
            Text("将从设备上彻底删除这些条目. 目录会连同里面的内容一起删.")
        }
        .sheet(item: $previewEntry) { entry in
            NavigationStack {
                ScrollView {
                    Text(previewLoading ? "读取中…" : previewText)
                        .font(.system(.caption, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(AppTheme.pageInset)
                        .textSelection(.enabled)
                }
                .navigationTitle(entry.name)
                .navigationBarTitleDisplayMode(.inline)
            }
        }
        .confirmationDialog("删除 \(deleteEntry?.name ?? "")？",
                            isPresented: $confirmingDelete, titleVisibility: .visible) {
            Button("删除", role: .destructive) { Task { await deleteSelected() } }
            Button("取消", role: .cancel) {}
        }
        .task { await load() }
    }

    private func load() async {
        loading = true
        defer { loading = false }
        let json = await airliftCall("afc.list", AirliftJSON.json(["root": root, "path": path]))
        let dict = AirliftJSON.dict(json)
        guard AirliftJSON.bool(dict, "ok") == true else {
            errorText = AirliftJSON.string(dict, "error") ?? json
            entries = []
            return
        }
        errorText = nil
        let raw = (dict?["entries"] as? [[String: Any]]) ?? []
        entries = raw.compactMap { item in
            guard let name = item["name"] as? String else { return nil }
            return AfcEntry(name: name,
                            path: (item["path"] as? String) ?? name,
                            isDir: (item["isDir"] as? Bool) ?? false,
                            size: (item["size"] as? Int) ?? 0)
        }.sorted { lhs, rhs in
            if lhs.isDir != rhs.isDir { return lhs.isDir }
            return lhs.name.lowercased() < rhs.name.lowercased()
        }
    }

    private func enter(_ entry: AfcEntry) async {
        path = entry.path.hasPrefix("/") ? entry.path : "/" + entry.path
        await load()
    }

    private func goUp() async {
        var comps = path.split(separator: "/").map(String.init)
        if !comps.isEmpty { comps.removeLast() }
        path = comps.isEmpty ? "/" : "/" + comps.joined(separator: "/")
        await load()
    }

    private func preview(_ entry: AfcEntry) async {
        previewEntry = entry
        previewLoading = true
        previewText = ""
        defer { previewLoading = false }
        let json = await airliftCall("afc.read",
                                     AirliftJSON.json(["root": root, "path": entry.path,
                                                       "encoding": "utf8"]))
        let dict = AirliftJSON.dict(json)
        previewText = AirliftJSON.bool(dict, "ok") == true
            ? (AirliftJSON.string(dict, "data") ?? "")
            : (AirliftJSON.string(dict, "error") ?? json)
    }

    private func togglePick(_ entry: AfcEntry) {
        if picked.contains(entry.path) {
            picked.remove(entry.path)
        } else {
            picked.insert(entry.path)
        }
    }

    /// 批量删除. **逐个删**（AFC 没有批量接口），每删一个报一行；
    /// 全失败 / 全成功都给一句总结，不留「点了没反应」的空白.
    private func deletePicked() async {
        let targets = entries.filter { picked.contains($0.path) }
        guard !targets.isEmpty else { return }
        loading = true
        defer { loading = false }
        var failed: [String] = []
        for entry in targets {
            let json = await airliftCall("afc.delete",
                                         AirliftJSON.json(["root": root, "path": entry.path]))
            if AirliftJSON.bool(AirliftJSON.dict(json), "ok") != true {
                failed.append(entry.name)
            }
        }
        if failed.isEmpty {
            errorText = nil
        } else {
            errorText = "有 \(failed.count) 项没删掉：\(failed.prefix(5).joined(separator: ", "))"
                + (failed.count > 5 ? " …" : "")
        }
        picked.removeAll()
        selecting = false
        await load()
    }

    private func deleteSelected() async {
        guard let entry = deleteEntry else { return }
        let json = await airliftCall("afc.delete",
                                     AirliftJSON.json(["root": root, "path": entry.path]))
        let dict = AirliftJSON.dict(json)
        if AirliftJSON.bool(dict, "ok") != true {
            errorText = AirliftJSON.string(dict, "error") ?? json
        }
        deleteEntry = nil
        await load()
    }

    private func makeFolder() async {
        let name = newFolderName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        let base = path == "/" ? "" : path
        let json = await airliftCall("afc.mkdir",
                                     AirliftJSON.json(["root": root, "path": "\(base)/\(name)"]))
        let dict = AirliftJSON.dict(json)
        if AirliftJSON.bool(dict, "ok") == true {
            newFolderName = ""
        } else {
            errorText = AirliftJSON.string(dict, "error") ?? json
        }
        await load()
    }

    private func doStat() async {
        let value = statPath.trimmingCharacters(in: .whitespaces)
        guard !value.isEmpty else { return }
        let json = await airliftCall("afc.stat", AirliftJSON.json(["root": root, "path": value]))
        let dict = AirliftJSON.dict(json)
        if AirliftJSON.bool(dict, "exists") == true {
            statResult = "存在 · \(AirliftJSON.string(dict, "ifmt") ?? "?")"
                + " · \(byteText(AirliftJSON.int(dict, "size") ?? 0))"
        } else {
            statResult = AirliftJSON.string(dict, "describe")
                ?? AirliftJSON.string(dict, "error") ?? "取不到"
        }
    }
}

// MARK: - 写入（AIR + airlift）

private struct AirliftOverwriteTab: View {
    let module: EscapeModule

    @State private var target = ""
    @State private var airFiles: [AirFile] = []
    @State private var selectedAirName: String?
    @State private var targetIsDirectory = false
    @State private var leafName = ""
    @State private var backupFirst = true
    @State private var working = false
    @State private var importing = false
    @State private var confirming = false
    @State private var confirmingDelete = false
    @State private var steps: [String] = []
    @State private var errorText: String?
    @State private var okText: String?

    private struct AirFile: Identifiable {
        let name: String
        let size: Int
        var id: String { name }
    }

    var body: some View {
        List {
            Section {
                TextField("/var/mobile/... 绝对路径", text: $target)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .font(.system(.caption, design: .monospaced))
                Toggle("目标是目录（写到它下面）", isOn: $targetIsDirectory)
                if targetIsDirectory {
                    TextField("文件名（留空 = 用源文件名）", text: $leafName)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }
            } header: {
                Text("目标")
            } footer: {
                Text(targetIsDirectory ? "落点 = 目标目录 / 文件名" : "落点 = 上面填的这个路径本身")
            }

            Section {
                if airFiles.isEmpty {
                    Text("AIR 里还没有文件. 点下面导入，或先把目标读回来.")
                        .font(.caption).foregroundColor(.secondary)
                }
                ForEach(airFiles) { file in
                    Button {
                        selectedAirName = file.name
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: selectedAirName == file.name
                                  ? "largecircle.fill.circle" : "circle")
                                .foregroundColor(selectedAirName == file.name
                                                 ? AppTheme.accent : .secondary)
                            Text(file.name)
                                .font(.system(.caption, design: .monospaced))
                                .foregroundColor(.primary).lineLimit(1)
                            Spacer()
                            SizePill(text: byteText(file.size), tint: .secondary)
                        }
                    }
                    .swipeActions(edge: .trailing) {
                        Button(role: .destructive) {
                            Task { await deleteAirFile(file.name) }
                        } label: {
                            Label("移除", systemImage: "trash")
                        }
                    }
                }
                Button {
                    importing = true
                } label: {
                    Label("从本机选择文件导入", systemImage: "square.and.arrow.down")
                }
                Button {
                    Task { await pullToAir() }
                } label: {
                    Label("把目标读回来（不改动目标）", systemImage: "arrow.down.doc")
                }
                .disabled(working || target.trimmingCharacters(in: .whitespaces).isEmpty)
            } header: {
                Text("源文件（AIR）")
            } footer: {
                Text("源文件先落进 AIR（AFC 根下，读写是瞬时的），再用 airlift 覆盖目标.")
            }

            Section("选项") {
                Toggle("覆盖前先把目标备份到 AIR（.bak）", isOn: $backupFirst)
                Button(role: .destructive) {
                    confirmingDelete = true
                } label: {
                    Label("删除目标文件", systemImage: "trash")
                }
                .disabled(working || target.trimmingCharacters(in: .whitespaces).isEmpty)
            }

            if let okText {
                Section { Text(okText).font(.caption).foregroundColor(.green) }
            }
            if let errorText {
                Section("错误") {
                    Text(errorText).font(.caption).foregroundColor(.red)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            StepsSection(steps: steps)
        }
        .listStyle(.insetGrouped)
        .busyOverlay(working, title: "执行中…")
        .safeAreaInset(edge: .bottom) {
            BottomActionBar {
                Button {
                    confirming = true
                } label: {
                    Label("覆盖目标", systemImage: "square.and.arrow.up.on.square")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .tint(AppTheme.accent)
                .disabled(working || selectedAirName == nil
                          || target.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .task { await refreshAirList() }
        .documentPicker(isPresented: $importing, allowedTypes: [.item],
                        allowsMultipleSelection: false) { urls in
            Task { await importPicked(urls) }
        }
        .confirmationDialog("确认覆盖？", isPresented: $confirming, titleVisibility: .visible) {
            Button("覆盖", role: .destructive) { Task { await overwrite() } }
            Button("取消", role: .cancel) {}
        } message: {
            Text("将用 AIR/\(selectedAirName ?? "?") 覆盖 \(target)."
                 + (backupFirst ? "覆盖前会先备份原内容." : "已关闭备份."))
        }
        .confirmationDialog("确认删除？", isPresented: $confirmingDelete, titleVisibility: .visible) {
            Button("删除", role: .destructive) { Task { await deleteTarget() } }
            Button("取消", role: .cancel) {}
        } message: {
            Text("将彻底删除 \(target). 备份会留在 App 沙盒的 LoginLogs/ 下.")
        }
    }

    private func refreshAirList() async {
        let dict = AirliftJSON.dict(await airliftCall("airlift.air", AirliftJSON.json(["op": "list"])))
        let raw = (dict?["entries"] as? [[String: Any]]) ?? []
        airFiles = raw.compactMap { item in
            guard let name = item["name"] as? String,
                  (item["isDir"] as? Bool) != true else { return nil }
            return AirFile(name: name, size: (item["size"] as? Int) ?? 0)
        }
        if let selected = selectedAirName, !airFiles.contains(where: { $0.name == selected }) {
            selectedAirName = nil
        }
    }

    private func deleteAirFile(_ name: String) async {
        let dict = AirliftJSON.dict(await airliftCall("airlift.air",
                                                      AirliftJSON.json(["op": "delete", "name": name])))
        if AirliftJSON.bool(dict, "ok") != true {
            errorText = AirliftJSON.string(dict, "error") ?? ""
        }
        if selectedAirName == name { selectedAirName = nil }
        await refreshAirList()
    }

    /// 导入用户选的文件到 AIR.
    /// 入参是**已经在 App 沙盒里**的 URL —— SharedDocumentPicker 用 asCopy: true，
    /// 系统拷完才回调，所以不要再调 startAccessingSecurityScopedResource.
    private func importPicked(_ urls: [URL]) async {
        guard let url = urls.first else { return }
        guard let data = try? Data(contentsOf: url) else {
            errorText = "读不到所选文件：\(url.lastPathComponent)"
            return
        }
        let args = AirliftJSON.json(["op": "write", "name": url.lastPathComponent,
                                     "data": data.base64EncodedString(), "encoding": "base64"])
        let dict = AirliftJSON.dict(await airliftCall("airlift.air", args))
        if AirliftJSON.bool(dict, "ok") == true {
            okText = "已导入 \(url.lastPathComponent)"
            errorText = nil
            await refreshAirList()
        } else {
            errorText = AirliftJSON.string(dict, "error") ?? ""
        }
    }

    private func pullToAir() async {
        working = true; steps = []; errorText = nil; okText = nil
        defer { working = false }
        let path = target.trimmingCharacters(in: .whitespaces)
        let json = await airliftCall("airlift.pull", AirliftJSON.json(["path": path]))
        let dict = AirliftJSON.dict(json)
        steps = AirliftJSON.strings(dict, "steps")
        if AirliftJSON.bool(dict, "ok") == true {
            okText = "已读到 AIR：\(AirliftJSON.string(dict, "airName") ?? "?")"
            await refreshAirList()
            if let name = AirliftJSON.string(dict, "airName"), !name.isEmpty {
                selectedAirName = name
            }
        } else {
            errorText = AirliftJSON.string(dict, "error") ?? json
        }
    }

    private func deleteTarget() async {
        working = true; steps = []; errorText = nil; okText = nil
        defer { working = false }
        let path = target.trimmingCharacters(in: .whitespaces)
        let json = await airliftCall("airlift.delete", AirliftJSON.json(["path": path]))
        let dict = AirliftJSON.dict(json)
        steps = AirliftJSON.strings(dict, "steps")
        if AirliftJSON.bool(dict, "ok") == true {
            okText = "已删除 \(path)"
        } else {
            errorText = AirliftJSON.string(dict, "error") ?? json
        }
    }

    private func overwrite() async {
        working = true; steps = []; errorText = nil; okText = nil
        defer { working = false }
        var payload: [String: Any] = [
            "target": target.trimmingCharacters(in: .whitespaces),
            "airName": selectedAirName ?? "",
            "backup": backupFirst,
        ]
        if targetIsDirectory {
            payload["targetIsDirectory"] = true
            let leaf = leafName.trimmingCharacters(in: .whitespaces)
            if !leaf.isEmpty { payload["leafName"] = leaf }
        }
        let json = await airliftCall("airlift.overwrite", AirliftJSON.json(payload))
        let dict = AirliftJSON.dict(json)
        steps = AirliftJSON.strings(dict, "steps")
        if AirliftJSON.bool(dict, "ok") == true {
            okText = "已写入 \(AirliftJSON.string(dict, "target") ?? "")"
        } else {
            errorText = AirliftJSON.string(dict, "error") ?? json
        }
    }
}

// MARK: - 主题（密码键盘）

/// 锁屏密码键盘主题：选 `.passthm` -> 预览 12 键 -> 一次批量写进 TelephonyUI 缓存.
/// 移植自 Mak5er/AirCard 的「Passcode Themes」. 机制与前提见 `PasscodeTheme` 的头注释.
private struct AirliftThemeTab: View {
    let module: EscapeModule

    @State private var theme: PasscodeTheme.Theme?
    @State private var importing = false
    @State private var importingPoster = false
    @State private var working = false
    @State private var steps: [String] = []
    @State private var errorText: String?
    @State private var okText: String?
    @State private var targetVersion = 10

    private var targetDir: String { "/var/mobile/Library/Caches/TelephonyUI-\(targetVersion)" }

    var body: some View {
        List {
            Section {
                HStack(spacing: 12) {
                    AppRowIcon(systemName: "keyboard.fill", tint: .pink,
                               symbolSize: 20, frameSize: 40)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("密码键盘主题").font(.headline)
                        Text(theme == nil ? "未选择主题包" : "\(theme!.keys.count) 个按键")
                            .font(.caption).foregroundColor(.secondary)
                    }
                    Spacer()
                    if let theme {
                        SizePill(text: "\(theme.keys.count) 键", tint: .pink)
                    }
                }
            } footer: {
                Text("需要 TelephonyUI-8 / 9 / 10 里至少有一个已经存在 —— "
                     + "airlift 在 Media 之外建不了目录.")
            }

            Section {
                Button {
                    importing = true
                } label: {
                    Label("选择 .passthm 文件", systemImage: "square.and.arrow.down")
                }
                Button {
                    importingPoster = true
                } label: {
                    Label("从一张壁纸切出 12 个按键", systemImage: "photo")
                }
                if theme != nil {
                    Picker("目标版本", selection: $targetVersion) {
                        Text("TelephonyUI-10").tag(10)
                        Text("TelephonyUI-9").tag(9)
                        Text("TelephonyUI-8").tag(8)
                    }
                    .pickerStyle(.segmented)
                }
            } header: {
                Text("主题包")
            } footer: {
                if theme != nil {
                    Text(targetDir).font(.system(.caption2, design: .monospaced))
                }
            }

            if let theme {
                Section("预览") {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 3),
                              spacing: 8) {
                        ForEach(PasscodeTheme.keypadOrder, id: \.self) { digit in
                            keyTile(digit: digit, theme: theme)
                        }
                    }
                    .padding(.vertical, 4)
                }

                Section("动作") {
                    Button {
                        Task { await apply(theme) }
                    } label: {
                        Label("应用到设备", systemImage: "arrow.up.doc")
                    }
                    .disabled(working)
                    Button {
                        exportTheme(theme)
                    } label: {
                        Label("导出为 .passthm", systemImage: "square.and.arrow.up")
                    }
                }
            }

            if let okText {
                Section { Text(okText).font(.caption).foregroundColor(.green) }
            }
            if let errorText {
                Section("错误") {
                    Text(errorText).font(.caption).foregroundColor(.red)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            StepsSection(steps: steps)
        }
        .listStyle(.insetGrouped)
        .busyOverlay(working, title: "写入中…")
        .documentPicker(isPresented: $importing, allowedTypes: [.item]) { urls in
            Task { await loadTheme(urls.first) }
        }
        .documentPicker(isPresented: $importingPoster, allowedTypes: [.image]) { urls in
            Task { await slicePoster(urls.first) }
        }
    }

    /// 一个键位的小预览（优先取「无副文本」那张，找不到就取该键位的第一张）.
    @ViewBuilder
    private func keyTile(digit: String, theme: PasscodeTheme.Theme) -> some View {
        let candidates = theme.keys.filter { $0.digit == digit }
        let key = candidates.first(where: { $0.subtext.isEmpty }) ?? candidates.first
        VStack(spacing: 4) {
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color(uiColor: .tertiarySystemFill))
                    .frame(height: 54)
                if let key, let image = UIImage(data: key.data) {
                    Image(uiImage: image).resizable().scaledToFit().frame(height: 54)
                } else {
                    Text(digit).font(.title3).foregroundColor(.secondary)
                }
            }
            Text(digit).font(.caption2).foregroundColor(.secondary)
        }
    }

    private func loadTheme(_ url: URL?) async {
        guard let url else { return }
        errorText = nil; okText = nil
        do {
            let loaded = try PasscodeTheme.load(url: url)
            theme = loaded
            targetVersion = loaded.guessedVersion
            okText = "已载入 \(loaded.keys.count) 个按键"
        } catch {
            errorText = error.localizedDescription
        }
    }

    private func slicePoster(_ url: URL?) async {
        guard let url, let image = UIImage(contentsOfFile: url.path) else {
            errorText = "读不到所选图片"
            return
        }
        let keys = PasscodeTheme.slice(poster: image)
        guard !keys.isEmpty else {
            errorText = "切片失败（图片可能太小）"
            return
        }
        theme = PasscodeTheme.Theme(name: url.deletingPathExtension().lastPathComponent,
                                    keys: keys, guessedVersion: targetVersion)
        errorText = nil
        okText = "已从壁纸切出 \(keys.count) 个按键"
    }

    private func exportTheme(_ theme: PasscodeTheme.Theme) {
        do {
            let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("Themes", isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let url = dir.appendingPathComponent("\(theme.name).passthm")
            try PasscodeTheme.export(theme, to: url)
            okText = "已导出到沙盒 Documents/Themes/\(theme.name).passthm"
            errorText = nil
        } catch {
            errorText = "导出失败：\(error.localizedDescription)"
        }
    }

    private func apply(_ theme: PasscodeTheme.Theme) async {
        working = true; steps = []; errorText = nil; okText = nil
        defer { working = false }
        let files = theme.keys.map { key -> [String: Any] in
            ["name": key.fileName, "data": key.data.base64EncodedString()]
        }
        let json = await airliftCall("airlift.writeMany",
                                     AirliftJSON.json(["dir": targetDir, "files": files,
                                                       "encoding": "base64"]))
        let dict = AirliftJSON.dict(json)
        steps = AirliftJSON.strings(dict, "steps")
        if AirliftJSON.bool(dict, "ok") == true {
            okText = "已写入 \(theme.keys.count) 个按键到 \(targetDir)"
        } else {
            errorText = AirliftJSON.string(dict, "error") ?? json
        }
    }
}

// MARK: - 更多（照主程序 MoreView 的样子）

/// 「更多」页：把次级入口收在这里.
///
/// 刻意照 `EscapeOS/Views/MoreView.swift` 做：
/// · `List` + `.listStyle(.insetGrouped)` + `.scrollContentBackground(.hidden)`
/// · Section header 用 `.footnote.weight(.semibold)` + `.textCase(nil)`
/// · 行用主程序的 **`MoreCard`**（`AppRowIcon` 蓝色 + 标题 + 副标题）—— 直接复用，不重画
private struct AirliftMoreTab: View {
    let module: EscapeModule

    @State private var cleaning = false
    @State private var cleanupNote = "删掉 Media 根下 airlift-* 的临时目录"

    var body: some View {
        List {
            Section {
                NavigationLink {
                    AirliftSupervisedTab(module: module)
                } label: {
                    MoreCard(icon: "lock.shield.fill", title: "监督模式",
                             subtitle: "改 CloudConfigurationDetails.plist 的 IsSupervised")
                }
                NavigationLink {
                    AirliftLogTab()
                } label: {
                    MoreCard(icon: "text.alignleft", title: "调用日志",
                             subtitle: "宿主能力调用的原始 JSON 往来")
                }
            } header: {
                Text("功能")
                    .font(.footnote.weight(.semibold))
                    .textCase(nil)
                    .foregroundColor(.secondary)
            }

            Section {
                Button(role: .destructive) {
                    Task { await cleanupTemp() }
                } label: {
                    HStack(spacing: 12) {
                        AppRowIcon(systemName: "trash", tint: .red, symbolSize: 20, frameSize: 36)
                        VStack(alignment: .leading, spacing: 3) {
                            Text("清理临时文件")
                                .font(.subheadline.weight(.semibold))
                                .foregroundColor(.primary)
                            Text(cleanupNote)
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer()
                        if cleaning { ProgressView().controlSize(.small) }
                    }
                    .padding(.vertical, 6)
                }
                .disabled(cleaning)
            } header: {
                Text("维护")
                    .font(.footnote.weight(.semibold))
                    .textCase(nil)
                    .foregroundColor(.secondary)
            } footer: {
                Text("airlift 的临时目录现在统一放在 Media/Airlift/ 下，而且每次调用结束宿主会自动清一遍. "
                     + "这里只是兜底. AIR/（你自己的源文件）与 Airlock/ 不会被删.")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }

            Section {
                NavigationLink {
                    AirliftAboutTab(module: module)
                } label: {
                    MoreCard(icon: "info.circle.fill", title: "关于本模块",
                             subtitle: "版本 / 依赖的宿主能力 / 实现说明")
                }
            } header: {
                Text("关于")
                    .font(.footnote.weight(.semibold))
                    .textCase(nil)
                    .foregroundColor(.secondary)
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
    }

    /// 清理 Media 根下的 `airlift-*` 临时项.
    ///
    /// ## 为什么不新开一个宿主能力
    /// 列 + 删本来就有（`afc.list` / `afc.delete`，根是 media），
    /// 在这里组合一下就行 —— 少一个能力就少一处要维护的接口.
    ///
    /// ## 刻意不删的两类
    /// · `AIR/` —— 那是**用户自己的源文件**（导入进来准备覆盖用的）
    /// · `Airlock/` —— airlift 的固定工作根，删了也会被下次运行重建，但没必要动
    private func cleanupTemp() async {
        cleaning = true
        defer { cleaning = false }

        let listJSON = await airliftCall("afc.list", AirliftJSON.json(["root": "media", "path": "/"]))
        let listDict = AirliftJSON.dict(listJSON)
        guard AirliftJSON.bool(listDict, "ok") == true else {
            cleanupNote = "列目录失败：\(AirliftJSON.string(listDict, "error") ?? "见日志")"
            return
        }
        let raw = (listDict?["entries"] as? [[String: Any]]) ?? []
        let names = raw.compactMap { $0["name"] as? String }

        // 两处都要清：
        //  · 统一工作目录 `Airlift/` **里面**的（v0.3.512 起的正常位置）
        //  · 根上的 `airlift-*`（v0.3.512 之前遗留的，一并收掉）
        var paths: [String] = []
        if names.contains("Airlift") {
            let inner = await airliftCall("afc.list",
                                          AirliftJSON.json(["root": "media", "path": "/Airlift"]))
            let innerRaw = (AirliftJSON.dict(inner)?["entries"] as? [[String: Any]]) ?? []
            paths += innerRaw.compactMap { $0["name"] as? String }
                .filter { $0.hasPrefix("airlift-") }
                .map { "/Airlift/\($0)" }
        }
        paths += names.filter { $0.hasPrefix("airlift-") }.map { "/\($0)" }

        guard !paths.isEmpty else {
            cleanupNote = "没有需要清理的临时目录"
            return
        }

        var failed = 0
        for path in paths {
            let json = await airliftCall("afc.delete",
                                         AirliftJSON.json(["root": "media", "path": path]))
            if AirliftJSON.bool(AirliftJSON.dict(json), "ok") != true { failed += 1 }
        }
        cleanupNote = failed == 0
            ? "已清理 \(paths.count) 个临时目录"
            : "清理了 \(paths.count - failed) 个，\(failed) 个没删掉（可能被系统占用）"
    }
}

/// 关于页：说清这个模块「是什么、靠什么、边界在哪」.
private struct AirliftAboutTab: View {
    let module: EscapeModule

    @State private var hostVersion = "…"
    @State private var supportedCapabilities: [String] = []

    var body: some View {
        List {
            Section {
                HStack(spacing: 12) {
                    AppRowIcon(systemName: "bolt.horizontal.circle.fill",
                               tint: .purple, symbolSize: 20, frameSize: 40)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(module.name).font(.headline)
                        Text("v\(module.version)").font(.caption).foregroundColor(.secondary)
                    }
                    Spacer()
                    SizePill(text: module.isUsable ? "可用" : "不可用",
                             tint: module.isUsable ? .green : .orange)
                }
            }

            Section {
                Text("本模块**只声明能力、调宿主接口**，不自己实现漏洞利用.")
                    .font(.caption).foregroundColor(.secondary)
                Text("沙盒外的读写走宿主提供的 airlift（AirTraffic 同步漏洞）；"
                     + "Media 与 CrashReporter 两个根走 AFC. "
                     + "漏洞链以后被替换时，本模块一行都不用改.")
                    .font(.caption).foregroundColor(.secondary)
            } header: {
                Text("实现说明")
                    .font(.footnote.weight(.semibold)).textCase(nil).foregroundColor(.secondary)
            }

            Section {
                Text("· 沙盒外只能读写**单个已知文件**，**不能列目录**" + "
"
                     + "· 在 Media 之外**建不了目录**（沙盒允许建文件、不允许建目录）" + "
"
                     + "· 把 Media 之外的**目录**搬进来是单向的（搬不回去）—— 已禁用该能力")
                    .font(.caption).foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } header: {
                Text("已知边界")
                    .font(.footnote.weight(.semibold)).textCase(nil).foregroundColor(.secondary)
            }

            Section {
                LabeledContent("宿主版本", value: hostVersion)
                LabeledContent("模块版本", value: module.version)
                LabeledContent("声明的能力", value: "\(module.requires?.count ?? 0) 项")
            } header: {
                Text("版本")
                    .font(.footnote.weight(.semibold)).textCase(nil).foregroundColor(.secondary)
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .task {
            let dict = AirliftJSON.dict(await airliftCall("host.version", "{}"))
            let v = AirliftJSON.string(dict, "version") ?? "未知"
            let b = AirliftJSON.string(dict, "build") ?? ""
            hostVersion = b.isEmpty ? v : "\(v) (\(b))"
        }
    }
}

// MARK: - 监督模式

private struct AirliftSupervisedTab: View {
    let module: EscapeModule

    @State private var isSupervised: Bool?
    @State private var organizationName = ""
    @State private var running = false
    @State private var loading = false
    @State private var confirming = false
    @State private var steps: [String] = []
    @State private var errorText: String?

    var body: some View {
        List {
            Section {
                HStack(spacing: 12) {
                    AppRowIcon(systemName: isSupervised == true ? "lock.shield.fill" : "lock.open",
                               tint: isSupervised == true ? .green : .secondary,
                               symbolSize: 20, frameSize: 40)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("监督模式").font(.headline)
                        Text(isSupervised == nil ? "读取中…" : (isSupervised! ? "已开启" : "未开启"))
                            .font(.caption).foregroundColor(.secondary)
                    }
                    Spacer()
                    SizePill(text: isSupervised == nil ? "…" : (isSupervised! ? "开" : "关"),
                             tint: isSupervised == true ? .green : .secondary)
                }
            }

            Section {
                Text("这个目标做不到. CloudConfigurationDetails.plist 在 SystemGroup 容器里，"
                     + "沙盒只允许读 / 移出、拒绝创建 / 写入 —— 读得到 412 字节，"
                     + "但覆盖后读回一点没变，连在同一个目录里新建一个文件都建不出来.")
                    .font(.caption).foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } header: {
                Text("结论先说")
            } footer: {
                Text("对照：/var/mobile/Library/** 下的文件可以正常覆盖.")
            }

            Section("当前状态") {
                LabeledContent("IsSupervised") {
                    Text(isSupervised == nil ? "读取中…" : (isSupervised! ? "true" : "false"))
                        .foregroundColor(isSupervised == true ? .green : .secondary)
                }
                TextField("组织名称（可选）", text: $organizationName)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            }

            if let errorText {
                Section("错误") {
                    Text(errorText).font(.caption).foregroundColor(.red)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            StepsSection(steps: steps)
        }
        .listStyle(.insetGrouped)
        .busyOverlay(running || loading, title: running ? "执行中…" : "读取中…")
        .safeAreaInset(edge: .bottom) {
            BottomActionBar {
                Button {
                    confirming = true
                } label: {
                    Label(isSupervised == true ? "关闭监督模式" : "启用监督模式",
                          systemImage: isSupervised == true ? "lock.open.fill" : "lock.shield.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .tint(AppTheme.accent)
                .disabled(isSupervised == nil || running)
            }
        }
        .task { await readState() }
        .confirmationDialog(isSupervised == true ? "确认关闭监督模式？" : "确认启用监督模式？",
                            isPresented: $confirming, titleVisibility: .visible) {
            Button(isSupervised == true ? "关闭" : "启用", role: .destructive) {
                Task { await apply(!(isSupervised ?? false)) }
            }
            Button("取消", role: .cancel) {}
        }
    }

    private func readState() async {
        loading = true
        defer { loading = false }
        let dict = AirliftJSON.dict(await airliftCall("sys.supervised.get", "{}"))
        if let value = AirliftJSON.bool(dict, "isSupervised") {
            isSupervised = value
            if let org = AirliftJSON.string(dict, "organizationName"), !org.isEmpty {
                organizationName = org
            }
            errorText = nil
        } else {
            isSupervised = nil
            errorText = AirliftJSON.string(dict, "error") ?? ""
        }
    }

    private func apply(_ enabled: Bool) async {
        running = true; steps = []; errorText = nil
        defer { running = false }
        var payload: [String: Any] = ["enabled": enabled]
        let trimmed = organizationName.trimmingCharacters(in: .whitespacesAndNewlines)
        if enabled, !trimmed.isEmpty { payload["organizationName"] = trimmed }
        let dict = AirliftJSON.dict(await airliftCall("sys.supervised.set",
                                                      AirliftJSON.json(payload)))
        steps = AirliftJSON.strings(dict, "steps")
        if AirliftJSON.bool(dict, "ok") != true {
            errorText = AirliftJSON.string(dict, "error") ?? ""
        }
        if AirliftJSON.bool(dict, "verified") == true,
           let value = AirliftJSON.bool(dict, "isSupervised") {
            isSupervised = value
            errorText = nil
        } else {
            await readState()
        }
    }
}

// MARK: - 日志

private struct AirliftLogTab: View {
    @ObservedObject private var memory = AirliftPocLog.shared

    @State private var entries: [FileEntry] = []
    @State private var loading = false

    struct FileEntry: Identifiable {
        let id = UUID()
        let head: String
        let ok: Bool
        let args: String
        let ret: String
    }

    var body: some View {
        List {
            Section {
                Button {
                    Task { await reload() }
                } label: {
                    Label("刷新", systemImage: "arrow.clockwise")
                }
                .disabled(loading)
                Button(role: .destructive) {
                    clearAll()
                } label: {
                    Label("清空日志", systemImage: "trash")
                }
            } footer: {
                Text("日志落在 App 沙盒的 CapabilityLog/run.log，重启 App 不会丢，"
                     + "SSH 的 cap 调用也在里面.")
            }

            if entries.isEmpty {
                Section {
                    Text("还没有调用记录. 在任意 tab 里操作一次就会出现.")
                        .foregroundColor(.secondary)
                }
            }

            Section {
                ForEach(entries) { entry in
                    DisclosureGroup {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("入参").font(.caption).foregroundColor(.secondary)
                            Text(entry.args)
                                .font(.system(.caption2, design: .monospaced))
                                .textSelection(.enabled)
                            Text("返回").font(.caption).foregroundColor(.secondary)
                            Text(entry.ret)
                                .font(.system(.caption2, design: .monospaced))
                                .textSelection(.enabled)
                        }
                        .padding(.vertical, 2)
                    } label: {
                        HStack(spacing: 8) {
                            Circle()
                                .fill(entry.ok ? Color.green : Color.red)
                                .frame(width: 7, height: 7)
                            Text(entry.head)
                                .font(.system(.caption, design: .monospaced))
                                .lineLimit(2)
                        }
                    }
                }
            } header: {
                Text("最近 \(entries.count) 条")
            }
        }
        .listStyle(.insetGrouped)
        .busyOverlay(loading, title: "读取中…")
        .task { await reload() }
    }

    /// 读持久化日志的末尾. 内存里那份随 App 重启清空，而且 SSH 的 cap 调用不经过它，
    /// 所以主来源必须是文件.
    private func reload() async {
        loading = true
        defer { loading = false }
        let url = HostCapabilityService.callLogURL
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            entries = []
            return
        }
        var out: [FileEntry] = []
        var head: String?
        var args = ""
        var ret = ""
        var ok = true
        func flush() {
            guard let h = head else { return }
            out.append(FileEntry(head: h, ok: ok, args: args, ret: ret))
            head = nil; args = ""; ret = ""; ok = true
        }
        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(rawLine)
            if line.hasPrefix("[") {
                flush()
                head = line
                ok = line.contains("] OK")
            } else if line.hasPrefix("  args:") {
                args = String(line.dropFirst("  args:".count)).trimmingCharacters(in: .whitespaces)
            } else if line.hasPrefix("  ret :") {
                ret = String(line.dropFirst("  ret :".count)).trimmingCharacters(in: .whitespaces)
            } else if head != nil {
                ret += "\n" + line
            }
        }
        flush()
        entries = Array(out.suffix(60).reversed())
    }

    private func clearAll() {
        try? FileManager.default.removeItem(at: HostCapabilityService.callLogURL)
        memory.clear()
        entries = []
    }
}
