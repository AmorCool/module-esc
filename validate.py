#!/usr/bin/env python3
"""模块清单校验（CI 用）：escape.module.v1 规范"""
import json
import sys


def main() -> int:
    if len(sys.argv) != 2:
        print("用法: validate.py <module.json 路径>")
        return 1
    path = sys.argv[1]
    try:
        m = json.load(open(path, encoding="utf-8"))
    except Exception as e:
        print(f"JSON 解析失败: {e}")
        return 1

    required = ["spec", "id", "name", "version", "description", "actions"]
    missing = [k for k in required if k not in m]
    if missing:
        print(f"缺少字段: {missing}")
        return 1
    if m["spec"] != "escape.module.v1":
        print(f"spec 不支持: {m['spec']}")
        return 1
    if not isinstance(m["actions"], list) or not m["actions"]:
        print("actions 必须为非空数组")
        return 1
    for a in m["actions"]:
        if a.get("type") != "signal":
            print(f"不支持的 action type: {a.get('type')}")
            return 1
        if not a.get("process"):
            print("signal 动作缺少 process 字段")
            return 1
    print(f"清单合法: {m['id']} v{m['version']} ({len(m['actions'])} 个动作)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
