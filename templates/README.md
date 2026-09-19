# 模板

复制到 `modules/<你的模块id>/` 使用。**目录名必须等于清单里的 `id`**，否则 CI 会警告。

> `templates/` 不在 `modules/` 下，所以 CI 不会校验/打包它。

## 四种形态怎么加

### 1. 纯动作模块（最简单，无签名）

就是 `starter/` 的样子：只写 `actions[]`。

- `type: "signal"` —— 结束/暂停/恢复进程（`process` 用进程名，模糊匹配）
- `type: "bridge"` —— 调用你自己 dylib 的导出符号（需要同时有 `binary`，否则 dylib 不会被加载）

### 2. binary 模块（自带后台服务，**需要签名**）

```json
"binary": {
  "executable": "bin/your.dylib",
  "port": 8080,
  "webPath": "/",
  "autoStart": true
}
```

dylib 是 dlopen 进宿主进程的。`entrySymbol` 默认不用写——引擎会自动找 `*Main` 结尾的导出。

### 3. lua 模块（纯脚本，无签名）

```json
"lua": { "entry": "main.lua" }
```

### 4. webroot 模块（自带网页界面）

```json
"webroot": "webroot"
```

`webroot/index.html` 必须有。

### 5. 原生 SwiftUI 界面（`ui`，推荐优先用）

```json
"ui": { "style": "native", "view": "your-module", "title": "你的模块" }
```

进模块是一个**全屏二级独立界面**：底部是模块自己的导航栏（不是 App 默认底栏），
左上角常驻「返回上一级」+「主页」。

⚠️ **`view` 只是注册名**——真正的 SwiftUI 视图必须编译进宿主
（`EscapeOS/Views/ModuleUI/`，用 `ModuleUIRegistry.shared.register(...)` 注册）。
名字没注册 ⇒ 卡片不显示「打开」按钮。所以加原生界面的模块要**两边同步改**。

### 6. 声明需要的宿主能力（`requires`）

要读写沙盒外文件、改系统设置、枚举进程时，**不要自己重写漏洞利用**，声明能力就行：

```json
"requires": ["fs.read", "fs.write", "sys.supervised.set"]
```

宿主装载时校验，缺任何一项模块就标记为不可用（卡片橙字显示缺哪项）。
能力清单见仓库 README §2.8。模块侧在 `escape_module_init` 里拿到函数表后
调 `call("fs.read", "{\"path\":\"/var/...\"}", &out)`。

## bridge 动作怎么写

```json
{
  "id": "reset-pwd",
  "label": "重置密码",
  "type": "bridge",
  "symbol": "YourModuleSetPwd",
  "args": ["randomPassword", "dataDir"],
  "success": "新密码: {0}"
}
```

- `symbol` 是你的 dylib 导出的 C 函数名，签名必须是
  `int f(const char *a)` / `int f(const char *a, const char *b)` / `int f(void)`，
  返回 `0` 表示成功。
- `args` 是**实参来源声明**，最多 2 个。`randomPassword` / `dataDir` / `moduleDir` / `str:字面量`。
- `success` 里的 `{0}`/`{1}` 会被替换成**实际**传入的值。

## 本地自检

```bash
python3 validate.py modules/<你的模块id>/module.json --strict
```

还没签名（binary/hotfix）时加 `--skip-signature`。
