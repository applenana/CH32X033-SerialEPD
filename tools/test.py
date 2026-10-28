"""Build the production C core with a simulated board, then run Python integration tests."""
import os
from pathlib import Path
import shutil
import subprocess
import sys
ROOT = Path(__file__).resolve().parents[1]

def main():
    gcc = os.environ.get("HOST_CC") or shutil.which("gcc")
    if not gcc and Path("C:/msys64/mingw64/bin/gcc.exe").exists():
        gcc = "C:/msys64/mingw64/bin/gcc.exe"
    if not gcc:
        raise SystemExit("Set HOST_CC to a native GCC compiler (64-bit MinGW for 64-bit Windows Python).")
    out = ROOT / "build/tests"; out.mkdir(parents=True, exist_ok=True)
    library = out / ("sim.dll" if os.name == "nt" else "sim.so")
    sources = ["User/protocol.c", "User/epd.c", "tests/sim.c"]
    env = os.environ.copy()
    env["PATH"] = str(Path(gcc).resolve().parent) + os.pathsep + env.get("PATH", "")
    subprocess.run([gcc, "-std=c11", "-Wall", "-Wextra", "-Werror", "-O1", "-g", "-shared", "-fPIC",
                    "-I" + str(ROOT / "User"), *[str(ROOT / s) for s in sources], "-o", str(library)], check=True, env=env)
    env["SERIALEPD_SIM"] = str(library)
    usb_library = out / ("usb_sim.dll" if os.name == "nt" else "usb_sim.so")
    subprocess.run([gcc, "-std=c11", "-Wall", "-Wextra", "-Werror", "-Wno-pointer-to-int-cast",
                    "-DSERIAL_EPD_HOST_TEST", "-O1", "-g", "-shared", "-fPIC",
                    "-I" + str(ROOT / "tests/fake"), "-I" + str(ROOT / "User"),
                    "-I" + str(ROOT / "Peripheral/inc"), str(ROOT / "tests/usb_sim.c"),
                    str(ROOT / "User/usb_desc.c"), "-o", str(usb_library)], check=True, env=env)
    env["SERIALEPD_USB_SIM"] = str(usb_library)
    subprocess.run([sys.executable, "-m", "unittest", "discover", "-s", "tests", "-v"], cwd=ROOT, env=env, check=True)

if __name__ == "__main__":
    main()
