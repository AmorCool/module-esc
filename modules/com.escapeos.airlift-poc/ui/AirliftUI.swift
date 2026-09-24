//
//  AirliftUI.swift
//  EscapeSpace · airlift-poc 模块自带
//
//  airlift **自己的一套 UI 系统**.
//
//  ## 为什么不复用主程序的 DesignSystem.swift
//  主程序那套（AppTheme / AppRowIcon / SizePill）是给「应用管理 / 设备信息」这类
//  **浏览型**页面设计的：分组列表、宽松行高、弱化信息密度.
//  而 airlift 是**工具型**界面：路径、字节数、判据、耗时是主角，需要**密、准、可选中**.
//  两者目标不同 ⇒ 各用各的一套，而不是把工具硬塞进列表.
//
//  ## 这套的设计口径
//  · 强调色用 **cyan**（与主程序的蓝刻意区分，一眼看出「这是 airlift」）
//  · 卡片式：14 圆角 + 细分隔线（不靠大色块），信息分层靠**留白与字号**，不靠边框
//  · 路径 / 十六进制 / 文件名一律**等宽**，且可长按选中
//  · 状态只用**小圆点 + 文字**表达（不用感叹号三角）
//  · 全部走系统语义色 ⇒ 自动跟随深浅色
//
//  ## 三条硬规则（用户明确要求）
//  1. 不用黄色感叹号
//  2. 代码注释是给开发者看的，**界面上一个字都不显示**
//  3. 句号一律英文 `.`，给用户看的描述要精简
//

import SwiftUI
import UIKit

// MARK: - 主题

/// airlift 的视觉常量.
enum AirliftTheme {
    /// 强调色 —— 刻意用 cyan，与主程序的蓝区分.
    static let accent = Color(uiColor: .systemCyan)
    /// 危险动作
    static let danger = Color(uiColor: .systemRed)
    /// 成功 / 进行中 / 中性
    static let ok = Color(uiColor: .systemGreen)
    static let warn = Color(uiColor: .systemOrange)

    static let pageInset: CGFloat = 16
    static let cardRadius: CGFloat = 14
    static let cardPad: CGFloat = 14
    static let cardGap: CGFloat = 12

    static var pageFill: Color { Color(uiColor: .systemGroupedBackground) }
    static var cardFill: Color { Color(uiColor: .secondarySystemGroupedBackground) }
    static var hairline: Color { Color(uiColor: .separator).opacity(0.5) }
    static var fieldFill: Color { Color(uiColor: .tertiarySystemFill) }
}

// MARK: - 页面骨架

/// 页面容器：统一底色、内边距与卡片间距.
struct AirliftPage<Content: View>: View {
    @ViewBuilder var content: () -> Content

    var body: some View {
        ScrollView {
            VStack(spacing: AirliftTheme.cardGap) { content() }
                .padding(.horizontal, AirliftTheme.pageInset)
                .padding(.vertical, AirliftTheme.pageInset)
        }
        .background(AirliftTheme.pageFill)
    }
}

/// 卡片容器：可选「图标 + 标题」抬头.
struct AirliftCard<Content: View>: View {
    var title: String?
    var icon: String?
    var tint: Color = AirliftTheme.accent
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let title {
                HStack(spacing: 6) {
                    if let icon {
                        Image(systemName: icon)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(tint)
                    }
                    Text(title)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(.secondary)
                }
                .padding(.bottom, 10)
            }
            VStack(alignment: .leading, spacing: 10) { content() }
        }
        .padding(AirliftTheme.cardPad)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AirliftTheme.cardFill,
                    in: RoundedRectangle(cornerRadius: AirliftTheme.cardRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: AirliftTheme.cardRadius, style: .continuous)
                .stroke(AirliftTheme.hairline, lineWidth: 0.5)
        )
    }
}

// MARK: - 顶部身份卡

/// 模块身份卡：图标 + 名称 + 副标题 + 右侧状态.
struct AirliftHero: View {
    let icon: String
    let title: String
    var subtitle: String = ""
    var tint: Color = AirliftTheme.accent
    var status: (text: String, color: Color)?

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .fill(tint.opacity(0.16))
                    .frame(width: 42, height: 42)
                Image(systemName: icon)
                    .font(.system(size: 19, weight: .medium))
                    .foregroundColor(tint)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.system(size: 16, weight: .semibold))
                if !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 8)
            if let status {
                AirliftPill(text: status.text, tint: status.color)
            }
        }
        .padding(AirliftTheme.cardPad)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AirliftTheme.cardFill,
                    in: RoundedRectangle(cornerRadius: AirliftTheme.cardRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: AirliftTheme.cardRadius, style: .continuous)
                .stroke(AirliftTheme.hairline, lineWidth: 0.5)
        )
    }
}

// MARK: - 小组件

/// 状态胶囊.
struct AirliftPill: View {
    let text: String
    var tint: Color = AirliftTheme.accent

    var body: some View {
        Text(text)
            .font(.system(size: 11, weight: .semibold))
            .foregroundColor(tint)
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .background(tint.opacity(0.14), in: Capsule())
    }
}

/// 左标签 / 右值. 值可等宽、可选中.
struct AirliftKV: View {
    let label: String
    let value: String
    var mono: Bool = false
    var tint: Color?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(label)
                .font(.system(size: 13))
                .foregroundColor(.secondary)
            Spacer(minLength: 8)
            Text(value)
                .font(mono ? .system(size: 12, design: .monospaced) : .system(size: 13))
                .foregroundColor(tint ?? .primary)
                .multilineTextAlignment(.trailing)
                .lineLimit(3)
                .textSelection(.enabled)
        }
    }
}

/// 路径条：等宽显示 + 长按可选中，用底色把「这是一条路径」和正文区分开.
struct AirliftPathBar: View {
    let text: String
    var tint: Color = AirliftTheme.accent

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "scope")
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(tint)
            Text(text)
                .font(.system(size: 12, design: .monospaced))
                .lineLimit(1)
                .truncationMode(.head)
                .textSelection(.enabled)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(AirliftTheme.fieldFill,
                    in: RoundedRectangle(cornerRadius: 9, style: .continuous))
    }
}

/// 等宽输入框.
struct AirliftField: View {
    let placeholder: String
    @Binding var text: String

    var body: some View {
        TextField(placeholder, text: $text)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .font(.system(size: 12, design: .monospaced))
            .padding(.horizontal, 10)
            .padding(.vertical, 9)
            .background(AirliftTheme.fieldFill,
                        in: RoundedRectangle(cornerRadius: 9, style: .continuous))
    }
}

/// 动作按钮：图标 + 标题 +（可选）副标题，整块可点.
struct AirliftAction: View {
    enum Kind { case normal, danger
        var tint: Color { self == .danger ? AirliftTheme.danger : AirliftTheme.accent }
    }
    let title: String
    var subtitle: String = ""
    let icon: String
    var kind: Kind = .normal
    var enabled: Bool = true
    var busy: Bool = false
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(kind.tint.opacity(enabled ? 0.14 : 0.07))
                        .frame(width: 28, height: 28)
                    if busy {
                        ProgressView().controlSize(.mini)
                    } else {
                        Image(systemName: icon)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundColor(enabled ? kind.tint : .secondary)
                    }
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(enabled ? .primary : .secondary)
                    if !subtitle.isEmpty {
                        Text(subtitle)
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled || busy)
    }
}

/// 一行结果 / 错误（小圆点 + 彩色文字）.
struct AirliftNote: View {
    enum Kind { case ok, warn, error
        var tint: Color {
            switch self {
            case .ok: return AirliftTheme.ok
            case .warn: return AirliftTheme.warn
            case .error: return AirliftTheme.danger
            }
        }
    }
    let kind: Kind
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Circle()
                .fill(kind.tint)
                .frame(width: 6, height: 6)
                .padding(.top, 5)
            Text(text)
                .font(.system(size: 12))
                .foregroundColor(kind == .error ? AirliftTheme.danger : .primary)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
            Spacer(minLength: 0)
        }
    }
}

// MARK: - 步骤

/// 把能力返回的「步骤」原文清成给人看的短句.
///
/// 能力返回的步骤里带大量给开发者的解释：`⚠️`、`★`、markdown 的 `**` 与反引号、
/// 以及括号里那串「为什么 / 判据 / 边界」. 那些在**日志**里有用，在**界面**上是噪音.
/// 这里只留「做了什么、成没成」；原文照样能在展开后的「全部行」和日志里看到.
enum AirliftStepText {
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

/// 单条步骤.
struct AirliftStepRow: View {
    let text: String
    var raw: Bool = false

    private var shown: String { raw ? text : AirliftStepText.clean(text) }
    private var isBad: Bool {
        text.contains("失败") || text.contains("拒绝") || text.contains("未成立")
            || text.contains("不一致") || text.contains("缺位")
    }
    private var isGood: Bool {
        text.contains("已") || text.contains("成立") || text.contains("成功")
    }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Circle()
                .fill(isBad ? AirliftTheme.warn : (isGood ? AirliftTheme.ok
                                                          : Color.secondary.opacity(0.4)))
                .frame(width: 6, height: 6)
                .padding(.top, 5)
            Text(shown.isEmpty ? text : shown)
                .font(.system(size: 12))
                .foregroundColor(isBad ? AirliftTheme.warn : .primary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// 步骤卡片：默认只显示关键行，技术判据折起来.
struct AirliftSteps: View {
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
            AirliftCard(title: title, icon: "list.bullet") {
                ForEach(Array((expanded ? steps : keySteps).enumerated()), id: \.offset) { _, step in
                    AirliftStepRow(text: step, raw: expanded)
                }
                if keySteps.count < steps.count {
                    Button {
                        withAnimation(.easeInOut(duration: 0.18)) { expanded.toggle() }
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: expanded ? "chevron.up" : "chevron.down")
                            Text(expanded ? "收起技术细节" : "显示全部 \(steps.count) 行")
                        }
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(AirliftTheme.accent)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }
}

// MARK: - 文件行

/// 文件 / 目录一行：图标 + 名称（等宽）+ 右侧大小 / 箭头.
struct AirliftFileRow: View {
    let name: String
    let isDir: Bool
    let size: Int
    var onTap: () -> Void
    var onDelete: (() -> Void)?

    var body: some View {
        HStack(spacing: 10) {
            Button(action: onTap) {
                HStack(spacing: 10) {
                    Image(systemName: isDir ? "folder.fill" : "doc.text")
                        .font(.system(size: 13))
                        .foregroundColor(isDir ? AirliftTheme.accent : .secondary)
                        .frame(width: 18)
                    Text(name)
                        .font(.system(size: 13, design: .monospaced))
                        .foregroundColor(.primary)
                        .lineLimit(1)
                    Spacer(minLength: 6)
                    if isDir {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(.secondary.opacity(0.6))
                    } else {
                        Text(AirliftByteText.string(size))
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundColor(.secondary)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if let onDelete {
                Button(action: onDelete) {
                    Image(systemName: "trash")
                        .font(.system(size: 12))
                        .foregroundColor(AirliftTheme.danger.opacity(0.75))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.vertical, 3)
    }
}

/// 字节数格式化（等宽数字，避免行宽跳动）.
enum AirliftByteText {
    static func string(_ size: Int) -> String {
        if size >= 1_048_576 { return String(format: "%.1f MB", Double(size) / 1_048_576) }
        if size >= 1024 { return String(format: "%.1f KB", Double(size) / 1024) }
        return "\(size) B"
    }
}
