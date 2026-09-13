#!/bin/zsh
set -euo pipefail

mori_project_dir="$(cd "$(dirname "$0")" && pwd)"
mori_build_dir="${TMPDIR:-/tmp}/MoriPhotos-Run"
mori_device_id="1FA174E3-E7E9-4CC3-9F0D-358F16EEE457"
mori_developer_dir="$(xcode-select -p)"
mori_device_hub="${mori_developer_dir%/Developer}/Applications/DeviceHub.app"
mori_classic_simulator="${mori_developer_dir}/Applications/Simulator.app"

trap 'print "启动未完成，请查看上方具体错误。"; read "?按回车关闭…"' ERR

# Reuse the dedicated simulator created for this project; do not erase devices.
if ! xcrun simctl list devices available -j | /usr/bin/python3 -c 'import json,sys; target=sys.argv[1]; sys.exit(0 if any(d["udid"] == target for v in json.load(sys.stdin)["devices"].values() for d in v) else 1)' "$mori_device_id"; then
    print "未找到本项目的 MoriPhotos QA 模拟器。请在 Device Hub 中创建 iPhone 模拟器后，将此脚本中的 mori_device_id 更新为对应 UDID。"
    exit 1
fi

if ! xcrun simctl list devices booted -j | /usr/bin/python3 -c 'import json,sys; target=sys.argv[1]; sys.exit(0 if any(d["udid"] == target for v in json.load(sys.stdin)["devices"].values() for d in v) else 1)' "$mori_device_id"; then
    xcrun simctl boot "$mori_device_id"
fi
xcrun simctl bootstatus "$mori_device_id" -b
xcodebuild -project "$mori_project_dir/MoriPhotos.xcodeproj" -scheme MoriPhotos \
    -destination "platform=iOS Simulator,id=$mori_device_id" \
    -derivedDataPath "$mori_build_dir" CODE_SIGNING_ALLOWED=NO build
xcrun simctl install "$mori_device_id" "$mori_build_dir/Build/Products/Debug-iphonesimulator/MoriPhotos.app"
xcrun simctl launch --terminate-running-process "$mori_device_id" dev.kylon.MoriPhotos

if [[ -d "$mori_device_hub" ]]; then
    open "$mori_device_hub"
    print "森空间已启动。在 Device Hub 中选择 MoriPhotos QA 查看并操作。"
elif [[ -d "$mori_classic_simulator" ]]; then
    open "$mori_classic_simulator" --args -CurrentDeviceUDID "$mori_device_id"
else
    print "App 已在模拟器启动，但没有找到 Device Hub 或 Simulator 窗口应用。"
fi
