"""Reproducible no-IDE build. Python stdlib only. Set WCH_GCC to the gcc executable."""
import argparse
import hashlib
import os
from pathlib import Path
import shutil
import subprocess

ROOT = Path(__file__).resolve().parents[1]

def find_gcc(explicit=None):
    candidates = [explicit, os.environ.get("WCH_GCC"), shutil.which("riscv-none-embed-gcc"),
                  shutil.which("riscv-wch-elf-gcc")]
    if os.name == "nt":
        for drive in "ACD":
            base = Path(drive + ":/MounRiverStudio/MounRiver_Studio2/resources/app/resources/win32/components/WCH/Toolchain")
            candidates.extend(base.glob("*/bin/*gcc.exe"))
    for candidate in candidates:
        if candidate and Path(candidate).is_file():
            return Path(candidate).resolve()
    raise SystemExit("WCH compiler not found. Use --gcc PATH or WCH_GCC (MounRiver QingKe toolchain).")

def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--gcc")
    args = ap.parse_args()
    gcc = find_gcc(args.gcc)
    out = ROOT / "build" / "firmware"
    out.mkdir(parents=True, exist_ok=True)
    version = subprocess.check_output([str(gcc), "--version"], text=True).splitlines()[0]
    print(version)
    # Standard RV32IMAC avoids dependence on compiler-specific XW instructions.
    arch = "rv32imac_zicsr" if "12." in version else "rv32imac"
    common = [f"-march={arch}", "-mabi=ilp32", "-msmall-data-limit=8", "-mno-save-restore",
              "-Os", "-g", "-ffunction-sections", "-fdata-sections", "-fno-common"]
    includes = ["-I" + str(ROOT / p) for p in ("User", "Core", "Debug", "Peripheral/inc")]
    sources = sorted((ROOT / "User").glob("*.c"))
    sources += [ROOT / "Core/core_riscv.c", ROOT / "Debug/debug.c", ROOT / "Startup/startup_ch32x035.S"]
    sources += [ROOT / "Peripheral/src" / ("ch32x035_" + p + ".c") for p in ("gpio", "rcc", "spi", "tim", "misc", "iwdg", "pwr")]
    objects = []
    for source in sources:
        obj = out / ("_".join(source.relative_to(ROOT).parts) + ".o")
        flags = ["-std=gnu11", "-Wall", "-Wextra", "-Werror", "-fstack-usage"] if source.suffix == ".c" else []
        subprocess.run([str(gcc), *common, *flags, *includes, "-c", str(source), "-o", str(obj)], check=True)
        objects.append(str(obj))
    elf = out / "serialepd.elf"
    subprocess.run([str(gcc), *common, "-nostartfiles", "--specs=nano.specs", "--specs=nosys.specs",
                    "-T" + str(ROOT / "Ld/Link.ld"), "-Wl,--gc-sections",
                    "-Wl,-Map=" + str(out / "serialepd.map"), *objects, "-o", str(elf)], check=True)
    def companion(name):
        return str(gcc.with_name(gcc.name.replace("gcc", name)))
    for fmt, suffix in (("binary", "bin"), ("ihex", "hex")):
        subprocess.run([companion("objcopy"), "-O", fmt, str(elf), str(out / ("serialepd." + suffix))], check=True)
    size = subprocess.check_output([companion("size"), str(elf)], text=True)
    print(size)
    (out / "build-info.txt").write_text(version + "\n" + " ".join(common) + "\n" + size, encoding="utf-8")
    (out / "SHA256SUMS.txt").write_text("".join(
        hashlib.sha256(p.read_bytes()).hexdigest() + "  " + p.name + "\n"
        for p in (out / "serialepd.bin", out / "serialepd.hex", elf)), encoding="ascii")
    print("Firmware:", out)

if __name__ == "__main__":
    main()
