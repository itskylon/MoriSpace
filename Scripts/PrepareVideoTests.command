#!/bin/zsh
set -eu
script_dir="${0:A:h}"
simulator_id="${1:-1FA174E3-E7E9-4CC3-9F0D-358F16EEE457}"
fixture_dir="$(mktemp -d -t mori-video-test)"
trap 'rm -rf "$fixture_dir"' EXIT
swift "$script_dir/GenerateVideoFixture.swift" "$fixture_dir/stream-test.mp4"
app_data="$(xcrun simctl get_app_container "$simulator_id" dev.kylon.MoriPhotos data)"
mkdir -p "$app_data/Documents"
cp "$fixture_dir/stream-test.mp4" "$app_data/Documents/MoriVideoTestFixture.mp4"
print 'Synthetic fixture installed in simulator app data.'
