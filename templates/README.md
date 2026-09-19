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
