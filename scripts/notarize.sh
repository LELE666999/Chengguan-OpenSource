#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
# Configure once with: xcrun notarytool store-credentials PROFILE
# Credentials remain in the macOS Keychain. Supply only the profile name here.
: "${CHENGGUAN_NOTARY_PROFILE:?Set CHENGGUAN_NOTARY_PROFILE to an existing notarytool Keychain profile name}"
task_app="$PWD/dist/澄观.app"
task_archive="$PWD/dist/Chengguan-notarization.zip"
codesign --verify --deep --strict --verbose=2 "$task_app"
if ! codesign -dv "$task_app" 2>&1 | /usr/bin/grep -q 'Authority=Developer ID Application:'; then
  print -u2 'Build with a Developer ID Application identity before notarizing.'
  exit 1
fi
/usr/bin/ditto -c -k --keepParent "$task_app" "$task_archive"
# Submission is asynchronous; this avoids a long blocking wait and preserves the submission ID.
xcrun notarytool submit "$task_archive" --keychain-profile "$CHENGGUAN_NOTARY_PROFILE" --output-format json > "$PWD/dist/notarization-submission.json"
print 'Submitted. Read dist/notarization-submission.json for the ID.'
print 'Check with: xcrun notarytool info ID --keychain-profile PROFILE'
print 'After Accepted: xcrun stapler staple dist/澄观.app && xcrun stapler validate dist/澄观.app'
