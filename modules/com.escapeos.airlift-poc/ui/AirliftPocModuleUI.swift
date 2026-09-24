//
//  AirliftPocModuleUI.swift
//  EscapeSpace · airlift-poc 模块自带
//
//  airlift 的界面. 视觉全部走本模块自己的 `AirliftUI.swift`（见那份文件的头注释：
//  为什么不复用主程序的 DesignSystem —— 浏览型 vs 工具型，目标不同）.
//
//  ## 这个模块为什么这么写
//  它只声明 requires，然后调宿主能力（`HostCapabilityService.call`）. 将来漏洞链被替换
//  （airlift -> 下一个），本文件一行都不用改.
//
//  ## 外壳约定
//  `ModuleHostShell` 已经给了顶栏标题与底部 tab 栏 ⇒ 这里**不套 NavigationStack、
//  不设 navigationTitle**（套了会变成双层栏）.
//
//  ## 三条硬规则（用户明确要求）
//  1. 不用黄色感叹号
//  2. 代码注释是给开发者看的，界面上一个字都不显示（`AirliftStepText.clean` 负责清）
//  3. 句号一律英文 `.`，给用户看的描述要精简
//

import SwiftUI
import UIKit
import UniformTypeIdentifiers

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
        entries.insert(Entry(time: Date(),
                             capability: capability,
                             args: Self.clip(args),
                             result: Self.clip(result),
                             ok: ok),
                       at: 0)
        if entries.count > 200 { entries.removeLast(entries.count - 200) }
    }

    func clear() { entries.removeAll() }

    private static func clip(_ text: String) -> String {
        guard text.count > maxTextLength else { return text }
        return String(text.prefix(maxTextLength)) + "\n…（已截断，原文 \(text.count) 字符）"
    }

    /// 统一的调用入口：调宿主能力并自动记一条内存日志.
    ///
    /// 同步阻塞：沙盒外操作走 airlift，一次 10~20 秒，调用方必须在后台线程调.
    nonisolated static func callRaw(_ capability: String, _ jsonArgs: String) -> (rc: Int32, json: String) {
        let result = HostCapabilityService.call(capability: capability, jsonArgs: jsonArgs)
        let ok = result.0 == 0
        Task { @MainActor in
            AirliftPocLog.shared.record(capability: capability,
                                        args: jsonArgs,
                                        result: result.1,
                                        ok: ok)
        }
        return (result.0, result.1)
    }
}

// MARK: - JSON 小工具

/// 从能力返回值里安全取值. 刻意不用 Codable：宿主返回会加字段，用字典读能向前兼容，
/// 解析失败时也能把原文交给界面（排障时原文比「解析失败」有用得多）.
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

/// 统一的异步调用（宿主能力是同步阻塞的，放后台线程）.
private func airliftCall(_ capability: String, _ args: String) async -> String {
    await withCheckedContinuation { continuation in
        DispatchQueue.global(qos: .userInitiated).async {
            let (_, json) = AirliftPocLog.callRaw(capability, args)
            continuation.resume(returning: json)
        }
    }
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
            ModuleUITab(id: "files", title: "文件",
                        systemImage: "folder") { m in
                AirliftFilesTab(module: m)
            },
            ModuleUITab(id: "overwrite", title: "写入",
                        systemImage: "square.and.arrow.down") { m in
                AirliftOverwriteTab(module: m)
            },
            ModuleUITab(id: "theme", title: "主题",
                        systemImage: "keyboard") { m in
                AirliftThemeTab(module: m)
            },
            ModuleUITab(id: "supervised", title: "监督",
                        systemImage: "lock.shield") { m in
                AirliftSupervisedTab(module: m)
            },
            ModuleUITab(id: "log", title: "日志",
                        systemImage: "text.alignleft") { m in
                AirliftLogTab()
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
        AirliftPage {
            AirliftHero(icon: "bolt.horizontal.circle.fill",
                        title: module.name,
                        subtitle: "v\(module.version) · 通过宿主能力接口读写沙盒外文件",
                        tint: .purple,
                        status: module.isUsable ? ("可用", AirliftTheme.ok)
                                                : ("不可用", AirliftTheme.warn))

            if !module.blockingIssues.isEmpty {
                AirliftCard(title: "为什么不可用", icon: "info.circle", tint: AirliftTheme.warn) {
                    ForEach(module.blockingIssues, id: \.self) { issue in
                        AirliftNote(kind: .warn, text: issue)
                    }
                }
            }

            AirliftCard(title: "宿主", icon: "iphone") {
                AirliftKV(label: "版本",
                          value: hostBuild.isEmpty ? hostVersion : "\(hostVersion) (\(hostBuild))",
                          mono: true)
                AirliftKV(label: "airlift（本模块读写）",
                          value: airliftRunnable == nil ? "查询中…" : (airliftRunnable! ? "可用" : "不可用"),
                          tint: airliftRunnable == nil ? .secondary
                              : (airliftRunnable! ? AirliftTheme.ok : AirliftTheme.warn))
                AirliftKV(label: "「漏洞利用」里的 airlift",
                          value: airliftEnabled == nil ? "查询中…" : (airliftEnabled! ? "已启用" : "未启用"),
                          tint: airliftEnabled == nil ? .secondary
                              : (airliftEnabled! ? AirliftTheme.ok : AirliftTheme.warn))
                if !exploitNote.isEmpty {
                    Text(exploitNote)
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            AirliftCard(title: "本模块声明的能力（\(supportedCapabilities.isEmpty ? "…" : "\(supportedCapabilities.count)")）",
                        icon: "checklist") {
                if supportedCapabilities.isEmpty {
                    Text(loading ? "查询中…" : "未取到能力清单")
                        .font(.system(size: 12)).foregroundColor(.secondary)
                } else {
                    ForEach(module.requires ?? [], id: \.self) { cap in
                        let ok = supportedCapabilities.contains(cap)
                        HStack(spacing: 8) {
                            Circle()
                                .fill(ok ? AirliftTheme.ok : AirliftTheme.danger)
                                .frame(width: 6, height: 6)
                            Text(cap)
                                .font(.system(size: 12, design: .monospaced))
                            Spacer(minLength: 0)
                            if !ok {
                                Text("缺失")
                                    .font(.system(size: 11, weight: .semibold))
                                    .foregroundColor(AirliftTheme.danger)
                            }
                        }
                    }
                }
            }

            AirliftCard {
                AirliftAction(title: loading ? "查询中…" : "刷新",
                              subtitle: "重新读取宿主版本、airlift 状态与能力清单",
                              icon: "arrow.clockwise", busy: loading) {
                    Task { await refresh() }
                }
            }
        }
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
        AirliftPage {
            AirliftHero(icon: "folder.fill",
                        title: "文件",
                        subtitle: "AFC 的两个根：Media 与 CrashReporter",
                        status: (root == "crash" ? "CrashReporter" : "Media", AirliftTheme.accent))

            AirliftCard(title: "位置", icon: "externaldrive") {
                Picker("根", selection: $root) {
                    Text("/var/mobile/Media").tag("media")
                    Text("CrashReporter").tag("crash")
                }
                .pickerStyle(.segmented)
                .onChange(of: root) { _ in
                    path = "/"
                    Task { await load() }
                }
                AirliftPathBar(text: path == "/" ? rootDisplay : path)
                HStack(spacing: 10) {
                    AirliftAction(title: "上一级", icon: "arrow.up",
                                  enabled: path != "/" && !loading) {
                        Task { await goUp() }
                    }
                    AirliftAction(title: "刷新", icon: "arrow.clockwise", busy: loading) {
                        Task { await load() }
                    }
                }
            }

            if let errorText {
                AirliftCard(title: "错误", icon: "xmark.octagon", tint: AirliftTheme.danger) {
                    AirliftNote(kind: .error, text: errorText)
                }
            }

            AirliftCard(title: "内容（\(entries.count) 项）", icon: "list.bullet") {
                if entries.isEmpty && !loading {
                    Text("目录为空").font(.system(size: 12)).foregroundColor(.secondary)
                }
                ForEach(entries) { entry in
                    AirliftFileRow(name: entry.name,
                                   isDir: entry.isDir,
                                   size: entry.size) {
                        if entry.isDir {
                            Task { await enter(entry) }
                        } else {
                            Task { await preview(entry) }
                        }
                    } onDelete: {
                        deleteEntry = entry
                        confirmingDelete = true
                    }
                }
            }

            AirliftCard(title: "新建目录", icon: "folder.badge.plus") {
                AirliftField(placeholder: "目录名", text: $newFolderName)
                AirliftAction(title: "创建", icon: "plus",
                              enabled: !newFolderName.trimmingCharacters(in: .whitespaces).isEmpty) {
                    Task { await makeFolder() }
                }
            }

            AirliftCard(title: "探测任意路径", icon: "scope") {
                Text("Media 之外读 / 写 / 列都会被沙盒拒，但 stat 能过 —— 一次 AFC 往返、几十毫秒.")
                    .font(.system(size: 11)).foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                AirliftField(placeholder: "相对当前根的路径，可含 ..", text: $statPath)
                AirliftAction(title: "查一下", icon: "magnifyingglass") {
                    Task { await doStat() }
                }
                if !statResult.isEmpty {
                    AirliftPathBar(text: statResult, tint: .secondary)
                }
            }
        }
        .sheet(item: $previewEntry) { entry in
            NavigationStack {
                ScrollView {
                    Text(previewLoading ? "读取中…" : previewText)
                        .font(.system(size: 12, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(AirliftTheme.pageInset)
                        .textSelection(.enabled)
                }
                .background(AirliftTheme.pageFill)
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
                                     AirliftJSON.json(["root": root,
                                                       "path": entry.path,
                                                       "encoding": "utf8"]))
        let dict = AirliftJSON.dict(json)
        previewText = AirliftJSON.bool(dict, "ok") == true
            ? (AirliftJSON.string(dict, "data") ?? "")
            : (AirliftJSON.string(dict, "error") ?? json)
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
                + " · \(AirliftByteText.string(AirliftJSON.int(dict, "size") ?? 0))"
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
        AirliftPage {
            AirliftHero(icon: "square.and.arrow.down.fill",
                        title: "写入",
                        subtitle: "用 AIR 里的文件覆盖沙盒外的任意路径",
                        tint: AirliftTheme.warn,
                        status: (working ? "执行中" : "就绪",
                                 working ? AirliftTheme.warn : AirliftTheme.ok))

            AirliftCard(title: "目标", icon: "scope") {
                AirliftField(placeholder: "/var/mobile/... 绝对路径", text: $target)
                Toggle("目标是目录（写到它下面）", isOn: $targetIsDirectory)
                    .font(.system(size: 13))
                if targetIsDirectory {
                    AirliftField(placeholder: "文件名（留空 = 用源文件名）", text: $leafName)
                }
                Text(targetIsDirectory ? "落点 = 目标目录 / 文件名" : "落点 = 上面填的这个路径本身")
                    .font(.system(size: 11)).foregroundColor(.secondary)
            }

            AirliftCard(title: "源文件（AIR）", icon: "tray.full") {
                if airFiles.isEmpty {
                    Text("AIR 里还没有文件. 点下面导入，或先把目标读回来.")
                        .font(.system(size: 12)).foregroundColor(.secondary)
                }
                ForEach(airFiles) { file in
                    HStack(spacing: 10) {
                        Button {
                            selectedAirName = file.name
                        } label: {
                            HStack(spacing: 10) {
                                Image(systemName: selectedAirName == file.name
                                      ? "largecircle.fill.circle" : "circle")
                                    .font(.system(size: 13))
                                    .foregroundColor(selectedAirName == file.name
                                                     ? AirliftTheme.accent : .secondary)
                                Text(file.name)
                                    .font(.system(size: 12, design: .monospaced))
                                    .foregroundColor(.primary)
                                    .lineLimit(1)
                                Spacer(minLength: 6)
                                Text(AirliftByteText.string(file.size))
                                    .font(.system(size: 11, design: .monospaced))
                                    .foregroundColor(.secondary)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        Button {
                            Task { await deleteAirFile(file.name) }
                        } label: {
                            Image(systemName: "trash")
                                .font(.system(size: 12))
                                .foregroundColor(AirliftTheme.danger.opacity(0.75))
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.vertical, 3)
                }
                AirliftAction(title: "从本机选择文件导入",
                              subtitle: "走统一文件选择调用点（asCopy，LC 环境可用）",
                              icon: "square.and.arrow.down") {
                    importing = true
                }
                AirliftAction(title: "把目标读回来",
                              subtitle: "读取并把原字节写回原位，不改动目标",
                              icon: "arrow.down.doc",
                              enabled: !working && !target.trimmingCharacters(in: .whitespaces).isEmpty) {
                    Task { await pullToAir() }
                }
            }

            AirliftCard(title: "动作", icon: "bolt") {
                Toggle("覆盖前先把目标备份到 AIR（.bak）", isOn: $backupFirst)
                    .font(.system(size: 13))
                AirliftAction(title: "覆盖目标",
                              subtitle: selectedAirName.map { "用 AIR/\($0)" } ?? "先选一个源文件",
                              icon: "square.and.arrow.up.on.square",
                              enabled: selectedAirName != nil
                                  && !target.trimmingCharacters(in: .whitespaces).isEmpty,
                              busy: working) {
                    confirming = true
                }
                AirliftAction(title: "删除目标文件",
                              subtitle: "先备份再删，备份留在 LoginLogs/",
                              icon: "trash", kind: .danger,
                              enabled: !working && !target.trimmingCharacters(in: .whitespaces).isEmpty) {
                    confirmingDelete = true
                }
            }

            if let okText { AirliftCard { AirliftNote(kind: .ok, text: okText) } }
            if let errorText { AirliftCard { AirliftNote(kind: .error, text: errorText) } }
            AirliftSteps(steps: steps)
        }
        .task { await refreshAirList() }
        .documentPicker(isPresented: $importing,
                        allowedTypes: [.item],
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
    ///
    /// 入参是**已经在 App 沙盒里**的 URL —— SharedDocumentPicker 用 asCopy: true，
    /// 系统拷完才回调，所以不要再调 startAccessingSecurityScopedResource.
    private func importPicked(_ urls: [URL]) async {
        guard let url = urls.first else { return }
        guard let data = try? Data(contentsOf: url) else {
            errorText = "读不到所选文件：\(url.lastPathComponent)"
            return
        }
        let args = AirliftJSON.json(["op": "write",
                                     "name": url.lastPathComponent,
                                     "data": data.base64EncodedString(),
                                     "encoding": "base64"])
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
        working = true
        steps = []
        errorText = nil
        okText = nil
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
        working = true
        steps = []
        errorText = nil
        okText = nil
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
        working = true
        steps = []
        errorText = nil
        okText = nil
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
///
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
        AirliftPage {
            AirliftHero(icon: "keyboard.fill",
                        title: "密码键盘主题",
                        subtitle: "把 .passthm 的按键图写进系统的 TelephonyUI 缓存",
                        tint: .pink,
                        status: theme == nil ? ("未选择", .secondary)
                                             : ("\(theme!.keys.count) 个按键", .pink))

            AirliftCard(title: "前提", icon: "info.circle", tint: AirliftTheme.warn) {
                Text("需要 TelephonyUI-8 / 9 / 10 里至少有一个已经存在 —— airlift 在 Media 之外建不了目录.")
                    .font(.system(size: 11)).foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            AirliftCard(title: "主题包", icon: "doc.zipper") {
                AirliftAction(title: "选择 .passthm 文件", icon: "square.and.arrow.down") {
                    importing = true
                }
                AirliftAction(title: "从一张壁纸切出 12 个按键",
                              subtitle: "整图等分 4 列 x 3 行，按 1-9 * 0 # 命名",
                              icon: "photo") {
                    importingPoster = true
                }
                if theme != nil {
                    Picker("目标版本", selection: $targetVersion) {
                        Text("TelephonyUI-10").tag(10)
                        Text("TelephonyUI-9").tag(9)
                        Text("TelephonyUI-8").tag(8)
                    }
                    .pickerStyle(.segmented)
                    AirliftPathBar(text: targetDir, tint: .secondary)
                }
            }

            if let theme {
                AirliftCard(title: "预览", icon: "keyboard") {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 3),
                              spacing: 8) {
                        ForEach(PasscodeTheme.keypadOrder, id: \.self) { digit in
                            keyTile(digit: digit, theme: theme)
                        }
                    }
                    .padding(.vertical, 4)
                }

                AirliftCard(title: "动作", icon: "bolt") {
                    AirliftAction(title: "应用到设备",
                                  subtitle: "N 个文件只走 1 趟 airlift",
                                  icon: "arrow.up.doc", busy: working) {
                        Task { await apply(theme) }
                    }
                    AirliftAction(title: "导出为 .passthm",
                                  subtitle: "存到沙盒 Documents/Themes/",
                                  icon: "square.and.arrow.up") {
                        exportTheme(theme)
                    }
                }
            }

            if let okText { AirliftCard { AirliftNote(kind: .ok, text: okText) } }
            if let errorText { AirliftCard { AirliftNote(kind: .error, text: errorText) } }
            AirliftSteps(steps: steps)
        }
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
                    .fill(AirliftTheme.fieldFill)
                    .frame(height: 54)
                if let key, let image = UIImage(data: key.data) {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                        .frame(height: 54)
                } else {
                    Text(digit).font(.system(size: 18, weight: .medium))
                        .foregroundColor(.secondary)
                }
            }
            Text(digit).font(.system(size: 10)).foregroundColor(.secondary)
        }
    }

    private func loadTheme(_ url: URL?) async {
        guard let url else { return }
        errorText = nil
        okText = nil
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
                                    keys: keys,
                                    guessedVersion: targetVersion)
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
        working = true
        steps = []
        errorText = nil
        okText = nil
        defer { working = false }
        let files = theme.keys.map { key -> [String: Any] in
            ["name": key.fileName, "data": key.data.base64EncodedString()]
        }
        let json = await airliftCall("airlift.writeMany", AirliftJSON.json([
            "dir": targetDir,
            "files": files,
            "encoding": "base64",
        ]))
        let dict = AirliftJSON.dict(json)
        steps = AirliftJSON.strings(dict, "steps")
        if AirliftJSON.bool(dict, "ok") == true {
            okText = "已写入 \(theme.keys.count) 个按键到 \(targetDir)"
        } else {
            errorText = AirliftJSON.string(dict, "error") ?? json
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
        AirliftPage {
            AirliftHero(icon: isSupervised == true ? "lock.shield.fill" : "lock.open",
                        title: "监督模式",
                        subtitle: isSupervised == nil ? "读取中…"
                                : (isSupervised! ? "已开启" : "未开启"),
                        tint: isSupervised == true ? AirliftTheme.ok : .secondary,
                        status: (isSupervised == nil ? "…" : (isSupervised! ? "开" : "关"),
                                 isSupervised == true ? AirliftTheme.ok : .secondary))

            AirliftCard(title: "结论先说", icon: "info.circle", tint: AirliftTheme.warn) {
                Text("这个目标做不到. CloudConfigurationDetails.plist 在 SystemGroup 容器里，"
                     + "沙盒只允许读 / 移出、拒绝创建 / 写入 —— 读得到 412 字节，"
                     + "但覆盖后读回一点没变，连在同一个目录里新建一个文件都建不出来.")
                    .font(.system(size: 11)).foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text("对照：/var/mobile/Library/** 下的文件可以正常覆盖.")
                    .font(.system(size: 11)).foregroundColor(.secondary)
            }

            AirliftCard(title: "当前状态", icon: "shield") {
                AirliftKV(label: "IsSupervised",
                          value: isSupervised == nil ? "读取中…" : (isSupervised! ? "true" : "false"),
                          mono: true,
                          tint: isSupervised == true ? AirliftTheme.ok : .secondary)
                AirliftField(placeholder: "组织名称（可选）", text: $organizationName)
                AirliftAction(title: "重新读取", icon: "arrow.clockwise", busy: loading) {
                    Task { await readState() }
                }
            }

            AirliftCard(title: "操作", icon: "bolt") {
                AirliftAction(title: isSupervised == true ? "关闭监督模式" : "启用监督模式",
                              subtitle: "读回原文件 -> 写回原位 -> 覆盖 -> 读回校验，约 50~100 秒",
                              icon: isSupervised == true ? "lock.open.fill" : "lock.shield.fill",
                              enabled: isSupervised != nil && !running,
                              busy: running) {
                    confirming = true
                }
            }

            if let errorText { AirliftCard { AirliftNote(kind: .error, text: errorText) } }
            AirliftSteps(steps: steps)
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
        running = true
        steps = []
        errorText = nil
        defer { running = false }
        var payload: [String: Any] = ["enabled": enabled]
        let trimmed = organizationName.trimmingCharacters(in: .whitespacesAndNewlines)
        if enabled, !trimmed.isEmpty { payload["organizationName"] = trimmed }
        let dict = AirliftJSON.dict(await airliftCall("sys.supervised.set", AirliftJSON.json(payload)))
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
        AirliftPage {
            AirliftHero(icon: "text.alignleft",
                        title: "日志",
                        subtitle: "宿主能力调用的原始 JSON 往来",
                        tint: .blue,
                        status: ("\(entries.count) 条", .blue))

            AirliftCard(title: "操作", icon: "wrench") {
                AirliftAction(title: loading ? "读取中…" : "刷新", icon: "arrow.clockwise",
                              busy: loading) {
                    Task { await reload() }
                }
                AirliftAction(title: "清空日志",
                              subtitle: "日志落在 CapabilityLog/run.log，重启 App 不会丢",
                              icon: "trash", kind: .danger) {
                    clearAll()
                }
            }

            if entries.isEmpty {
                AirliftCard {
                    Text("还没有调用记录. 在任意 tab 里操作一次就会出现.")
                        .font(.system(size: 12)).foregroundColor(.secondary)
                }
            }

            ForEach(entries) { entry in
                AirliftCard {
                    DisclosureGroup {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("入参").font(.system(size: 11)).foregroundColor(.secondary)
                            Text(entry.args)
                                .font(.system(size: 11, design: .monospaced))
                                .textSelection(.enabled)
                            Text("返回").font(.system(size: 11)).foregroundColor(.secondary)
                            Text(entry.ret)
                                .font(.system(size: 11, design: .monospaced))
                                .textSelection(.enabled)
                        }
                        .padding(.top, 6)
                    } label: {
                        HStack(spacing: 8) {
                            Circle()
                                .fill(entry.ok ? AirliftTheme.ok : AirliftTheme.danger)
                                .frame(width: 7, height: 7)
                            Text(entry.head)
                                .font(.system(size: 12, design: .monospaced))
                                .lineLimit(2)
                        }
                    }
                    .font(.system(size: 12))
                }
            }
        }
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
