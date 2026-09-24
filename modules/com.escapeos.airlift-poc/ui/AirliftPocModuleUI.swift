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
/// 能力返回的步骤里带大量给开发者的解释：`⚠️`、`▸`、markdown 的 `**` 与反引号、
/// 以及括号里那串「为什么 / 判据 / 边界」. 那些在**日志**里有用，在**界面**上是噪音.
/// 这里只留「做了什么、成没成」；原文照样能在展开后的「全部行」和日志里看到.
private enum StepText {
    static func clean(_ raw: String) -> String {
        var text = raw
        for junk in ["⚠️", "\u{FE0F}", "▸", "**", "`", "❌", "✅"] {
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

/// 步骤区块：默认**只留 2~4 行真正有信息的**，其余折起来. 用普通 `Section`（不自造卡片）.
///
/// ## 为什么从「黑名单」改成「白名单」（用户反馈「注释太多了 精简掉 废话那么多」）
/// 旧实现是「排除一批噪音关键词」—— 那是**漏的**：`清单里有没有我们那条`、
/// `0) 变体 4：`、`读到 AssetManifest`、`关键结论：组(d)` 这些都不在黑名单里，
/// 于是一次写入能刷出十几行给开发者看的判据原文.
/// ⇒ 反过来做：**只保留少量「做了什么 / 成没成」的句子**，其余全部收进「显示全部」.
/// 判据原文一行都没丢，只是**默认不糊在你脸上**（展开或看日志都在）.
private struct StepsSection: View {
    let steps: [String]
    var title: String = "执行步骤"
    @State private var expanded = false

    /// 白名单：命中这些片段的行才默认显示.
    private static let keep: [String] = [
        "stage 已发出",              // 第①步：归档发出去了
        "清单里有没有我们那条",       // 第②步：设备认了我们那条 asset
        "已被搬走",                  // 第③步：设备真的执行了 move
        "机制成立",                  // 结论：整条链通了
        "已发出覆盖写入",            // 结论：写入已发出
        "未成立", "失败", "拒绝",     // 失败原因（必须让用户看见）
        "已删除", "读回",
    ]

    private var keySteps: [String] {
        steps.filter { line in Self.keep.contains { line.contains($0) } }
    }

    var body: some View {
        if !steps.isEmpty {
            Section {
                ForEach(Array((expanded ? steps : keySteps).enumerated()), id: \.offset) { _, step in
                    HStack(alignment: .top, spacing: 8) {
                        Circle()
                            .fill(isBad(step) ? Color.red
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
                        Label(expanded ? "收起" : "技术细节 \(steps.count) 行",
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

/// 判断一次能力调用是否成功.
///
/// ## 为什么不只看 `ok`
/// 宿主有一条**成功路径漏了 `ok` 字段**（`airOverwrite`，0.3.524 及以前）——
/// 于是模块把一次**成功的写入显示成失败**，还把整段原始 JSON 糊在错误框里.
/// 用户看到的「注释太多了 废话那么多」有一半就是那段 JSON.
/// 宿主侧已修（成功/失败都显式给 `ok`），这里再兜一层：**`ok` 缺失时看 `error`**，
/// 没有 `error` 就当成功 —— 免得将来再有一条路径漏字段，又把成功报成失败.
private func airliftOK(_ dict: [String: Any]?) -> Bool {
    guard let dict else { return false }
    if let ok = dict["ok"] as? Bool { return ok }
    return dict["error"] == nil
}

/// 字节数格式化（等宽数字，避免行宽跳动）.
private func byteText(_ size: Int) -> String {
    if size >= 1_048_576 { return String(format: "%.1f MB", Double(size) / 1_048_576) }
    if size >= 1024 { return String(format: "%.1f KB", Double(size) / 1024) }
    return "\(size) B"
}

/// ISO8601 时间戳 → `09-24 09:41`（去掉年份、秒、毫秒 —— 列表里没人看那些）.
private func shortTime(_ raw: String) -> String {
    guard raw.count >= 16 else { return raw }
    let s = raw.dropFirst(5)                    // "2026-09-24T09:41:53Z" → "09-24T09:41:53Z"
    return s.prefix(12).replacingOccurrences(of: "T", with: " ")   // → "09-24 09:41"
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
            // ▸ v0.3.512：监督 / 日志 收进「更多」——
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
    /// ▸ v0.3.512：批量选择模式（用户要求「不能批量选择/全选删除操作吗」）
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
        guard airliftOK(dict) else {
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
        previewText = airliftOK(dict)
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
        if !airliftOK(dict) {
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
        if airliftOK(dict) {
            newFolderName = ""
        } else {
            errorText = AirliftJSON.string(dict, "error") ?? json
        }
        await load()
    }

}

// MARK: - 写入（AIR + airlift）

private struct AirliftOverwriteTab: View {
    let module: EscapeModule

    @State private var target = ""
    @State private var airFiles: [AirFile] = []
    @State private var selectedAirName: String?
    @State private var backupFirst = true
    @State private var working = false
    @State private var importing = false
    @State private var confirming = false
    @State private var confirmingDelete = false
    @State private var steps: [String] = []
    @State private var errorText: String?
    @State private var okText: String?
    /// 点「覆盖」时**自动识别**出来的落点（用户要求：不要手动开关目录/文件）
    @State private var resolved: (isDir: Bool, leaf: String?)?
    /// 批量选择（用户要求：源文件也要能批量/全选删除）
    @State private var selecting = false
    @State private var picked = Set<String>()
    @State private var confirmingBatchDelete = false

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
            } header: {
                Text("目标")
            } footer: {
                Text("目录还是文件**自动识别**（问设备，不用你选）. "
                     + "目标是目录时，落到目录下、用源文件名.")
            }

            Section {
                if airFiles.isEmpty {
                    Text("AIR 里还没有文件. 点下面导入，或先把目标读回来.")
                        .font(.caption).foregroundColor(.secondary)
                }
                ForEach(airFiles) { file in
                    Button {
                        if selecting {
                            togglePick(file.name)
                        } else {
                            selectedAirName = file.name
                        }
                    } label: {
                        HStack(spacing: 10) {
                            if selecting {
                                Image(systemName: picked.contains(file.name)
                                      ? "checkmark.circle.fill" : "circle")
                                    .foregroundColor(picked.contains(file.name)
                                                     ? AppTheme.accent : .secondary)
                            } else {
                                Image(systemName: selectedAirName == file.name
                                      ? "largecircle.fill.circle" : "circle")
                                    .foregroundColor(selectedAirName == file.name
                                                     ? AppTheme.accent : .secondary)
                            }
                            Text(file.name)
                                .font(.system(.caption, design: .monospaced))
                                .foregroundColor(.primary).lineLimit(1)
                            Spacer()
                            SizePill(text: byteText(file.size), tint: .secondary)
                        }
                    }
                    .swipeActions(edge: .trailing) {
                        Button(role: .destructive) {
                            Task { await deleteAirFiles([file.name]) }
                        } label: {
                            Label("移除", systemImage: "trash")
                        }
                    }
                }
                if !selecting {
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
                }
            } header: {
                HStack {
                    Text("源文件（AIR，\(airFiles.count) 个）")
                    Spacer()
                    if !airFiles.isEmpty {
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
            } footer: {
                Text(selecting
                     ? "选中后可一次删掉多个."
                     : "源文件先落进 AIR（AFC 根下，读写是瞬时的），再用 airlift 覆盖目标.")
            }

            Section("选项") {
                Toggle("覆盖前先备份原内容", isOn: $backupFirst)
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
            if selecting {
                HStack(spacing: 10) {
                    Button {
                        if picked.count == airFiles.count {
                            picked.removeAll()
                        } else {
                            picked = Set(airFiles.map(\.name))
                        }
                    } label: {
                        Label(picked.count == airFiles.count ? "取消全选" : "全选",
                              systemImage: picked.count == airFiles.count
                                  ? "circle.slash" : "checkmark.circle")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.large)

                    Button(role: .destructive) {
                        confirmingBatchDelete = true
                    } label: {
                        Label("删除 \(picked.count) 个", systemImage: "trash")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .tint(.red)
                    .disabled(picked.isEmpty)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(.bar)
            } else {
                BottomActionBar {
                    Button {
                        Task { await prepareOverwrite() }
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
            Text("落点：\(resolvedPath ?? "?")\n源：AIR/\(selectedAirName ?? "?")"
                 + (backupFirst ? "\n覆盖前会先备份原内容." : "\n已关闭备份."))
        }
        .confirmationDialog("确认删除？", isPresented: $confirmingDelete, titleVisibility: .visible) {
            Button("删除", role: .destructive) { Task { await deleteTarget() } }
            Button("取消", role: .cancel) {}
        } message: {
            Text("将彻底删除 \(target). 原内容会先存进备份（「更多 → 备份与还原」里能看到）.")
        }
        .confirmationDialog("删除选中的 \(picked.count) 个源文件？",
                            isPresented: $confirmingBatchDelete, titleVisibility: .visible) {
            Button("删除", role: .destructive) {
                Task { await deleteAirFiles(Array(picked)) }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("只删 AIR 里的这些副本，设备上的目标文件不受影响.")
        }
    }

    /// 自动识别后的落点（弹窗里显示给用户看）
    private var resolvedPath: String? {
        guard let resolved else { return nil }
        let t = target.trimmingCharacters(in: .whitespaces)
        guard resolved.isDir else { return t }
        let leaf = resolved.leaf ?? selectedAirName ?? ""
        return leaf.isEmpty ? t : t.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "/" + leaf
    }

    private func togglePick(_ name: String) {
        if picked.contains(name) { picked.remove(name) } else { picked.insert(name) }
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
        picked = picked.filter { name in airFiles.contains { $0.name == name } }
    }

    /// 一次删多个源文件（用户要求「源文件也要能批量/全选删除」）.
    private func deleteAirFiles(_ names: [String]) async {
        guard !names.isEmpty else { return }
        working = true; errorText = nil; okText = nil
        defer { working = false }
        var failed: [String] = []
        for name in names {
            let dict = AirliftJSON.dict(await airliftCall("airlift.air",
                                                          AirliftJSON.json(["op": "delete",
                                                                            "name": name])))
            if !airliftOK(dict) {
                failed.append(name + "：" + (AirliftJSON.string(dict, "error") ?? "失败"))
            }
            if selectedAirName == name { selectedAirName = nil }
        }
        okText = failed.isEmpty ? "已删除 \(names.count) 个源文件"
                                : "删了 \(names.count - failed.count) 个，\(failed.count) 个失败"
        errorText = failed.isEmpty ? nil : failed.joined(separator: "\n")
        withAnimation(.easeInOut(duration: 0.18)) {
            selecting = false
            picked.removeAll()
        }
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
        if airliftOK(dict) {
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
        if airliftOK(dict) {
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
        if airliftOK(dict) {
            okText = "已删除 \(path)"
        } else {
            errorText = AirliftJSON.string(dict, "error") ?? json
        }
    }

    /// 点「覆盖」时**先自动识别落点**，把识别结果显示在确认弹窗里，再让用户确认.
    ///
    /// ## 为什么不再让用户手动选「目录 / 文件」（用户要求）
    /// 用户：「不要有手动开关目标路径是否为目录还是文件，你不能自动识别吗」
    /// ⇒ 用 `afc.stat` 问设备（**几十毫秒的 AFC 往返，Media 之外 stat 也能过**）：
    ///   · 路径以 `/` 结尾 ⇒ 目录
    ///   · stat 回 `isDir = true` ⇒ 目录，落到它下面、用源文件名
    ///   · 其余 ⇒ 文件
    /// 识别不出来（stat 失败）时**按文件处理**（最保守），并且弹窗里会把落点写清楚，
    /// 用户能当场看见我们打算写到哪 —— 不会有「悄悄写错地方」.
    private func prepareOverwrite() async {
        let path = target.trimmingCharacters(in: .whitespaces)
        var isDir = path.hasSuffix("/")
        if !isDir {
            let dict = AirliftJSON.dict(await airliftCall("afc.stat",
                                                          AirliftJSON.json(["path": path])))
            isDir = AirliftJSON.bool(dict, "isDir") == true
        }
        resolved = (isDir: isDir, leaf: isDir ? selectedAirName : nil)
        confirming = true
    }

    private func overwrite() async {
        working = true; steps = []; errorText = nil; okText = nil
        defer { working = false }
        var payload: [String: Any] = [
            "target": target.trimmingCharacters(in: .whitespaces),
            "airName": selectedAirName ?? "",
            "backup": backupFirst,
        ]
        if let resolved, resolved.isDir {
            payload["targetIsDirectory"] = true
            if let leaf = resolved.leaf, !leaf.isEmpty { payload["leafName"] = leaf }
        }
        let json = await airliftCall("airlift.overwrite", AirliftJSON.json(payload))
        let dict = AirliftJSON.dict(json)
        steps = AirliftJSON.strings(dict, "steps")
        if airliftOK(dict) {
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
        if airliftOK(dict) {
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
                    AirliftChangesTab()
                } label: {
                    MoreCard(icon: "clock.arrow.circlepath", title: "改动记录",
                             subtitle: "airlift 改过哪些文件、改成了什么值")
                }
                NavigationLink {
                    AirliftBackupsTab()
                } label: {
                    MoreCard(icon: "arrow.counterclockwise.circle", title: "备份与还原",
                             subtitle: "1 号 = 初始备份（永不覆盖），可回滚任意一步")
                }
                NavigationLink {
                    AirliftTweaksTab()
                } label: {
                    MoreCard(icon: "slider.horizontal.3", title: "系统选项",
                             subtitle: "移植自 Nugget：SpringBoard / AirDrop / 标签栏")
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
                Text("· 沙盒外只能读写**单个已知文件**，**不能列目录**" + "\n"
                     + "· 在 Media 之外**建不了目录**（沙盒允许建文件、不允许建目录）" + "\n"
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
        if !airliftOK(dict) {
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

// MARK: - 备份与还原

/// 「备份与还原」：1 号是**初始备份**（永不覆盖），可回滚任意一步.
///
/// 用户要求：「备份应该记录第一次的备份，而不是每次写入都备份一次；
/// 序号 1 即初始备份，方便以后还原」.
///
/// ## 为什么不「自动挑一份好的」（用户否决）
/// 用户指出：1 号只保证**最早**，**不保证完好** —— 若我们第一次读就已经读到坏内容，
/// 1 号本身就是坏的. 我原本打算按「最大/最全」自动挑一份，**被用户否决，且确实是错的**：
/// 文件变小不等于坏（正常删键也会变小），拿大小当判据会误判.
/// ⇒ 现在**只摆数据**：每份列出**键数 / 字节 / 时间**，再并排显示「设备上当前」的键数，
/// 哪一份是好的由用户一眼判断，我们不替他做决定.
private struct AirliftBackupsTab: View {
    @State private var groups: [Group] = []
    @State private var loading = false
    @State private var working = false
    @State private var note = ""
    @State private var confirmRestore: (path: String, version: Int)?
    @State private var confirmAirRestore: (path: String, name: String)?

    struct Group: Identifiable {
        var id: String { path }
        let path: String
        let versions: [Ver]
        /// 设备上**当前**内容的字节数（来自本地缓存，可能不是最新）
        let currentBytes: Int?
        /// 设备上**当前**内容的顶层键数（同上）
        let currentKeys: Int?
        /// `Media/AIR/` 里同源的副本（AFC 直读，秒级）
        let airSources: [AirCopy]
    }
    struct Ver: Identifiable {
        var id: Int { index }
        let index: Int
        let time: String
        let bytes: Int
        /// 顶层键数；不是字典 plist ⇒ nil
        let keys: Int?
        let note: String
    }
    /// `AIR/` 里的一份副本（用「写入」那条路还原）
    struct AirCopy: Identifiable {
        var id: String { name }
        let name: String
        let bytes: Int
        let keys: Int?
    }

    /// 一份备份的副标题：`09-24 09:41 · 5764 B · 49 键`
    private func subtitle(_ v: Ver) -> String {
        var parts = [shortTime(v.time), byteText(v.bytes)]
        if let k = v.keys { parts.append("\(k) 键") }
        return parts.joined(separator: "  ·  ")
    }

    /// AIR 副本的副标题：`5764 B · 49 键`
    private func copySubtitle(_ c: AirCopy) -> String {
        var parts = [byteText(c.bytes)]
        if let k = c.keys { parts.append("\(k) 键") }
        return parts.joined(separator: "  ·  ")
    }

    var body: some View {
        List {
            Section {
                Button {
                    Task { await reload() }
                } label: {
                    Label("刷新", systemImage: "arrow.clockwise")
                }
                .disabled(loading || working)
            } footer: {
                if note.isEmpty {
                    Text("每份都标了**键数 / 字节 / 时间** —— 哪份完好由你看数据判断，我们不替你挑.\n"
                         + "「AIR」那几行是 `Media/AIR/` 里的同源副本（AFC 直读，秒出）—— "
                         + "**备份序号全是坏的时候，好数据往往在这里**.")
                } else {
                    Text(note).foregroundColor(AppTheme.accent)
                }
            }

            if groups.isEmpty {
                Section {
                    Text(loading ? "读取中…" : "还没有备份. 用「写入」覆盖一次就会出现.")
                        .foregroundColor(.secondary)
                }
            }

            ForEach(groups) { group in
                Section {
                    if let cb = group.currentBytes {
                        HStack(spacing: 8) {
                            Text("设备上当前")
                                .font(.caption).foregroundColor(.secondary)
                            Spacer()
                            Text(group.currentKeys.map { "\(byteText(cb))  ·  \($0) 键" }
                                 ?? byteText(cb))
                                .font(.system(.caption2, design: .monospaced))
                                .foregroundColor(.secondary)
                        }
                    }
                    ForEach(group.versions) { v in
                        Button {
                            confirmRestore = (group.path, v.index)
                        } label: {
                            HStack(spacing: 10) {
                                SizePill(text: v.index == 1 ? "1 最早" : "\(v.index)",
                                         tint: v.index == 1 ? .blue : .secondary)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(v.index == 1 ? "最早的一份（我们介入之前）"
                                                      : "第 \(v.index) 份快照")
                                        .font(.callout).foregroundColor(.primary)
                                    Text(subtitle(v))
                                        .font(.system(.caption2, design: .monospaced))
                                        .foregroundColor(.secondary)
                                }
                                Spacer()
                                Image(systemName: "arrow.counterclockwise")
                                    .font(.caption).foregroundColor(AppTheme.accent)
                            }
                        }
                        .disabled(working)
                    }
                    // AIR 里的同源副本 —— 用户那次「救不回」，能救数据的那份其实一直躺在这里
                    ForEach(group.airSources) { copy in
                        Button {
                            confirmAirRestore = (group.path, copy.name)
                        } label: {
                            HStack(spacing: 10) {
                                SizePill(text: "AIR", tint: .purple)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(copy.name.hasSuffix(".bak") ? "AIR 副本（覆盖前自动留的）"
                                                                     : "AIR 副本")
                                        .font(.callout).foregroundColor(.primary)
                                    Text(copySubtitle(copy))
                                        .font(.system(.caption2, design: .monospaced))
                                        .foregroundColor(.secondary)
                                }
                                Spacer()
                                Image(systemName: "arrow.counterclockwise")
                                    .font(.caption).foregroundColor(AppTheme.accent)
                            }
                        }
                        .disabled(working)
                    }
                } header: {
                    Text(group.path)
                        .font(.system(.caption2, design: .monospaced))
                        .textCase(nil)
                }
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .busyOverlay(loading || working, title: working ? "还原中…" : "读取中…")
        .confirmationDialog(restoreTitle, isPresented: Binding(get: { confirmRestore != nil },
                                                              set: { if !$0 { confirmRestore = nil } }),
                            titleVisibility: .visible) {
            Button("还原", role: .destructive) {
                if let target = confirmRestore { Task { await restore(target) } }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text(restoreMessage)
        }
        .confirmationDialog(airRestoreTitle,
                            isPresented: Binding(get: { confirmAirRestore != nil },
                                                 set: { if !$0 { confirmAirRestore = nil } }),
                            titleVisibility: .visible) {
            Button("还原", role: .destructive) {
                if let target = confirmAirRestore { Task { await restoreFromAir(target) } }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text(airRestoreMessage)
        }
        .task { await reload() }
    }

    private var airRestoreTitle: String {
        "用 AIR 副本还原？"
    }

    private var airRestoreMessage: String {
        guard let c = confirmAirRestore else { return "" }
        let copy = groups.first { $0.path == c.path }?.airSources.first { $0.name == c.name }
        var msg = "把 \(c.path) 覆盖成 AIR/\(c.name)"
        if let copy { msg += "（\(copySubtitle(copy))）" }
        msg += ". 覆盖前会先给当前内容存一份快照."
        return msg
    }

    /// 被选中要还原的那一份（弹窗里要显示它的键数/字节，别让用户盲选）
    private var pending: Ver? {
        guard let c = confirmRestore else { return nil }
        return groups.first { $0.path == c.path }?.versions.first { $0.index == c.version }
    }

    private var restoreTitle: String {
        guard let v = pending else { return "选择要还原的备份" }
        return "还原到第 \(v.index) 份？"
    }

    private var restoreMessage: String {
        guard let v = pending, let c = confirmRestore else { return "" }
        var msg = "把 \(c.path) 覆盖成这一份：\(subtitle(v)). "
        msg += "还原前会先给当前内容也存一份快照（免得还原错了没法回头）."
        return msg
    }

    private func reload() async {
        loading = true
        defer { loading = false }
        let dict = AirliftJSON.dict(await airliftCall("airlift.backups", "{}"))
        let raw = (dict?["paths"] as? [[String: Any]]) ?? []
        var out: [Group] = []
        for item in raw {
            guard let path = item["path"] as? String else { continue }
            let d2 = AirliftJSON.dict(await airliftCall("airlift.backups",
                                                        AirliftJSON.json(["path": path])))
            let vraw = (d2?["versions"] as? [[String: Any]]) ?? []
            let versions = vraw.compactMap { v -> Ver? in
                guard let idx = v["index"] as? Int else { return nil }
                return Ver(index: idx,
                           time: (v["time"] as? String) ?? "",
                           bytes: (v["bytes"] as? Int) ?? 0,
                           keys: v["keys"] as? Int,
                           note: (v["note"] as? String) ?? "")
            }
            if !versions.isEmpty {
                let copies = ((d2?["airSources"] as? [[String: Any]]) ?? []).compactMap { c -> AirCopy? in
                    guard let name = c["name"] as? String else { return nil }
                    return AirCopy(name: name, bytes: (c["bytes"] as? Int) ?? 0,
                                   keys: c["keys"] as? Int)
                }
                out.append(Group(path: path, versions: versions,
                                 currentBytes: d2?["currentBytes"] as? Int,
                                 currentKeys: d2?["currentKeys"] as? Int,
                                 airSources: copies))
            }
        }
        groups = out
    }

    /// 用 `AIR/` 里的副本还原 —— 走「写入」那条路（`airlift.overwrite` + `airName`），
    /// 不是 `airlift.restore`（那个只认带序号的 `AirliftBackups/`）.
    private func restoreFromAir(_ target: (path: String, name: String)) async {
        working = true
        defer { working = false }
        let dict = AirliftJSON.dict(await airliftCall("airlift.overwrite",
                                                      AirliftJSON.json(["target": target.path,
                                                                        "airName": target.name,
                                                                        "backup": true])))
        note = airliftOK(dict)
            ? "已用 AIR/\(target.name) 还原 \(target.path)"
            : "还原失败：" + (AirliftJSON.string(dict, "error") ?? "见日志")
        confirmAirRestore = nil
        await reload()
    }

    private func restore(_ target: (path: String, version: Int)) async {
        working = true
        defer { working = false }
        let dict = AirliftJSON.dict(await airliftCall("airlift.restore",
                                                      AirliftJSON.json(["path": target.path,
                                                                        "version": target.version])))
        note = airliftOK(dict)
            ? "已还原 \(target.path) 到第 \(target.version) 份"
            : "还原失败：" + (AirliftJSON.string(dict, "error") ?? "见日志")
        confirmRestore = nil
        await reload()
    }
}

// MARK: - 系统选项（移植自 Nugget）

/// 「系统选项」：移植 Nugget 的 plist tweak.
///
/// ## 为什么能移植（研究结论）
/// Nugget 自己的机制是 SparseRestore（部分恢复），**在 iOS 27 上已被 Apple 补掉**
/// （它 README 原文：DO NOT USE THIS ON iOS 27）. 但它的功能**本质就是往 plist 写键**，
/// 而那几个 plist 在我们的**可写区** ⇒ 用 airlift 直接写就行.
///
/// ## 「默认」= 删键
/// Nugget 的 UI 每个设置三个单选 `Default / Enabled / Disabled`，
/// `Default` 的动作是 `set_enabled(False)` = **不碰这个键** ⇒
/// 我们关掉开关时**删掉这个键**，就等价于「回到系统默认」.
private struct AirliftTweaksTab: View {
    /// 一条 tweak（键名与值照 Nugget 的 `tweak_loader.py:217-287` 抄）
    struct Tweak: Identifiable {
        var id: String { file + "/" + key }
        let file: String
        let key: String
        let label: String
        let hint: String
        /// 开 = 写入这个值；关 = 删键
        let onValue: Any
        let section: String
    }

    private static let springboard = "/var/mobile/Library/Preferences/com.apple.springboard.plist"
    private static let sharingd = "/var/mobile/Library/Preferences/com.apple.sharingd.plist"
    private static let uikit = "/var/mobile/Library/Preferences/com.apple.UIKit.plist"

    private static let tweaks: [Tweak] = [
        Tweak(file: springboard, key: "SBDontLockAfterCrash", label: "崩溃后不锁屏",
              hint: "SBDontLockAfterCrash", onValue: true, section: "SpringBoard"),
        Tweak(file: springboard, key: "SBDontDimOrLockOnAC", label: "接电源时不自动变暗/锁屏",
              hint: "SBDontDimOrLockOnAC", onValue: true, section: "SpringBoard"),
        Tweak(file: springboard, key: "SBHideLowPowerAlerts", label: "隐藏低电量提示",
              hint: "SBHideLowPowerAlerts", onValue: true, section: "SpringBoard"),
        Tweak(file: springboard, key: "SBHideACPower", label: "隐藏充电提示",
              hint: "SBHideACPower", onValue: true, section: "SpringBoard"),
        Tweak(file: springboard, key: "SBNeverBreadcrumb", label: "永不显示返回上级面包屑",
              hint: "SBNeverBreadcrumb", onValue: true, section: "SpringBoard"),
        Tweak(file: springboard, key: "SBShowSupervisionTextOnLockScreen",
              label: "锁屏显示监督文字", hint: "SBShowSupervisionTextOnLockScreen",
              onValue: true, section: "SpringBoard"),
        Tweak(file: springboard, key: "SBExtendedDisplayOverrideSupportForAirPlayAndDontFileRadars",
              label: "Stage Manager 支持 AirPlay", hint: "AirplaySupport",
              onValue: true, section: "SpringBoard"),
        Tweak(file: springboard, key: "SBAlwaysShowSystemApertureInSnapshots",
              label: "截图中显示灵动岛", hint: "SBAlwaysShowSystemApertureInSnapshots",
              onValue: true, section: "SpringBoard"),
        Tweak(file: springboard, key: "SBSuppressDynamicIslandCompletely",
              label: "完全隐藏灵动岛", hint: "SBSuppressDynamicIslandCompletely",
              onValue: true, section: "SpringBoard"),
        Tweak(file: springboard, key: "SBShowAuthenticationEngineeringUI",
              label: "显示认证工程 UI", hint: "SBShowAuthenticationEngineeringUI",
              onValue: true, section: "SpringBoard"),
        Tweak(file: sharingd, key: "OverrideTimeLimitEveryoneMode", label: "AirDrop 取消 10 分钟限制",
              hint: "OverrideTimeLimitEveryoneMode", onValue: true, section: "AirDrop"),
        Tweak(file: uikit, key: "UseFloatingTabBar", label: "浮动标签栏",
              hint: "UseFloatingTabBar", onValue: false, section: "UIKit"),
    ]

    @State private var keysByFile: [String: [String: String]] = [:]
    @State private var loading = false
    @State private var working = false
    @State private var note = ""
    /// 当前在忙什么 —— 决定遮罩文案（用户反馈「点从设备重读，怎么显示是写入中」）
    @State private var phase = Phase.idle
    /// 正在读第几个文件 / 共几个（读取每个 10~20 秒，必须让用户看见进度）
    @State private var readProgress = (done: 0, total: 0)

    private enum Phase: Equatable {
        case idle, reading, writing
        var title: String {
            switch self {
            case .idle: return ""
            case .reading: return "读取中…"
            case .writing: return "写入中…"
            }
        }
    }

    /// 本页涉及的三个文件（去重，且顺序稳定）
    private var files: [String] {
        var seen: [String] = []
        for t in Self.tweaks where !seen.contains(t.file) { seen.append(t.file) }
        return seen
    }

    /// 短文件名（遮罩里显示，别把整条路径糊上去）
    private func shortFile(_ path: String) -> String {
        path.split(separator: "/").last.map(String.init) ?? path
    }

    private var sections: [String] {
        var seen: [String] = []
        for t in Self.tweaks where !seen.contains(t.section) { seen.append(t.section) }
        return seen
    }

    var body: some View {
        List {
            Section {
                Button {
                    Task { await readFromDevice() }
                } label: {
                    Label("从设备重读（每个文件约 10~20 秒）", systemImage: "arrow.triangle.2.circlepath")
                }
                .disabled(loading || working)
            } footer: {
                Text(note.isEmpty
                     ? "键名与值照 Nugget 抄. **关掉开关 = 删掉这个键 = 回到系统默认**（Nugget 的「Default」语义）.\n"
                       + "进本页会**真的从设备读一遍**（不是拿缓存糊弄你）；改一次值 = 写一次 airlift.\n"
                       + "读写都会**先让偏好服务（cfprefsd）松手** —— 它占着这几个 plist，不松手读不到也守不住.\n"
                       + "改完**多数要 respring / 重启**才看得到效果."
                     : note)
                    .foregroundColor(note.isEmpty ? .secondary : AppTheme.accent)
            }

            ForEach(sections, id: \.self) { section in
                Section {
                    ForEach(Self.tweaks.filter { $0.section == section }) { tweak in
                        Toggle(isOn: Binding(
                            get: { isOn(tweak) },
                            set: { newValue in Task { await apply(tweak, on: newValue) } }
                        )) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(tweak.label).font(.callout)
                                Text(tweak.key)
                                    .font(.system(.caption2, design: .monospaced))
                                    .foregroundColor(.secondary)
                            }
                        }
                        .disabled(working)
                    }
                } header: {
                    Text(section)
                        .font(.footnote.weight(.semibold)).textCase(nil).foregroundColor(.secondary)
                } footer: {
                    if section == "SpringBoard" {
                        Text(Self.springboard).font(.system(.caption2, design: .monospaced))
                    } else if section == "AirDrop" {
                        Text(Self.sharingd).font(.system(.caption2, design: .monospaced))
                    } else {
                        Text(Self.uikit).font(.system(.caption2, design: .monospaced))
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .busyOverlay(loading || working, title: busyTitle)
        .task { await readFromDevice() }
    }

    /// 遮罩文案：读就写「读取中」，写就写「写入中」（用户反馈过这里显示错了）.
    /// 读的时候带上进度 —— 每个文件 10~20 秒，没有进度用户只会以为卡死.
    private var busyTitle: String {
        guard phase == .reading, readProgress.total > 0 else { return phase.title }
        return "读取中 \(readProgress.done + 1)/\(readProgress.total)…"
    }

    private func isOn(_ tweak: Tweak) -> Bool {
        guard let value = keysByFile[tweak.file]?[tweak.key] else { return false }
        if let b = tweak.onValue as? Bool { return value == (b ? "true" : "false") }
        if let i = tweak.onValue as? Int { return value == "\(i)" }
        return value == "\(tweak.onValue)"
    }

    /// **真的从设备读一遍**（用户要求：进本页不要拿上一轮的缓存糊弄）.
    ///
    /// 每个文件一次 airlift 读（10~20 秒），三个文件最多 ~60 秒 ⇒ **必须显示进度**，
    /// 否则用户只会觉得卡死. 失败的文件如实报出名字（读本来就不稳，不是全部都会成）.
    private func readFromDevice() async {
        working = true
        phase = .reading
        defer { working = false; phase = .idle; readProgress = (0, 0) }
        let list = files
        readProgress = (0, list.count)
        var out: [String: [String: String]] = [:]
        var failed: [String] = []
        for (index, file) in list.enumerated() {
            readProgress = (index, list.count)
            let dict = AirliftJSON.dict(await airliftCall("plist.tweak",
                                                          AirliftJSON.json(["path": file,
                                                                            "refresh": true])))
            if !airliftOK(dict) {
                failed.append(shortFile(file))
            }
        }
        // 读完后统一取一遍（此时读成功的已在宿主的本地缓存里，这一遍是秒级的）
        for file in list {
            let dict = AirliftJSON.dict(await airliftCall("plist.tweak",
                                                          AirliftJSON.json(["path": file, "list": true])))
            out[file] = (dict?["keys"] as? [String: String]) ?? [:]
        }
        keysByFile = out
        note = failed.isEmpty
            ? "已从设备重读 \(list.count) 个文件"
            : "\(failed.count) 个文件没读成功：\(failed.joined(separator: "、"))（读本来就不稳，可再点一次）"
    }

    /// 只从宿主的本地缓存取一遍（改完值后用 —— 那时缓存就是刚写进去的内容，秒级）
    private func reload() async {
        loading = true
        defer { loading = false }
        var out: [String: [String: String]] = [:]
        for file in files {
            let dict = AirliftJSON.dict(await airliftCall("plist.tweak",
                                                          AirliftJSON.json(["path": file, "list": true])))
            out[file] = (dict?["keys"] as? [String: String]) ?? [:]
        }
        keysByFile = out
    }

    private func apply(_ tweak: Tweak, on: Bool) async {
        working = true
        phase = .writing
        defer { working = false; phase = .idle }
        var payload: [String: Any] = ["path": tweak.file, "key": tweak.key]
        if on { payload["value"] = tweak.onValue }      // 不传 value = 删键
        let dict = AirliftJSON.dict(await airliftCall("plist.tweak", AirliftJSON.json(payload)))
        note = airliftOK(dict)
            ? (on ? "已写入 \(tweak.key) = \(tweak.onValue)" : "已删键 \(tweak.key)（回到系统默认）")
              + " · 已让偏好服务重读，多数还要 respring / 重启"
            : "失败：" + (AirliftJSON.string(dict, "error") ?? "见日志")
        await reload()
    }
}

// MARK: - 改动记录

/// 「改动记录」：airlift 越界改过哪些文件.
///
/// ## 为什么要有这一页（用户要求）
/// 「如果新增的文件要记忆防止以后不知道改了啥文件加了啥东西」.
/// airlift 写完 `/var/mobile/Library/**` 之后设备上**没有任何痕迹**，
/// 时间一长就成了「不知道哪来的文件」，想回滚也无从下手.
private struct AirliftChangesTab: View {
    @State private var entries: [Row] = []
    @State private var loading = false
    @State private var clearing = false
    @State private var markdownPath = ""

    struct Row: Identifiable {
        let id = UUID()
        let time: String
        let action: String
        let path: String
        let bytes: Int
        let backup: String
        let verified: Bool
        let detail: String
    }

    private var actionLabel: (String) -> (String, Color) {
        { action in
            switch action {
            case "write": return ("写入", .green)
            case "write-failed": return ("写入失败", .red)
            case "delete": return ("删除", .red)
            case "delete-failed": return ("删除失败", .red)
            case "plist-set": return ("改值", .green)
            case "plist-unset": return ("还原默认", .blue)
            case "restore": return ("回滚", .blue)
            case "restore-failed": return ("回滚失败", .red)
            case "kill-cfprefsd": return ("重启偏好服务", .secondary)
            default: return (action, .secondary)
            }
        }
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
                    clearing = true
                } label: {
                    Label("清空记录", systemImage: "trash")
                }
                .disabled(entries.isEmpty || clearing)
            } header: {
                Text("操作")
                    .font(.footnote.weight(.semibold)).textCase(nil).foregroundColor(.secondary)
            } footer: {
                Text("清空只删记录，**设备上的文件不会被动**. "
                     + "记录同时写了一份人可读的 markdown，SSH 里可以直接 cat：\n\(markdownPath)")
                    .font(.caption2)
            }

            if entries.isEmpty {
                Section {
                    Text(loading ? "读取中…" : "还没有改动记录. 用「写入」改一次就会出现.")
                        .foregroundColor(.secondary)
                }
            }

            Section {
                ForEach(entries) { row in
                    let info = actionLabel(row.action)
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 8) {
                            SizePill(text: info.0, tint: info.1)
                            Text(shortTime(row.time))
                                .font(.caption2).foregroundColor(.secondary)
                            Spacer()
                            if row.bytes > 0 {
                                Text(byteText(row.bytes))
                                    .font(.caption2).foregroundColor(.secondary)
                            }
                            if row.verified {
                                Image(systemName: "checkmark.seal.fill")
                                    .font(.caption2).foregroundColor(.green)
                            }
                        }
                        Text(row.path)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                        if !row.detail.isEmpty {
                            // 用户要求：「动作是改了什么值 应该显示在改动记录里」
                            Text(row.detail)
                                .font(.system(.caption, design: .monospaced))
                                .foregroundColor(AppTheme.accent)
                                .fixedSize(horizontal: false, vertical: true)
                                .textSelection(.enabled)
                        }
                        if !row.backup.isEmpty {
                            Text("备份：\(row.backup)")
                                .font(.caption2).foregroundColor(.secondary)
                                .textSelection(.enabled)
                        }
                    }
                    .padding(.vertical, 2)
                }
            } header: {
                Text("最近 \(entries.count) 条")
                    .font(.footnote.weight(.semibold)).textCase(nil).foregroundColor(.secondary)
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .busyOverlay(loading, title: "读取中…")
        .confirmationDialog("清空改动记录？", isPresented: $clearing, titleVisibility: .visible) {
            Button("清空", role: .destructive) { Task { await clear() } }
            Button("取消", role: .cancel) {}
        } message: {
            Text("只删记录，设备上的文件不会被动.")
        }
        .task { await reload() }
    }

    private func reload() async {
        loading = true
        defer { loading = false }
        let dict = AirliftJSON.dict(await airliftCall("airlift.changes",
                                                      AirliftJSON.json(["limit": 200])))
        markdownPath = AirliftJSON.string(dict, "markdownPath") ?? ""
        let raw = (dict?["changes"] as? [[String: Any]]) ?? []
        entries = raw.compactMap { item in
            guard let path = item["path"] as? String else { return nil }
            return Row(time: (item["time"] as? String) ?? "",
                       action: (item["action"] as? String) ?? "",
                       path: path,
                       bytes: (item["bytes"] as? Int) ?? 0,
                       backup: (item["backup"] as? String) ?? "",
                       verified: (item["verified"] as? Bool) ?? false,
                       detail: (item["detail"] as? String) ?? "")
        }
    }

    private func clear() async {
        clearing = true
        defer { clearing = false }
        _ = await airliftCall("airlift.changes.clear", "{}")
        await reload()
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
