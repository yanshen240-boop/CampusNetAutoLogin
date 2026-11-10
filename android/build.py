#!/usr/bin/env python3
"""把 android/ 目录打成 Magisk / KernelSU 模块 zip。

用法：
    python3 android/build.py
产物：
    android/dist/CampusNetAutoLogin-Magisk-v<version>.zip

版本号取自 android/module.prop 的 version 字段，发布前先改那里。
"""
import os
import re
import sys
import zipfile

ROOT = os.path.dirname(os.path.abspath(__file__))
DIST = os.path.join(ROOT, "dist")

# 不进模块 zip 的东西：构建产物、文档、PC 端辅助工具
EXCLUDE_DIRS = {"dist", "__pycache__", "tools"}
EXCLUDE_FILES = {"build.py", "README.md", "RELEASE_NOTES.md", ".gitignore"}

# 需要有执行位的文件（没扩展名的脚本靠这里点名）
EXEC_FILES = {"campusctl", "lib.sh", "monitor.sh"}


def read_version() -> str:
    path = os.path.join(ROOT, "module.prop")
    with open(path, encoding="utf-8") as fh:
        text = fh.read()
    m = re.search(r"^version=(.+)$", text, re.M)
    if not m:
        sys.exit("module.prop 里找不到 version= 字段")
    return m.group(1).strip()


def main() -> None:
    ver = read_version()
    os.makedirs(DIST, exist_ok=True)
    out = os.path.join(DIST, f"CampusNetAutoLogin-Magisk-{ver}.zip")
    if os.path.exists(out):
        os.remove(out)

    count = 0
    with zipfile.ZipFile(out, "w", zipfile.ZIP_DEFLATED, compresslevel=9) as zf:
        for root, dirs, files in os.walk(ROOT):
            # 过滤目录，顺便保证遍历顺序稳定
            dirs[:] = sorted(d for d in dirs if d not in EXCLUDE_DIRS and not d.startswith("."))
            for name in sorted(files):
                if name in EXCLUDE_FILES or name.startswith("."):
                    continue
                full = os.path.join(root, name)
                arc = os.path.relpath(full, ROOT).replace(os.sep, "/")
                info = zipfile.ZipInfo(arc)
                mode = 0o755 if (name in EXEC_FILES or name.endswith(".sh")) else 0o644
                info.external_attr = mode << 16
                info.compress_type = zipfile.ZIP_DEFLATED
                with open(full, "rb") as fh:
                    zf.writestr(info, fh.read())
                count += 1

    print(f"built: {out}")
    print(f"files: {count}, size: {os.path.getsize(out)} bytes, version: {ver}")


if __name__ == "__main__":
    main()
