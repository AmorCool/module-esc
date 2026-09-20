#!/usr/bin/env python3
"""模块清单校验（CI 用）：escape.module.v1 规范

本脚本与宿主 EscapeSpace 的**真实实现**对齐（对照 v0.3.480 源码）：

  * 动作类型只有两种是真实存在的：
      - signal  宿主 ModuleService.runSignal() 特判分支
                → 需要 process（进程名模糊匹配）；signal 只认
                  SIGKILL / SIGSTOP / SIGCONT（SIGTERM 按 kill 语义映射）
      - bridge  宿主 ModuleService.run() 的通用分支：**任何非 "signal" 的 type
                都走这里**，语义完全由模块自己定义
                → 需要 symbol（dlsym 到模块 dylib 的导出符号）
                → args 是「实参来源声明」，由 BinaryModuleRunner.bridgeCall 解析：
                     randomPassword  生成 8 位随机密码
                     dataDir         模块数据目录 <Modules>/<id>/data
                     moduleDir       模块目录 <Modules>/<id>
                     str:xxx         字面量 xxx
                     其它            原样字面量
                → 宿主 bridgeCall 只支持 0/1/2 个实参（超过 2 个会被静默丢弃）
                → success 是成功消息模板，{0}/{1} 会被替换为**实际**实参值
                → marksStopped 让宿主执行成功后清掉「运行中」状态

  * 含 binary 或 hotfix 的模块**必须**带 signature.sig：
      ed25519 对 module.json **原文字节**签名，base64（单行）文本，
      与 module.json 同目录。宿主用内置公钥校验，缺失/不匹配一律拒绝导入。

用法：
    validate.py <module.json 路径> [--strict] [--skip-signature]

退出码：0 = 合法（可能有 warning）；1 = 非法
--strict           把 warning 也当错误（本地自检建议开启）
--skip-signature   跳过 signature.sig 检查（还没跑 CI 签名的本地自检用）
"""

import base64
import json
import os
import re
import sys

SEMVER_RE = re.compile(r"^\d+\.\d+\.\d+(?:[-+][0-9A-Za-z.\-]+)?$")
MODULE_ID_RE = re.compile(r"^[a-z0-9][a-z0-9-]*(?:\.[a-z0-9][a-z0-9-]*)+$")

# 宿主真实支持的动作类型（见 ModuleService.run）
ACTION_TYPES = {
    "signal": "按进程名模糊匹配 → 查 PID → 下发信号",
    "bridge": "调用模块 dylib 导出符号（通用桥，语义由模块定义）",
}
# README 里标注「接口预留」的类型：宿主尚未实现，禁止在清单里使用
RESERVED_ACTION_TYPES = {"kill_top_memory", "notify", "script"}

# 宿主 parseSignal() 真正区分语义的三个信号
SIGNAL_NAMES = {"SIGKILL", "SIGSTOP", "SIGCONT"}
SIGNAL_ALIASES = {"SIGTERM"}  # 会被当成 kill，接受但提示

# bridge 实参来源关键字（BinaryModuleRunner.bridgeCall）
ARG_SOURCES = {"randomPassword", "dataDir", "moduleDir"}
MAX_BRIDGE_ARGS = 2

# 宿主 accent 色名（ModuleManagerView / EscapeTheme）
ACCENTS = {
    "blue", "green", "orange", "red", "purple", "pink", "teal", "indigo",
    "yellow", "gray", "mint", "cyan", "brown",
}

# 热补丁 patch 类型（HotfixService.reload）
HOTFIX_PATCH_TYPES = {"feature_flag", "text"}

# 宿主能力清单（escape.host.v1，见 HostCapabilityService.capabilityList）
# 模块在 requires 里声明；宿主装载时校验，缺任何一项 ⇒ 模块不可用。
# 注意：这里是「当前宿主已知的能力」，将来宿主加能力要同步改这一份。
KNOWN_CAPABILITIES = {
    "host.version",
    "host.capabilities",
    "fs.read",
    "fs.write",
    "fs.delete",
    "fs.exists",
    "fs.list",
    "sys.supervised.get",
    "sys.supervised.set",
    "airlift.air",
    "airlift.pull",
    "airlift.overwrite",
    "airlift.readdir",
    "airlift.restoredir",
    "airlift.delete",
    "apps.lookup",
    "afc.list",
    "afc.read",
    "afc.write",
    "afc.delete",
    "afc.mkdir",
    "proc.list",
    "proc.signal",
    "notify.post",
    "exploit.status",
}

# 原生界面形态（module.json "ui".style）
UI_STYLES = {"native"}

# 分发方式（module.json "distribution"）
#   bundled  = 内置进 app（随包发布，首次启动自动安装，用户卸载后不再回来）
#   external = 独立模块，走 edge Release 的 .zip 按需导入（**默认**）
# 默认取 external 是刻意的：「不内置」是安全的默认值 —— 忘了写字段时，
# 模块不会被悄悄塞进 app（v0.3.481 真机踩过：airlift-poc 被自动打成了内置模块）。
DISTRIBUTIONS = {"bundled", "external"}


class Report:
    def __init__(self) -> None:
        self.errors: list = []
        self.warns: list = []

    def err(self, msg: str) -> None:
        self.errors.append(msg)

    def warn(self, msg: str) -> None:
        self.warns.append(msg)


def is_str(v) -> bool:
    return isinstance(v, str)


def is_nonempty_str(v) -> bool:
    return isinstance(v, str) and v.strip() != ""


def check_signature(module_dir: str, rep: Report, skip: bool = False) -> None:
    """binary / hotfix 模块必须带同目录 signature.sig（ed25519 / base64 单行）。

    CI 在 validate 之前先签名（package.yml 的 Sign 步骤），所以 CI 里这个文件必然存在。
    本地自检还没签名时用 --skip-signature 跳过。
    """
    sig_path = os.path.join(module_dir, "signature.sig")
    if not os.path.isfile(sig_path):
        if skip:
            rep.warn("signature.sig 不存在（--skip-signature 已跳过）——CI 会自动签名")
        else:
            rep.err(
                "含 binary/hotfix 的模块必须提供 signature.sig（与 module.json 同目录）；"
                "CI 会自动生成，本地自检请加 --skip-signature"
            )
        return
    try:
        with open(sig_path, "r", encoding="utf-8") as fh:
            text = fh.read().strip()
    except Exception as exc:  # pragma: no cover - IO 异常
        rep.err(f"signature.sig 读取失败: {exc}")
        return
    if not text:
        rep.err("signature.sig 为空")
        return
    if "\n" in text:
        rep.warn("signature.sig 含换行——应为单行 base64（openssl base64 -A）")
        text = "".join(text.split())
    try:
        raw = base64.b64decode(text, validate=True)
    except Exception:
        rep.err("signature.sig 不是合法 base64")
        return
    if len(raw) != 64:
        rep.err(f"signature.sig 解出 {len(raw)} 字节，ed25519 签名应为 64 字节")


def check_actions(actions, has_binary: bool, allows_empty: bool, rep: Report) -> None:
    if not isinstance(actions, list):
        rep.err("actions 必须为数组")
        return
    if not actions:
        if not allows_empty:
            rep.err("普通模块 actions 不能为空（binary / lua / 原生界面模块除外）")
        return

    seen_ids = set()
    for idx, a in enumerate(actions):
        where = f"actions[{idx}]"
        if not isinstance(a, dict):
            rep.err(f"{where} 必须是对象")
            continue
        aid = a.get("id")
        if not is_nonempty_str(aid):
            rep.err(f"{where} 缺少 id")
        else:
            where = f"动作 {aid}"
            if aid in seen_ids:
                rep.err(f"{where} 的 id 重复")
            seen_ids.add(aid)
        if not is_nonempty_str(a.get("label")):
            rep.err(f"{where} 缺少 label")

        atype = a.get("type")
        if not is_nonempty_str(atype):
            rep.err(f"{where} 缺少 type")
        elif atype in RESERVED_ACTION_TYPES:
            rep.err(
                f"{where} 使用了预留类型 {atype}（宿主尚未实现，"
                f"当前仅支持 {' / '.join(sorted(ACTION_TYPES))}）"
            )
        elif atype not in ACTION_TYPES:
            rep.err(
                f"{where} 不支持的 action type: {atype}"
                f"（当前仅支持 {' / '.join(sorted(ACTION_TYPES))}；"
                f"任何非 signal 的自定义语义请统一写成 bridge + symbol）"
            )
        elif atype == "signal":
            if not is_nonempty_str(a.get("process")):
                rep.err(f"{where}（signal）缺少 process 字段")
            sig = a.get("signal") or "SIGKILL"
            if not is_str(sig):
                rep.err(f"{where} 的 signal 必须是字符串")
            else:
                up = sig.upper()
                if up not in SIGNAL_NAMES:
                    if up in SIGNAL_ALIASES:
                        rep.warn(f"{where} 的 {up} 会被宿主按 SIGKILL 处理")
                    else:
                        rep.err(
                            f"{where} 的 signal={sig} 宿主不识别"
                            f"（仅 {' / '.join(sorted(SIGNAL_NAMES))}）"
                        )
        elif atype == "bridge":
            symbol = a.get("symbol")
            if not is_nonempty_str(symbol):
                rep.err(f"{where}（bridge）缺少 symbol 字段（模块 dylib 导出符号名）")
            elif not re.match(r"^[A-Za-z_][A-Za-z0-9_]*$", symbol):
                rep.warn(f"{where} 的 symbol={symbol!r} 不像合法的 C 符号名")
            args = a.get("args")
            if args is None:
                pass
            elif not isinstance(args, list):
                rep.err(f"{where} 的 args 必须为数组")
            else:
                if len(args) > MAX_BRIDGE_ARGS:
                    rep.err(
                        f"{where} 声明了 {len(args)} 个实参，"
                        f"宿主 bridgeCall 只消费前 {MAX_BRIDGE_ARGS} 个"
                    )
                for j, spec in enumerate(args):
                    if not is_str(spec):
                        rep.err(f"{where} 的 args[{j}] 必须是字符串")
                        continue
                    if spec in ARG_SOURCES or spec.startswith("str:"):
                        continue
                    # 字面量也合法，但容易写错（比如想写 dataDir 却写成 DataDir）
                    if spec[:1].isalpha():
                        rep.warn(
                            f"{where} 的 args[{j}]={spec!r} 被当作字面量；"
                            f"若想要动态值请用 {' / '.join(sorted(ARG_SOURCES))} 或 str: 前缀"
                        )
                if "randomPassword" in args:
                    if not is_nonempty_str(a.get("success")):
                        rep.warn(
                            f"{where} 用 randomPassword 但没写 success 模板——"
                            f"生成出来的密码不会显示给用户"
                        )
                    elif "{0}" not in a["success"]:
                        rep.warn(f"{where} 的 success 未包含 {{0}} 占位符，密码不会显示")
            if a.get("success") is not None and not is_str(a["success"]):
                rep.err(f"{where} 的 success 必须是字符串")
        if a.get("confirm") is not None and not is_str(a["confirm"]):
            rep.err(f"{where} 的 confirm 必须是字符串")
        if a.get("marksStopped") is not None and not isinstance(a["marksStopped"], bool):
            rep.err(f"{where} 的 marksStopped 必须是布尔值")
        ts = a.get("timeoutSec")
        if ts is not None and (not isinstance(ts, int) or isinstance(ts, bool) or ts <= 0):
            rep.err(f"{where} 的 timeoutSec 必须是正整数")


def check_binary(binary, rep: Report) -> None:
    if not isinstance(binary, dict):
        rep.err("binary 必须是对象")
        return
    exe = binary.get("executable")
    if not is_nonempty_str(exe):
        rep.err("binary.executable 不能为空（相对模块目录的路径，如 bin/openlist.dylib）")
    elif exe.startswith("/") or ".." in exe.split("/"):
        rep.err("binary.executable 必须是模块目录内的相对路径")
    port = binary.get("port")
    if port is not None:
        if not isinstance(port, int) or isinstance(port, bool) or not (1 <= port <= 65535):
            rep.err("binary.port 必须是 1-65535 的整数")
    web_path = binary.get("webPath")
    if web_path is not None:
        if not is_str(web_path):
            rep.err("binary.webPath 必须是字符串")
        elif not web_path.startswith("/"):
            rep.err("binary.webPath 必须以 / 开头")
    if binary.get("autoStart") is not None and not isinstance(binary["autoStart"], bool):
        rep.err("binary.autoStart 必须是布尔值")
    if binary.get("entrySymbol") is not None and not is_nonempty_str(binary["entrySymbol"]):
        rep.err("binary.entrySymbol 必须是非空字符串")


def check_lua(lua, module_dir: str, rep: Report) -> None:
    if not isinstance(lua, dict):
        rep.err("lua 必须是对象")
        return
    entry = lua.get("entry") or "main.lua"
    if not is_nonempty_str(entry):
        rep.err("lua.entry 必须是非空字符串")
        return
    if entry.startswith("/") or ".." in entry.split("/"):
        rep.err("lua.entry 必须是模块目录内的相对路径")
        return
    if module_dir and not os.path.isfile(os.path.join(module_dir, entry)):
        rep.warn(f"lua.entry 指向的脚本不存在: {entry}")


def check_hotfix(hotfix, module_dir: str, rep: Report) -> None:
    if not isinstance(hotfix, dict):
        rep.err("hotfix 必须是对象")
        return
    patches = hotfix.get("patches")
    if patches is not None:
        if not isinstance(patches, list):
            rep.err("hotfix.patches 必须为数组")
        else:
            for idx, p in enumerate(patches):
                where = f"hotfix.patches[{idx}]"
                if not isinstance(p, dict):
                    rep.err(f"{where} 必须是对象")
                    continue
                ptype = p.get("type")
                if ptype not in HOTFIX_PATCH_TYPES:
                    rep.err(
                        f"{where} 的 type={ptype!r} 不支持"
                        f"（仅 {' / '.join(sorted(HOTFIX_PATCH_TYPES))}）"
                    )
                if not is_nonempty_str(p.get("key")):
                    rep.err(f"{where} 缺少 key")
                if "value" not in p:
                    rep.err(f"{where} 缺少 value")
                elif ptype == "feature_flag" and not isinstance(p["value"], bool):
                    rep.err(f"{where} 是 feature_flag，value 必须是布尔值")
                elif ptype == "text" and not is_str(p["value"]):
                    rep.err(f"{where} 是 text，value 必须是字符串")
    script = hotfix.get("script")
    if script is not None:
        if not is_nonempty_str(script):
            rep.err("hotfix.script 必须是非空字符串")
        elif module_dir and not os.path.isfile(os.path.join(module_dir, script)):
            rep.warn(f"hotfix.script 指向的脚本不存在: {script}（默认 hotfix.js）")


def check_webroot(webroot, module_dir: str, rep: Report) -> None:
    if not is_str(webroot) or not webroot.strip():
        rep.err("webroot 必须是非空字符串（模块目录内的相对目录名）")
        return
    if webroot.startswith("/") or ".." in webroot.split("/"):
        rep.err("webroot 必须是模块目录内的相对目录")
        return
    if not module_dir:
        return
    root = os.path.join(module_dir, webroot)
    if not os.path.isdir(root):
        rep.err(f"webroot 目录不存在: {webroot}/")
    elif not os.path.isfile(os.path.join(root, "index.html")):
        rep.err(f"webroot 目录缺少 index.html: {webroot}/index.html")


def check_requires(requires, rep: Report) -> None:
    """模块声明的宿主能力（escape.host.v1）。

    未知能力只给警告不给错误：宿主装载时会自己门禁（模块显示为「缺少宿主能力」，
    不会静默失败），而 CI 不该因为宿主将来加了能力就卡住旧清单。
    """
    if not isinstance(requires, list):
        rep.err("requires 必须为数组（宿主能力名列表）")
        return
    seen = set()
    for idx, cap in enumerate(requires):
        if not is_nonempty_str(cap):
            rep.err(f"requires[{idx}] 必须是非空字符串")
            continue
        if cap in seen:
            rep.warn(f"requires 里 {cap} 重复声明")
        seen.add(cap)
        if cap not in KNOWN_CAPABILITIES:
            rep.warn(
                f"requires 里的 {cap!r} 不在当前宿主已知能力清单内"
                f"（宿主会因此把模块标记为「缺少宿主能力」而不可用；"
                f"若这是新能力，需要先发宿主版本）"
            )


def check_ui(ui, rep: Report) -> None:
    """原生 SwiftUI 界面声明（module.json "ui"）。"""
    if not isinstance(ui, dict):
        rep.err("ui 必须是对象")
        return
    style = ui.get("style")
    if not is_nonempty_str(style):
        rep.err("ui.style 不能为空")
    elif style not in UI_STYLES:
        rep.err(f"ui.style={style!r} 不支持（目前仅 {' / '.join(sorted(UI_STYLES))}）")
    if not is_nonempty_str(ui.get("view")):
        rep.err("ui.view 不能为空（宿主内的视图注册名，如 \"airlift-poc\"）")
    elif not re.match(r"^[a-z0-9][a-z0-9._-]*$", ui["view"]):
        rep.warn(f"ui.view={ui['view']!r} 建议用小写字母/数字/连字符（如 airlift-poc）")
    if ui.get("title") is not None and not is_str(ui["title"]):
        rep.err("ui.title 必须是字符串")


def check_manifest(path: str, strict: bool, skip_signature: bool = False) -> int:
    module_dir = os.path.dirname(os.path.abspath(path))
    try:
        with open(path, "r", encoding="utf-8") as fh:
            m = json.load(fh)
    except Exception as exc:
        print(f"JSON 解析失败: {exc}")
        return 1
    if not isinstance(m, dict):
        print("module.json 顶层必须是对象")
        return 1

    rep = Report()

    for key in ("spec", "id", "name", "version", "description", "actions"):
        if key not in m:
            rep.err(f"缺少字段: {key}")
    if rep.errors:
        for e in rep.errors:
            print(f"  ✗ {e}")
        return 1

    if m["spec"] != "escape.module.v1":
        rep.err(f"spec 不支持: {m['spec']!r}（应为 'escape.module.v1'）")
    mid = m["id"]
    if not is_nonempty_str(mid):
        rep.err("id 不能为空")
    elif not MODULE_ID_RE.match(mid):
        rep.err(f"id={mid!r} 不是反向域名格式（小写字母/数字/连字符，至少两段）")
    elif mid != os.path.basename(module_dir):
        rep.warn(f"id={mid!r} 与目录名 {os.path.basename(module_dir)!r} 不一致（建议一致）")
    if not is_nonempty_str(m["name"]):
        rep.err("name 不能为空")
    if not is_nonempty_str(m["version"]):
        rep.err("version 不能为空")
    elif not SEMVER_RE.match(m["version"]):
        rep.err(f"version={m['version']!r} 不是 semver（如 1.2.3）")
    if not is_nonempty_str(m["description"]):
        rep.err("description 不能为空")
    vc = m.get("versionCode")
    if vc is not None and (not isinstance(vc, int) or isinstance(vc, bool) or vc <= 0):
        rep.err("versionCode 必须是正整数")
    mhv = m.get("minHostVersion")
    if mhv is not None:
        if not is_nonempty_str(mhv):
            rep.err("minHostVersion 不能为空")
        elif not SEMVER_RE.match(mhv):
            rep.err(f"minHostVersion={mhv!r} 不是 semver（如 0.3.480）")
    if m.get("accent") is not None and m["accent"] not in ACCENTS:
        rep.warn(
            f"accent={m['accent']!r} 不在宿主已知色名内，会回退为蓝色"
            f"（已知: {', '.join(sorted(ACCENTS))}）"
        )
    dist = m.get("distribution")
    if dist is not None:
        if not is_nonempty_str(dist):
            rep.err("distribution 不能为空")
        elif dist not in DISTRIBUTIONS:
            rep.err(
                f"distribution={dist!r} 不支持"
                f"（仅 {' / '.join(sorted(DISTRIBUTIONS))}）"
            )

    has_binary = "binary" in m
    has_lua = "lua" in m
    has_hotfix = "hotfix" in m
    has_webroot = "webroot" in m
    has_ui = "ui" in m

    check_actions(m.get("actions"), has_binary, has_lua or has_ui, rep)
    if has_binary:
        check_binary(m["binary"], rep)
    if has_lua:
        check_lua(m["lua"], module_dir, rep)
    if has_hotfix:
        check_hotfix(m["hotfix"], module_dir, rep)
    if has_webroot:
        check_webroot(m["webroot"], module_dir, rep)
    if has_ui:
        check_ui(m["ui"], rep)
    if "requires" in m:
        check_requires(m["requires"], rep)

    if has_webroot and has_ui:
        rep.warn("同时声明了 webroot 与 ui——宿主优先用原生界面，webroot 不会展示")
    if has_binary and has_lua:
        rep.warn("同时声明了 binary 与 lua——宿主优先走 binary，lua 不会被执行")
    if has_binary or has_hotfix:
        check_signature(module_dir, rep, skip=skip_signature)

    for w in rep.warns:
        print(f"  ⚠ {w}")
    for e in rep.errors:
        print(f"  ✗ {e}")

    if rep.errors:
        print(f"清单非法: {mid}（{len(rep.errors)} 个错误）")
        return 1
    if strict and rep.warns:
        print(f"清单非法（--strict）: {mid}（{len(rep.warns)} 个警告）")
        return 1

    kinds = []
    if has_binary:
        kinds.append("binary")
    if has_lua:
        kinds.append("lua")
    if has_hotfix:
        kinds.append("hotfix")
    if has_webroot:
        kinds.append("webroot")
    if has_ui:
        kinds.append("native-ui")
    kind_txt = f"，类型 {'+'.join(kinds)}" if kinds else ""
    req_txt = ""
    if isinstance(m.get("requires"), list) and m["requires"]:
        req_txt = f"，需要能力 {len(m['requires'])} 项"
    dist_txt = f"，分发 {m.get('distribution') or 'external(默认)'}"
    print(
        f"清单合法: {mid} v{m['version']} "
        f"({len(m['actions'])} 个动作{kind_txt}{req_txt}{dist_txt})"
    )
    return 0


def main() -> int:
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    strict = "--strict" in sys.argv[1:]
    skip_signature = "--skip-signature" in sys.argv[1:]
    if len(args) != 1:
        print("用法: validate.py <module.json 路径> [--strict] [--skip-signature]")
        return 1
    return check_manifest(args[0], strict, skip_signature)


if __name__ == "__main__":
    sys.exit(main())
