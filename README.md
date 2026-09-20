# module-esc

EscapeSpace 模块仓库——存放模块定义（`escape.module.v1` 规范），CI 自动校验 + 打包 `.zip` + 发布到 [Release](../../releases)（`edge` 预发布，每次 push 更新）。

IPA 编译在 [EscapeOS 主仓库](https://github.com/AmorCool/EscapeOS)进行，与本仓库无关。

---

## 1. 模块是什么

模块 = **一个目录 + 一份清单**：

```
modules/com.example.mymodule/
├── module.json          # 必须：声明式清单
├── signature.sig        # 条件必须：含 binary / hotfix 时由 CI 生成（不要手写、不要提交）
├── webroot/             # 可选：WKWebView 界面（必须含 index.html）
│   └── index.html
├── bin/                 # 可选：binary 模块的 dylib（CI 构建产物）
│   └── openlist.dylib
├── main.lua             # 可选：lua 模块的入口脚本
└── hotfix.js            # 可选：hotfix 模块的 JS 补丁
```

清单本身是纯数据；可执行逻辑都在**载荷**里，由宿主按 `binary` / `lua` / `hotfix` / `webroot` / `ui`
五个可选键决定怎么加载。

宿主解析清单后，动作（`actions[]`）通过两种通道执行：

| 通道 | 宿主实现 | 说明 |
|---|---|---|
| `signal` | `ModuleService.runSignal()` | 按进程名模糊匹配 → 查 PID → 下发信号 |
| `bridge` | `BinaryModuleRunner.bridgeCall()` | `dlsym` 到模块 dylib 的导出符号，直接 C 调用 |

反方向（模块 → 宿主）走 `requires` 声明的**能力接口**（§2.8）。

> `binary` 模块的 dylib 是 **dlopen 进宿主进程**（同一地址空间，不是独立进程），
> 所以 `bridge` 是一次同步 C 函数调用。

---

## 2. module.json 规范（escape.module.v1）

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
  "minHostVersion": "0.3.480",
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

### 2.1 顶层字段

| 字段 | 必填 | 类型 | 说明 |
|---|---|---|---|
| `spec` | ✅ | string | 固定 `"escape.module.v1"` |
| `id` | ✅ | string | 反向域名，**必须与目录名一致**（小写字母/数字/连字符，≥2 段） |
| `name` | ✅ | string | 卡片标题 |
| `version` | ✅ | string | semver，如 `1.2.3`；zip 文件名用它 |
| `versionCode` | ⬜ | int | 正整数，用于版本比较 |
| `description` | ✅ | string | 卡片描述 |
| `actions` | ✅ | array | 动作列表；普通模块不能为空，`binary` / `lua` 模块可以为空 |
| `icon` | ⬜ | string | SF Symbol 名，如 `gearshape.fill` |
| `accent` | ⬜ | string | 主题色名（见下），未知值回退为 `blue` |
| `author` | ⬜ | string | 作者 |
| `notes` | ⬜ | string | 卡片上的橙色注意事项 |
| `category` | ⬜ | string | 分类（如 `系统维护` / `本地服务`） |
| `minHostVersion` | ⬜ | string | 需要的最低宿主版本（semver） |
| `webroot` | ⬜ | string | 模块目录内的 WebView 目录名（须含 `index.html`） |
| `binary` | ⬜ | object | 二进制模块（随宿主自启动的后台服务，如 OpenList） |
| `lua` | ⬜ | object | Lua 脚本模块（`{"entry": "main.lua"}`，纯数据、无签名要求） |
| `hotfix` | ⬜ | object | 热补丁模块（声明式 patch + 可选 JS 脚本） |
| `ui` | ⬜ | object | **原生 SwiftUI 二级界面**（见 §2.7） |
| `requires` | ⬜ | array | **声明需要的宿主能力**（见 §2.8） |
| `distribution` | ⬜ | string | `bundled`（内置进 app）/ `external`（独立模块，**默认**）（见 §2.9） |

已知 `accent`：`blue` `green` `orange` `red` `purple` `pink` `teal` `indigo` `yellow` `gray` `mint` `cyan` `brown`

### 2.2 动作类型

| type | 说明 | 状态 |
|---|---|---|
| `signal` | 按进程名模糊匹配 → 查 PID → 下发信号 | ✅ 已支持 |
| `bridge` | 调用模块 dylib 导出符号（通用桥，语义由模块自定义） | ✅ 已支持 |
| `kill_top_memory` | 结束内存占用最高的后台应用（前台应用豁免） | 🔜 接口预留 |
| `notify` | 本地通知 | 🔜 接口预留 |
| `script` | 设备侧脚本 | 🔜 接口预留 |

> ⚠️ **预留类型写进清单会被 CI 拒绝**——宿主尚未实现，装了也不会执行。
> 需要自定义语义时统一写 `"type": "bridge"` + `"symbol": "..."`。
>
> 宿主对 `type` 的真实判断只有一句「是不是 `signal`」：**任何非 `signal` 的值都走 bridge 通道**，
> 所以历史上用别的名字也能跑；但请只用 `bridge`，校验器也只认它。

#### `signal` 动作字段

| 字段 | 必填 | 说明 |
|---|---|---|
| `process` | ✅ | 进程名，对 `displayName` / `executablePath` 做**大小写不敏感包含匹配** |
| `signal` | ⬜ | `SIGKILL`（默认）/ `SIGSTOP`（暂停）/ `SIGCONT`（恢复）。`SIGTERM` 按 kill 语义映射 |

#### `bridge` 动作字段

| 字段 | 必填 | 说明 |
|---|---|---|
| `symbol` | ✅ | 模块 dylib 的导出符号名（`dlsym`）。宿主先在已加载 dylib 里找，再全局找 |
| `args` | ⬜ | **实参来源声明**数组，按序对应符号参数（见下）。**最多 2 个**——宿主 `bridgeCall` 只实现 0/1/2 参 |
| `success` | ⬜ | 成功消息模板，`{0}`/`{1}` 会被替换为**实际**实参值。缺省为「执行成功」 |
| `marksStopped` | ⬜ | `true` 时宿主执行成功后清掉「运行中」状态（停止类动作需要） |

`args[]` 的取值：

| 写法 | 含义 |
|---|---|
| `randomPassword` | 生成 8 位随机密码（已去掉易混淆字符 `0O1lI`） |
| `dataDir` | 模块数据目录 `<Modules>/<id>/data` |
| `moduleDir` | 模块目录 `<Modules>/<id>` |
| `str:xxx` | 字面量 `xxx` |
| 其它字符串 | 原样字面量（容易写错，校验器会警告） |

> 用 `randomPassword` 时**务必**在 `success` 里带上 `{0}`，否则生成的密码不会显示给用户。
> 例：`"success": "管理员密码已重置: {0}\n旧密码与登录会话已失效。"`

#### 通用字段（两种类型都可用）

| 字段 | 说明 |
|---|---|
| `id` | 动作唯一标识（模块内不可重复） |
| `label` | 按钮文案 |
| `icon` | SF Symbol 名 |
| `confirm` | 执行前确认弹窗文案；为空直接执行 |
| `timeoutSec` | 超时秒数（预留） |

### 2.3 `binary` 模块

随宿主加载的后台服务（如 OpenList）。**含 `binary` 的模块必须带 `signature.sig`。**

```json
"binary": {
  "executable": "bin/openlist.dylib",
  "args": ["server", "--data", "data"],
  "port": 5244,
  "webPath": "/",
  "autoStart": true,
  "entrySymbol": "openlist_embed"
}
```

| 字段 | 必填 | 说明 |
|---|---|---|
| `executable` | ✅ | 相对模块目录的可执行文件/dylib 路径（禁止绝对路径与 `..`） |
| `args` | ⬜ | 启动参数；相对路径会在启动时自动拼上模块目录 |
| `port` | ⬜ | WebUI 端口（1-65535），宿主据此拼 `http://127.0.0.1:<port>` |
| `webPath` | ⬜ | WebUI 路径，默认 `/`，必须以 `/` 开头 |
| `autoStart` | ⬜ | 是否随宿主自启动 |
| `entrySymbol` | ⬜ | 入口符号名。**默认不填**——引擎自动扫描 dylib 符号表里 `*Main` 结尾的导出；只有需要显式指定时才声明 |

> 内置 binary 模块（如 alist）**不落盘**：直接从 app bundle 原地加载，数据目录仍在 `Documents/Modules/<id>/data`。

### 2.4 `lua` 模块

纯脚本模块，走内置 Rust + mlua 解释器，**无签名要求**。

```json
"lua": { "entry": "main.lua" }
```

`entry` 缺省为 `main.lua`，必须是模块目录内的相对路径。

### 2.5 `hotfix` 模块

声明式热补丁 + 可选 JS 脚本。**含 `hotfix` 的模块必须带 `signature.sig`。**

```json
"hotfix": {
  "script": "hotfix.js",
  "patches": [
    { "type": "feature_flag", "key": "someFeature", "value": true },
    { "type": "text", "key": "someLabel", "value": "替换后的文案" }
  ]
}
```

`patches[].type` 仅支持 `feature_flag`（`value` 为布尔）与 `text`（`value` 为字符串）。

### 2.6 `webroot` 模块

模块自带 WKWebView 界面，对齐 KernelSU 的 webroot 机制。目录内**必须**有 `index.html`。

```json
"webroot": "webroot"
```

### 2.7 `ui` — 原生 SwiftUI 二级界面

`webroot` 是网页（WKWebView），`ui` 是**原生**。用哪个取决于体验要求：
原生界面进得去、滑得动、和系统控件一致，但**视图实现必须编译进宿主**——
SwiftUI 视图没法从 zip 里加载。所以 `view` 是一个**注册名**：

```json
"ui": { "style": "native", "view": "airlift-poc", "title": "Airlift PoC" }
```

| 字段 | 必填 | 说明 |
|---|---|---|
| `style` | ✅ | 目前只有 `native` |
| `view` | ✅ | 宿主内的视图注册名（小写字母/数字/连字符），如 `airlift-poc` |
| `title` | ⬜ | 二级界面标题；为空用模块 `name` |

**行为**：模块卡片上出现「打开」按钮 → 进入一个**全屏二级独立界面**——
底部是**模块自己的**导航栏（不是 App 默认底栏），左上角常驻「返回上一级」与「主页」
两个按钮（主页一键回到 App 默认界面）。

**注意**：`view` 名字没被宿主注册时，卡片**不会**出现「打开」按钮（不会给一个点进去空白的入口）。
所以新增原生界面的模块必须同步在宿主里注册同名视图，两边名字要一致。
同时声明 `webroot` 与 `ui` 时宿主优先用原生界面（校验器会警告）。

### 2.8 `requires` — 声明需要的宿主能力

模块想用宿主能力（沙盒外读写、改系统设置、枚举进程…）时，在这里声明，**不要自己重写一套漏洞利用**：

```json
"requires": ["fs.read", "fs.write", "sys.supervised.set"]
```

宿主装载时校验：**缺任何一项 ⇒ 模块标记为「不可用」**，卡片上橙字显示缺哪一项，
执行与打开按钮全部禁用。这样能力缺失是**装载期可见**的，而不是点下去才在运行时静默失败。

当前宿主能力清单（`escape.host.v1`）：

| 能力 | 说明 | 限制 |
|---|---|---|
| `host.version` | 宿主版本 / build 号 | — |
| `host.capabilities` | 列出本机实际支持的能力 | — |
| `fs.read` | 读文件（沙盒外走漏洞利用） | 单文件；沙盒外**默认读后写回原位**（非破坏性），传 `allowMove: true` 才跳过写回 |
| `fs.write` | 写文件（沙盒外走漏洞利用） | 单文件 |
| `fs.delete` | 删文件（沙盒外走漏洞利用） | 单文件 |
| `fs.exists` | 判存在 | ⚠️ **仅 App 沙盒内**（沙盒外无法只 stat 不搬动文件） |
| `fs.list` | 列目录 | ⚠️ **仅 App 沙盒内**；沙盒外无法枚举（漏洞利用只能操作单个文件） |
| `sys.supervised.get` | 读监督模式状态 | 读走 airlift（读后立刻写回原位） |
| `sys.supervised.set` | 开关监督模式（改 `CloudConfigurationDetails.plist` 的 `IsSupervised`） | 全程 airlift，约 40~80 秒 |
| `airlift.air` | AIR 中转站操作：`list` / `mkdir` / `read` / `write` / `delete` | 廉价 AFC，不经 airlift |
| `airlift.pull` | 把沙盒外文件读到 AIR（原文件读后立刻写回原位） | 约 20~40 秒 |
| `airlift.overwrite` | 用 AIR 里的文件（或沙盒内文件）**覆盖**任意沙盒外路径 | 可选覆盖前备份，约 20~60 秒 |
| `container.status` | MHA（MobileHouseArrest）状态诊断 | 排障第一件事 |
| `container.find` | 按 bundle id 查数据容器根路径（**只查不激活**） | 需 MHA |
| `container.activate` | 激活某 App 的数据容器（拿**真实沙盒扩展**） | 需 MHA；lease 是进程级的 |
| `container.list` | **列容器内目录（任意层级）** | 需 MHA。**airlift 做不到这件事** |
| `container.ids` | 枚举某类容器已注册的标识符 | 需 MHA；iOS 26 上常近乎为空 |
| `proc.list` | 列出进程 | — |
| `proc.signal` | 给进程发信号 | 只认 SIGKILL / SIGSTOP / SIGCONT |
| `notify.post` | 发本地通知 | 需用户已授权通知 |
| `exploit.status` | 查漏洞利用可用性 | — |

#### ★ 两条访问沙盒外的路：airlift 与 MHA，能力**不一样**

| | airlift（AirTraffic/ATAirlock） | MHA（MobileHouseArrest 容器） |
|---|---|---|
| 能读/写**单个文件** | ✅ 任意路径 | ✅（需先 activate） |
| **能列目录** | ❌ **不能** | ✅ **能，任意层级** |
| 需要什么 | LocalDevVPN 回环 + 配对文件 | MHA 身份（`container.status` 可查） |
| 单次成本 | 10~20 秒 | 瞬时 |

⇒ **要「浏览」就必须走 MHA**；只有 MHA 不可用时才退回 airlift（那就只能按已知路径读写单个文件）。
`fs.read` / `fs.write` / `fs.delete` / `fs.exists` / **`fs.list`** 会自动识别
「这个路径在不在已激活的容器 lease 内」—— 在的话直接用 FileManager（含列目录），
否则才走 airlift。**模块侧不用自己判断。**

> `container.activate` 拿到的 lease 是**进程级**的（持有到进程退出）。
> 不要对几百个 App 逐个 activate；按需激活。

#### AIR 中转站（`/var/mobile/Media/AIR`）

`/var/mobile/Media` 正是 AFC 的根，所以这个目录**宿主可以廉价直读直写**（一条 AFC 连接，
不用跑 airlift）。而沙盒外的目标文件只能靠 airlift 搬（一趟 10~20 秒）⇒
把读出来的字节落在 AIR，之后的查看 / 编辑 / 再覆盖就都是瞬时操作。

**约定**：读 → 副本落 `AIR/<扁平化文件名>`（例：
`/private/var/mobile/Library/Logs/x.bin` → `private_var_mobile_Library_Logs_x.bin`）；
写 → 用 `AIR/<文件>` 的字节覆盖目标路径。

> ⚠️ **airlift 的「读」是移动不是拷贝** —— 宿主会在读完后**立刻把原字节写回原位**。
> 这是内建行为，模块不用自己处理；但如果看到「没能写回原位」的报错，
> 说明目标文件当前不在原位置，务必按返回里的 `steps` 排查。

#### 「自定义覆盖」的机制差异（参考 lara 的界面形态）

界面形态参考 `github.com/rooootdev/lara` 的 Custom Overwrite（填目标路径 + 选源文件 → 覆盖），
但**漏洞利用完全不同**：

| | lara | 我们 |
|---|---|---|
| 机制 | DarkSword 内核链，内核层**原地覆盖字节** | airlift 越界写 |
| 大小限制 | **目标文件必须 ≥ 源文件** | **无限制**（目标可比源小/大，甚至不存在） |
| 是否碰内核 | 是 | 否 |

调用方式：模块加载时宿主会把一张 **C 函数表**（`EscapeHostAPI`）交给模块的
`escape_module_init(const EscapeHostAPI *api)` 导出（可选导出，返回 0 表示接受）。
函数表里有 `call(capability, json_args, &out_json)`，JSON 进 JSON 出，二进制数据用 base64。
**新增能力只需要改宿主**，清单、校验器、已有模块都不用动。

> `requires` 里写了当前宿主不认识的能力 → 校验器给**警告**（不是错误），
> 因为宿主会自己门禁，而 CI 不该因为宿主将来加了能力就卡住旧清单。

### 2.9 `distribution` — 内置还是独立

```json
"distribution": "external"
```

| 值 | 含义 |
|---|---|
| `bundled` | **内置**进 app：随宿主包一起发布，首次启动由宿主自动安装，用户卸载后不会再回来（除非手动「恢复内置模块」） |
| `external`（**默认**） | **独立模块**：走 edge Release 的 `.zip`，用户在「模块 → 导入」里按需安装 |

**默认是 `external`，这是刻意的**：「不内置」是安全的默认值 —— 忘了写这个字段时，
模块不会被悄悄塞进 app 变成内置模块。

宿主构建时的同步脚本（`Resources/Scripts/sync_bundled_modules.py`）只把
`distribution == "bundled"` 的模块拷进 `Resources/BundledModules/`，并且会
**反向清理**：某个模块从 `bundled` 改成 `external` 后，旧的 bundle 副本会被删掉。

> ⚠️ 这个字段是 v0.3.481 加的，起因是一个真实事故：`airlift-poc` 加进本仓库后
> 被构建脚本按「全部模块」拷进了 bundle，于是它以**内置模块**的身份出现在用户手机上，
> 而需求明确要求它是独立模块。旧实现还硬编码了 `rm -rf .../com.escapeos.alist`，
> 意味着每加一个不内置的模块都得回去改一次宿主 workflow —— 典型的「为模块适配构建脚本」。
> 现在规则由模块自己声明，新增模块**不需要动宿主构建**。

### 2.10 签名规则（重要）

| 模块形态 | 是否需要 `signature.sig` |
|---|---|
| 纯 `actions`（signal / bridge） | ❌ 不需要 |
| `lua` | ❌ 不需要 |
| `binary` | ✅ 需要 |
| `hotfix` | ✅ 需要 |

- 算法：**ed25519**，对 `module.json` 的**原文字节**签名（不是先哈希再签）
- 格式：base64 **单行**文本，文件名 `signature.sig`，与 `module.json` **同目录**
- **CI 自动生成，不要手写、也不要提交到仓库**（`package.yml` 的 Sign 步骤先于 Validate 步骤，保证校验时文件已存在）
- 校验失败或缺失 → 宿主**拒绝导入**
- 私钥是仓库 secret `HOTFIX_PRIVATE_KEY`；未配置时 CI 会**直接失败**（而不是悄悄产出一个装不上的 zip）

---

## 3. 本地自检

```bash
# 全量校验（--strict：警告也算错，建议本地用）
for d in modules/*/; do python3 validate.py "$d/module.json" --strict; done

# binary/hotfix 模块本地还没签名时，跳过签名检查
python3 validate.py modules/com.escapeos.alist/module.json --skip-signature
```

`validate.py` 检查的内容（逐条对照宿主真实实现，不是猜的）：

- 必填字段、`spec` 版本、`id` 反向域名格式且与目录名一致、`version` / `minHostVersion` 是 semver
- 动作 `id` 唯一、`label` 非空、`type` 是 `signal` / `bridge`（预留类型报错）
- `signal` 有 `process` 且信号名被宿主识别；`bridge` 有 `symbol`，`args` ≤ 2 个
- `binary` / `lua` / `hotfix` / `webroot` / `ui` 各子结构，以及对应文件是否真的存在
- `requires` 里的能力名是否在当前宿主已知清单内（未知给警告）
- `signature.sig` 是否存在、是否合法 base64、是否 64 字节
- 容易踩的坑给 warning：`accent` 拼错、`args` 想写 `dataDir` 却写成 `DataDir`、用了 `randomPassword` 但 `success` 里没有 `{0}`、同时声明 `webroot` 与 `ui`

退出码：`0` 合法 / `1` 非法。参数：`--strict`、`--skip-signature`。

---

## 4. 新增模块流程

1. 复制 `templates/starter/` 到 `modules/<你的模块id>/`，改 `module.json`
   （目录名必须等于 `id`；`templates/` 不在 `modules/` 下，不会被 CI 打包）
2. 本地跑一遍 `validate.py --strict`
3. push 到 `main` → CI 自动：签名 → 校验 → 打包 → 发到 `edge` Release
4. 手机导入 `.zip` 验证

## 5. 使用模块

1. 到 [Release (edge)](../../releases) 下载想要的模块 `.zip`
2. EscapeSpace → 模块 → 右上角导入 → 选择 `.zip`
3. 卡片上点「执行」

## 6. CI 工作流

| 工作流 | 触发 | 作用 |
|---|---|---|
| `package.yml` | push `main` / 手动 | 签名（binary+hotfix）→ 校验全部清单 → 打包 zip → 发 `edge` 预发布 |
| `build-alist.yml` | 手动 | 交叉编译 OpenList 为 iOS arm64 dylib + 签名 + 单独发 `edge`（`package.yml` 会跳过 `com.escapeos.alist`，避免空壳 zip 覆盖完整包） |

> `build-alist.yml` 从 EscapeOS 仓库 `migrate-xcode` 分支拉 `sapbridge/openlist.go` 与 `patch_stages.py`；
> 若该分支被删或改名，alist 构建会失败——改分支时记得同步这个 workflow。

---

## 7. 设计方向（尚未实现，勿在清单里使用）

### 7.1 `bridge.args` 泛化

现在的 `args` 是**宿主关键字数组**（`randomPassword` / `dataDir` / `moduleDir`），
其中 `randomPassword` / `dataDir` 目前只有 alist 一个模块在用 —— 这是宿主代码里为单个模块
开的专属口子，属于「为模块适配接口」的反面教材。

方向：`args` 改成 JSON 对象 + `$` 变量，宿主不再需要认识每个模块的参数：

```json
"args": { "length": 8, "dir": "$dataDir", "tag": "$random:12" }
```

变量命名空间由宿主解析（`$dataDir` / `$moduleDir` / `$random:N` / `$now` …），
模块也可以直接写自己的字面量。新增变量是宿主侧加法，清单无需改动。

### 7.2 已落地：宿主能力接口 + 原生界面

`requires`（§2.8）与 `ui`（§2.7）就是为解决「模块必须反向调用宿主」这个缺口加的，
宿主从 v0.3.481 起支持。在此之前，需要沙盒外读写或改系统设置的模块只能自己重写整套漏洞利用。

关键收益：模块调 `fs.read` 时**根本不关心底层是 bad_query 还是 airlift**——
将来漏洞链被替换，模块零改动。这就是「装上就天衣无缝」的接缝所在。

### 7.3 待办

- `minHostVersion` 目前宿主只是读进来存着，**没有真正强制**（v0.3.481 起开始强制）
- `fs.list` 沙盒外无法枚举目录（漏洞利用只支持单文件），需要宿主侧补一个目录枚举通道
