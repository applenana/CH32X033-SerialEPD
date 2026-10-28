"""Package existing native Release builds; never downloads SDKs or signs files."""
from pathlib import Path
import hashlib
import json
import re
import shutil
import subprocess
import zipfile

ROOT = Path(__file__).resolve().parents[1]
APP = ROOT / "app"


def main():
    version = re.search(r"^version:\s*([^\s+]+)",
                        (APP / "pubspec.yaml").read_text(encoding="utf-8"), re.M)[1]
    win = APP / "build/windows/x64/runner/Release"
    apk = APP / "build/app/outputs/apk/release/app-release.apk"
    for path in [win / "ink_studio.exe", win / "flutter_windows.dll",
                 win / "serialport.dll", win / "data/app.so", apk]:
        if not path.is_file():
            raise SystemExit(f"Missing Release build: {path}")
    # Do not accidentally package an earlier build after source edits.
    inputs = [APP / "pubspec.yaml", APP / "pubspec.lock"]
    for folder in ["lib", "assets"]:
        inputs.extend(p for p in (APP / folder).rglob("*") if p.is_file())
    newest = max(p.stat().st_mtime for p in inputs)
    if min(apk.stat().st_mtime, (win / "data/app.so").stat().st_mtime) < newest:
        raise SystemExit("Native builds are older than application sources; rebuild first.")

    output = ROOT / "build/releases"
    output.mkdir(parents=True, exist_ok=True)
    windows_zip = output / f"InkStudio-{version}-windows-x64.zip"
    android_apk = output / f"InkStudio-{version}-android.apk"
    readme = f"""墨屿 · Ink Studio {version}

Windows：完整解压 ZIP，运行 ink_studio.exe，保留 DLL 和 data 文件夹。
需要 Windows 10/11 x64；缺少运行库时安装 Microsoft VC++ 2015–2022 x64 Runtime。
Android：安装 APK，使用 USB OTG 数据线，搜索设备、连接并授权 USB。
需要 Android 7.0+ 和 USB Host；此 APK 为 Release 优化、开发证书签名的学习测试版。

1. 选择实际 A0/A1 批次；软件不能自动识别屏幕批次。
2. 导入图片，点击“裁切”自由选择区域、旋转、镜像，再应用。
3. 点击“照片”使用感知重建 DBS；可调观看柔和度和纸白保护。
4. 发送后等待设备报告刷新完成。上传 100% 不等于刷新结束。

原生输出为黑白黄红四色；灰阶由网点混色产生，不是硬件多级灰度。
已做软件模拟互通；尚未完成实际 USB/OTG 和面板刷屏验收。
第三方许可可在应用“关于”查看；本包未做商业代码签名。
"""
    with zipfile.ZipFile(windows_zip, "w", zipfile.ZIP_DEFLATED) as archive:
        for path in sorted(win.rglob("*")):
            if path.is_file():
                archive.write(path, path.relative_to(win).as_posix())
        archive.writestr("使用说明.txt", readme.encode("utf-8"))
        archive.write(APP / "assets/licenses/reconstruction.txt", "RECONSTRUCTION-LICENSE.txt")
    with zipfile.ZipFile(windows_zip) as archive:
        if archive.testzip() is not None:
            raise SystemExit("Windows ZIP failed CRC validation")
    shutil.copy2(apk, android_apk)
    (output / "使用说明.txt").write_text(readme, encoding="utf-8")
    commit = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=ROOT, text=True).strip()
    dirty = bool(subprocess.check_output(["git", "status", "--porcelain"], cwd=ROOT, text=True).strip())
    metadata = {"version": version, "source_commit": commit, "source_dirty": dirty,
                "hardware_verified": False, "android_signing": "development certificate",
                "files": {}}
    checksums = []
    for path in [windows_zip, android_apk]:
        digest = hashlib.sha256(path.read_bytes()).hexdigest()
        checksums.append(f"{digest}  {path.name}")
        metadata["files"][path.name] = {"bytes": path.stat().st_size, "sha256": digest}
    (output / "SHA256SUMS.txt").write_text("\n".join(checksums) + "\n", encoding="ascii")
    (output / "build-info.json").write_text(json.dumps(metadata, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print(json.dumps(metadata, ensure_ascii=False, indent=2))


if __name__ == "__main__":
    main()
