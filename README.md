# module-esc

EscapeSpace 模块仓库——存放模块定义（`escape.module.v1` 规范），CI 自动打包 `.zip` 发布。

## 这是什么

模块是**声明式清单**（`module.json`），不含可执行代码。宿主 app（EscapeSpace）解析清单并通过
Rust FFI 管道执行动作（如按进程名查找 PID 并下发信号）。因此本仓库只做：

1. 存放模块定义：`modules/<模块id>/module.json`（可选 `webroot/` 网页界面）
2. CI 校验清单 + 打包 `.zip` + 发布到 [Release](../../releases)（edge 预发布，每次 push 更新）

IPA 编译在 [EscapeOS 主仓库](https://github.com/AmorCool/EscapeOS)进行，与本仓库无关。

## 模块 .zip 结构

```
com.example.mymodule.zip
└── com.example.mymodule/
    ├── module.json          # 必须：模块清单
    └── webroot/             # 可选：WebView 界面（含 index.html）
        └── index.html
```

## module.json 规范（escape.module.v1）

```json
{
  "spec": "escape.module.v1",
  "id": "com.example.mymodule",
  "name": "我的模块",
  "icon": "gearshape.fill",
  "accent": "blue",
  "version": "1.0.0",
  "versionCode": 1,
  "author": "你的名字",
  "description": "模块功能描述（卡片显示）",
  "notes": "注意事项（橙色小字，可选）",
  "category": "系统维护",
  "minHostVersion": "0.3.56",
  "actions": [
    {
      "id": "main",
      "label": "执行动作",
      "icon": "play.fill",
      "type": "signal",
      "process": "目标进程名",
      "signal": "SIGKILL",
      "confirm": "执行前确认文案（可选，为空直接执行）",
      "timeoutSec": 10
    }
  ]
}
```

### 动作类型

| type | 说明 | 状态 |
|---|---|---|
| `signal` | 按进程名模糊匹配 → 查 PID → 下发信号（SIGKILL/SIGSTOP/SIGCONT，SIGTERM 映射为 SIGKILL） | ✅ v1 支持 |
| `kill_top_memory` | 结束内存占用最高的后台应用（前台应用豁免） | 🔜 接口预留 |
| `notify` | 本地通知 | 🔜 接口预留 |
| `script` | 设备侧脚本 | 🔜 接口预留 |

## 使用方法

1. 到 [Release (edge)](../../releases) 下载想要的模块 `.zip`
2. EscapeSpace → 模块 → 右上角导入 → 选择 .zip
3. 卡片上点「执行」

## 新增模块流程

1. `modules/<新模块id>/module.json` +（可选）`webroot/`
2. push 到 main → CI 自动校验 + 打包 + 发到 edge Release
3. 手机导入 .zip 验证
