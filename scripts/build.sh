#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
swift build --build-system native -c release
task_app="$PWD/dist/澄观.app"
mkdir -p "$task_app/Contents/MacOS" "$task_app/Contents/Resources"
cp .build/release/Chengguan "$task_app/Contents/MacOS/Chengguan"
if [[ -d .build/release/VitalsReplica_VitalsReplica.bundle ]]; then
  cp -R .build/release/VitalsReplica_VitalsReplica.bundle "$task_app/Contents/Resources/"
fi
cp Vendor/Stats-LICENSE "$task_app/Contents/Resources/Stats-LICENSE.txt"
cp Vendor/m1ddc-LICENSE "$task_app/Contents/Resources/m1ddc-LICENSE.txt"
cp THIRD_PARTY_NOTICES.md "$task_app/Contents/Resources/THIRD_PARTY_NOTICES.md"
python3 scripts/make_bundle.py "$task_app"
# Use ad-hoc signing for local builds. Set a stable Developer ID identity for distribution.
task_identity="${CHENGGUAN_SIGN_IDENTITY:--}"
if [[ "$task_identity" == "-" ]]; then
  codesign --force --sign - "$task_app"
else
  codesign --force --options runtime --timestamp --sign "$task_identity" "$task_app"
fi
codesign --verify --deep --strict "$task_app"
print "Built: $task_app"
