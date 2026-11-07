import pathlib, plistlib, sys, subprocess, tempfile, shutil
app = pathlib.Path(sys.argv[1])
icon_name = 'ChengguanUserIcon'
info = {
    'CFBundleExecutable': 'Chengguan', 'CFBundleIdentifier': 'studio.lele.Chengguan',
    'CFBundleName': '澄观', 'CFBundleDisplayName': '澄观',
    'CFBundlePackageType': 'APPL', 'CFBundleShortVersionString': '0.20.1', 'CFBundleVersion': '58',
    'LSMinimumSystemVersion': '15.0', 'NSHighResolutionCapable': True,
    'NSAudioCaptureUsageDescription': '为你选择的 App 调节独立音量。音频只在本机实时混音，不录制、不存储、不上传。',
    'NSRemovableVolumesUsageDescription': '显示容量与格式，检查 DCIM 目录；你点击测速时仅写入并读回独立临时文件。完成后释放，不修改或上传现有文件。',
    'NSBluetoothAlwaysUsageDescription': '显示已配对蓝牙设备的连接状态。',
    'NSHumanReadableCopyright': 'Chengguan. SMC reader derived from Stats (MIT).',
    'CFBundleIconFile': icon_name,
}
with tempfile.TemporaryDirectory() as tmp:
    compiled = pathlib.Path(tmp)
    partial = compiled / 'partial.plist'
    original = pathlib.Path(__file__).resolve().parent.parent / 'Design/AppIcon.icon'
    # A new catalog name invalidates legacy icon-service entries while preserving every user layer.
    source = compiled / (icon_name + '.icon')
    shutil.copytree(original, source)
    # Compile the user's original Icon Composer layers, including appearance variants.
    # actool also creates the .icns fallback for our macOS 15 deployment target.
    subprocess.run(['xcrun', 'actool', str(source), '--compile', str(compiled),
                    '--platform', 'macosx', '--minimum-deployment-target', info['LSMinimumSystemVersion'],
                    '--app-icon', icon_name, '--output-partial-info-plist', str(partial),
                    '--output-format', 'human-readable-text'], check=True)
    info.update(plistlib.loads(partial.read_bytes()))
    for name in [icon_name + '.icns', 'Assets.car']:
        shutil.copy2(compiled / name, app / 'Contents/Resources' / name)
    (app / 'Contents/Resources/AppIcon.icns').unlink(missing_ok=True)
    # Retain a flattened preview for documentation; the app uses the native icon assets.
    subprocess.run(['/usr/bin/sips', '-s', 'format', 'png', str(compiled / (icon_name + '.icns')),
                    '--out', str(app / 'Contents/Resources/AppIcon.png')], check=True, stdout=subprocess.DEVNULL)
(app / 'Contents/Info.plist').write_bytes(plistlib.dumps(info))
