# ui/ —— 这个模块的原生 SwiftUI 界面（**源码归本仓库所有**）

## 为什么放这里

用户要求模块**真正独立**：界面应该集成在模块里，而不是散在宿主仓库。
但 SwiftUI 视图**必须编译**（设备上没有 Swift 编译器，zip 里放 .swift 也没有运行时作用），
所以折中成：**源码归模块仓库**，宿主的 `sync_bundled_modules.py` 在 xcodegen 之前
把它拷到 `EscapeOS/Modules/<id>/`，宿主编译时自然带上。

⇒ 本目录是 **UI 的唯一数据源**；宿主仓库里不再持有副本。

## 文件

| 文件 | 作用 |
|---|---|
| `AirliftPocModuleUI.swift` | 模块的全部界面：概览 / 文件 / 写入 / 主题 / 监督 / 日志 |
| `PasscodeTheme.swift` | 锁屏密码键盘主题（`.passthm`）的解析 / 导出 / 切片 |

## 视觉规范（**改之前先看**）

一律复用宿主 `EscapeOS/Views/DesignSystem.swift` 那套，不要自造：

- `AppTheme.accent`（系统蓝）、`AppRowIcon`、`SizePill`
- `List` + `.listStyle(.insetGrouped)`、`Section { } header/footer`、`LabeledContent`
- 强调动作 `.buttonStyle(.borderedProminent)` + `.controlSize(.small)`
- 外壳 `ModuleHostShell` 已提供顶栏标题与底部 tab 栏 ⇒ **不套 NavigationStack、不设 navigationTitle**

三条硬规则（用户明确要求）：

1. 不用黄色感叹号（不用 `⚠️`，也不用 `exclamationmark.triangle`）
2. 代码注释是给开发者看的，**界面上一个字都不显示**（`StepText.clean` 负责清）
3. 句号一律英文 `.`，给用户看的描述要精简

## 代价

改 UI 仍需**重编宿主**（做不到热更新）。要热更新只能走 `webroot`（HTML）那条路。
