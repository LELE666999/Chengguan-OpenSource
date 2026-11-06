#!/usr/bin/env python3
"""Package the existing signed arm64 app as a Finder drag-to-install disk image.

Run with a Python environment containing scripts/dmg-requirements.txt.
No credentials, user preferences or runtime databases are copied.
"""

import argparse
import hashlib
from pathlib import Path
import plistlib
import re
import shutil
import subprocess
import tempfile

from ds_store import DSStore
from mac_alias import Alias


ROOT = Path(__file__).resolve().parent.parent


def run(*args, **kwargs):
    return subprocess.run([str(arg) for arg in args], check=True, **kwargs)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, help="Destination DMG (must not exist)")
    args = parser.parse_args()
    app = ROOT / "dist/澄观.app"
    with (app / "Contents/Info.plist").open("rb") as stream:
        info = plistlib.load(stream)
    version = info["CFBundleShortVersionString"]
    output = (args.output or ROOT / f"dist/澄观-{version}-arm64.dmg").resolve()
    if output.exists():
        raise SystemExit(f"Refusing to overwrite: {output}")
    output.parent.mkdir(parents=True, exist_ok=True)
    run("codesign", "--verify", "--deep", "--strict", app)
    signature = run("codesign", "-dv", "--verbose=2", app, capture_output=True, text=True).stderr
    match = re.search(r"^Authority=(Developer ID Application:.+)$", signature, re.MULTILINE)
    if not match:
        raise SystemExit("Build and Developer ID sign dist/澄观.app before packaging.")
    identity = match.group(1)
    binary_info = run("lipo", "-archs", app / "Contents/MacOS/Chengguan", capture_output=True, text=True).stdout.strip()
    if binary_info != "arm64":
        raise SystemExit(f"Update the installer architecture label first: {binary_info}")

    with tempfile.TemporaryDirectory(prefix="chengguan-dmg-") as temporary:
        work = Path(temporary)
        stage = work / "stage"
        stage.mkdir()
        run("ditto", app, stage / app.name)
        (stage / "Applications").symlink_to("/Applications")
        (stage / ".background").mkdir()
        run("swift", ROOT / "scripts/DrawDMGBackground.swift", stage / ".background/install.png")
        shutil.copy2(app / "Contents/Resources/ChengguanUserIcon.icns", stage / ".VolumeIcon.icns")
        writable = work / "installer-rw.dmg"
        mount = work / "mount"
        mount.mkdir()
        run("hdiutil", "create", "-quiet", "-srcfolder", stage, "-volname", f"澄观 {version}",
            "-fs", "HFS+", "-format", "UDRW", writable)
        run("hdiutil", "attach", "-quiet", "-nobrowse", "-noautoopen", "-mountpoint", mount, writable)
        try:
            finder_info = bytearray(32)
            finder_info[8:10] = (0x0400).to_bytes(2, "big")
            run("xattr", "-wx", "com.apple.FinderInfo", finder_info.hex(), mount)
            with DSStore.open(str(mount / ".DS_Store"), "w+") as store:
                store["."]["vSrn"] = ("long", 1)
                store["."]["icvl"] = ("type", b"icnv")
                store["."]["bwsp"] = {
                    "ShowStatusBar": False, "ShowToolbar": False, "ShowTabView": False,
                    "ShowPathbar": False, "ShowSidebar": False, "ContainerShowSidebar": False,
                    "WindowBounds": "{{160, 120}, {640, 380}}", "SidebarWidth": 0
                }
                store["."]["icvp"] = {
                    "viewOptionsVersion": 1, "iconSize": 96.0, "textSize": 14.0,
                    "gridSpacing": 100.0, "gridOffsetX": 0.0, "gridOffsetY": 0.0,
                    "arrangeBy": "none", "labelOnBottom": True,
                    "showItemInfo": False, "showIconPreview": False,
                    "scrollPositionX": 0.0, "scrollPositionY": 0.0,
                    "backgroundColorRed": 1.0, "backgroundColorGreen": 1.0, "backgroundColorBlue": 1.0,
                    "backgroundType": 2,
                    "backgroundImageAlias": Alias.for_file(str(mount / ".background/install.png")).to_bytes()
                }
                store[app.name]["Iloc"] = (175, 210)
                store["Applications"]["Iloc"] = (465, 210)
            run("codesign", "--verify", "--deep", "--strict", mount / app.name)
        finally:
            run("hdiutil", "detach", "-quiet", mount)
        compressed = work / "installer.dmg"
        run("hdiutil", "convert", "-quiet", writable, "-format", "UDZO", "-imagekey", "zlib-level=9", "-o", compressed)
        run("codesign", "--sign", identity, "--timestamp", compressed)
        run("codesign", "--verify", "--strict", compressed)
        run("hdiutil", "verify", "-quiet", compressed)
        shutil.move(compressed, output)

    digest = hashlib.sha256(output.read_bytes()).hexdigest()
    checksum = output.with_name(output.name + ".sha256")
    checksum.write_text(f"{digest}  {output.name}\n", encoding="utf-8")
    print(f"DMG: {output}")
    print(f"Version: {version} ({info['CFBundleVersion']}) · arm64")
    print(f"SHA-256: {digest}")
    print("Developer ID signed; Apple notarization is a separate step.")


if __name__ == "__main__":
    main()
