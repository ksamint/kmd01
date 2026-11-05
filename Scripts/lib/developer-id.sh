# shellcheck shell=bash
#
# Developer ID signing and notarization on the developer's Mac.
#
# These replace the signing steps of the retired signed-local-install.yml,
# release.yml, and finalize-release.yml workflows. Credentials come from the
# local keychain and environment, using the variable names those workflows
# used, and are never written to files, logs, or evidence:
#
#   APPLE_TEAM_ID            required; the Developer ID team.
#   APPLE_DEVELOPER_ID_SHA1  optional; picks one "Developer ID Application"
#                            identity when the keychain holds several. The
#                            identity (certificate and private key) must
#                            already be in the login keychain; nothing is
#                            imported from a .p12.
#   Notarization, one of:
#     KSAMINT_NOTARY_KEYCHAIN_PROFILE  a profile saved with
#                            `xcrun notarytool store-credentials` (keychain).
#     APPLE_NOTARY_KEY_PATH + APPLE_NOTARY_KEY_ID + APPLE_NOTARY_ISSUER_ID
#                            an App Store Connect API key file you already
#                            keep (for example
#                            ~/.appstoreconnect/private_keys/AuthKey_<ID>.p8,
#                            mode 600). With it, provisioning profiles are
#                            downloaded and xcodebuild may update them, as
#                            the workflows did. Without it, the profiles
#                            below must already be installed and Xcode must
#                            be signed in to the team.
#
# The base64 secrets the workflows decoded to disk
# (APPLE_DEVELOPER_ID_P12_BASE64, APPLE_NOTARY_KEY_P8_BASE64) are ignored.
#
# Sourced after Scripts/lib/local-evidence.sh. Step functions run inside
# le_step subshells; functions that set variables must run directly.

# Developer ID provisioning profiles, one per bundle, as bundle-id|profile-name.
# Scripts/validate-product-identity.mjs checks this list.
KSAMINT_DEVELOPER_ID_PROFILES='art.apuch.ksamint.markedit|ksamint MarkEdit Developer ID
art.apuch.ksamint.markedit.conversation-capture-helper|ksamint Capture Helper Developer ID
art.apuch.ksamint.markedit.finder-extension|ksamint Finder Extension Developer ID
art.apuch.ksamint.markedit.preview-extension|ksamint Preview Extension Developer ID
art.apuch.ksamint.markedit.quick-actions|ksamint Quick Actions Developer ID'

DI_NOTARY_ARGS=()
DI_XCODE_AUTH_ARGS=()

# Resolves the signing identity and notary credentials. Run directly (not in
# le_step): it exports APPLE_DEVELOPER_ID_SHA1 and sets the argument arrays.
di_resolve_credentials() {
  local identities matches count mode
  case "${APPLE_TEAM_ID:-}" in
    [A-Z0-9][A-Z0-9][A-Z0-9][A-Z0-9][A-Z0-9][A-Z0-9][A-Z0-9][A-Z0-9][A-Z0-9][A-Z0-9]) ;;
    *) le_die "Set APPLE_TEAM_ID to the 10-character Developer ID team." ;;
  esac
  if [ -n "${APPLE_DEVELOPER_ID_P12_BASE64:-}${APPLE_NOTARY_KEY_P8_BASE64:-}" ]; then
    echo "Ignoring APPLE_*_BASE64 variables: local builds never decode key material to disk." >&2
  fi

  identities=$(security find-identity -v -p codesigning)
  matches=$(printf '%s\n' "$identities" | grep "Developer ID Application: .*($APPLE_TEAM_ID)\"" || true)
  if [ -n "${APPLE_DEVELOPER_ID_SHA1:-}" ]; then
    matches=$(printf '%s\n' "$matches" | awk -v sha="$APPLE_DEVELOPER_ID_SHA1" '$2 == sha')
  fi
  count=$(printf '%s' "$matches" | grep -c . || true)
  if [ "$count" -ne 1 ]; then
    le_die "Expected exactly one valid 'Developer ID Application' identity for team $APPLE_TEAM_ID in the keychain, found $count. Install it in the login keychain or set APPLE_DEVELOPER_ID_SHA1."
  fi
  APPLE_DEVELOPER_ID_SHA1=$(printf '%s\n' "$matches" | awk '{print $2}')
  case "$APPLE_DEVELOPER_ID_SHA1" in
    *[!0-9A-F]*|'') le_die 'Unable to resolve Developer ID identity' ;;
  esac
  export APPLE_DEVELOPER_ID_SHA1 APPLE_TEAM_ID

  DI_XCODE_AUTH_ARGS=()
  if [ -n "${KSAMINT_NOTARY_KEYCHAIN_PROFILE:-}" ]; then
    mode=keychain-profile
    DI_NOTARY_ARGS=(--keychain-profile "$KSAMINT_NOTARY_KEYCHAIN_PROFILE")
  elif [ -n "${APPLE_NOTARY_KEY_PATH:-}" ]; then
    mode=api-key
    test -n "${APPLE_NOTARY_KEY_ID:-}" && test -n "${APPLE_NOTARY_ISSUER_ID:-}" \
      || le_die "APPLE_NOTARY_KEY_PATH also needs APPLE_NOTARY_KEY_ID and APPLE_NOTARY_ISSUER_ID."
    test -f "$APPLE_NOTARY_KEY_PATH" && test -r "$APPLE_NOTARY_KEY_PATH" \
      || le_die "APPLE_NOTARY_KEY_PATH is not a readable file."
    case "$(stat -f '%Lp' "$APPLE_NOTARY_KEY_PATH")" in
      ?00|?) ;;
      *) le_die "APPLE_NOTARY_KEY_PATH must not be readable by group or others (chmod 600)." ;;
    esac
    DI_NOTARY_ARGS=(--key "$APPLE_NOTARY_KEY_PATH" --key-id "$APPLE_NOTARY_KEY_ID" --issuer "$APPLE_NOTARY_ISSUER_ID")
    DI_XCODE_AUTH_ARGS=(-authenticationKeyPath "$APPLE_NOTARY_KEY_PATH"
      -authenticationKeyID "$APPLE_NOTARY_KEY_ID"
      -authenticationKeyIssuerID "$APPLE_NOTARY_ISSUER_ID")
  else
    le_die "Set KSAMINT_NOTARY_KEYCHAIN_PROFILE, or APPLE_NOTARY_KEY_PATH with APPLE_NOTARY_KEY_ID and APPLE_NOTARY_ISSUER_ID, for notarization."
  fi
  le_set_string signingTeam "$APPLE_TEAM_ID"
  le_set_string signingIdentitySHA1 "$APPLE_DEVELOPER_ID_SHA1"
  le_set_string notaryCredentials "$mode"
}

# Downloads the Developer ID profiles with the App Store Connect API key, as
# the workflows did. The short-lived JWT stays in memory: xtrace is off and the
# Authorization header reaches curl on stdin, never in argv or the log.
di_download_profiles() {
  { set +x; } 2>/dev/null
  local token profiles response uuid profile_name
  token="$(KEY_PATH="$APPLE_NOTARY_KEY_PATH" ruby -ropenssl -rjson -rbase64 -e '
    encode = ->(value) { Base64.urlsafe_encode64(value, padding: false) }
    now = Time.now.to_i
    header = encode.call({alg: "ES256", kid: ENV.fetch("APPLE_NOTARY_KEY_ID"), typ: "JWT"}.to_json)
    payload = encode.call({iss: ENV.fetch("APPLE_NOTARY_ISSUER_ID"), iat: now, exp: now + 600, aud: "appstoreconnect-v1"}.to_json)
    input = "#{header}.#{payload}"
    der = OpenSSL::PKey.read(File.read(ENV.fetch("KEY_PATH"))).sign(OpenSSL::Digest::SHA256.new, input)
    signature = OpenSSL::ASN1.decode(der).value.map { |part| part.value.to_s(2).rjust(32, "\0") }.join
    print "#{input}.#{encode.call(signature)}"
  ')"
  profiles="$HOME/Library/MobileDevice/Provisioning Profiles"
  mkdir -p "$profiles"
  while IFS='|' read -r _bundle_id profile_name; do
    echo "Downloading profile: $profile_name"
    response="$(printf 'Authorization: Bearer %s\n' "$token" | curl --fail --silent --show-error --get \
      -H @- \
      --data-urlencode "filter[name]=$profile_name" \
      --data-urlencode 'filter[profileType]=MAC_APP_DIRECT' \
      https://api.appstoreconnect.apple.com/v1/profiles)"
    test "$(printf '%s' "$response" | jq '.data | length')" -eq 1
    test "$(printf '%s' "$response" | jq -r '.data[0].attributes.profileState')" = ACTIVE
    uuid="$(printf '%s' "$response" | jq -r '.data[0].attributes.uuid')"
    printf '%s' "$response" | jq -r '.data[0].attributes.profileContent' | \
      base64 --decode > "$profiles/$uuid.provisionprofile"
    security cms -D -i "$profiles/$uuid.provisionprofile" > /dev/null
  done <<<"$KSAMINT_DEVELOPER_ID_PROFILES"
  unset token
}

# Verifies that every Developer ID profile is installed, belongs to the team,
# and has not expired. Downloads them first when an API key is configured.
di_install_profiles() {
  if [ -n "${APPLE_NOTARY_KEY_PATH:-}" ] && [ -z "${KSAMINT_NOTARY_KEYCHAIN_PROFILE:-}" ]; then
    di_download_profiles
    set -x
  fi
  local now decoded profile_name file name team expiry found
  now=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  decoded=$(mktemp "${TMPDIR:-/tmp}/kmd-profile.XXXXXX")
  while IFS='|' read -r _bundle_id profile_name; do
    found=false
    for file in "$HOME/Library/MobileDevice/Provisioning Profiles"/*.provisionprofile \
                "$HOME/Library/Developer/Xcode/UserData/Provisioning Profiles"/*.provisionprofile; do
      test -f "$file" || continue
      security cms -D -i "$file" > "$decoded" 2>/dev/null || continue
      name=$(plutil -extract Name raw -o - "$decoded" 2>/dev/null || true)
      test "$name" = "$profile_name" || continue
      team=$(plutil -extract TeamIdentifier.0 raw -o - "$decoded" 2>/dev/null || true)
      expiry=$(plutil -extract ExpirationDate raw -o - "$decoded" 2>/dev/null || true)
      if [ "$team" = "$APPLE_TEAM_ID" ] && [[ "$expiry" > "$now" ]]; then
        echo "Profile '$profile_name': $file (team $team, expires $expiry)"
        found=true
        break
      fi
    done
    if ! $found; then
      rm -f "$decoded"
      echo "Missing or expired Developer ID profile '$profile_name' for team $APPLE_TEAM_ID." >&2
      return 1
    fi
  done <<<"$KSAMINT_DEVELOPER_ID_PROFILES"
  rm -f "$decoded"
}

# di_archive_and_export SOURCE_DIR WORK_DIR COMMIT [BUILD_SETTING...]
# Archives the ARM64 app and exports it with the Developer ID profiles to
# WORK_DIR/export/kmd.app.
di_archive_and_export() {
  local source=$1 work=$2 commit=$3 options bundle_id profile_name
  shift 3
  cd "$source" || return
  xcodebuild archive \
    -project MarkEdit.xcodeproj \
    -scheme MarkEditMac \
    -configuration Release \
    -archivePath "$work/ksamint-MarkEdit.xcarchive" \
    -destination 'generic/platform=macOS' \
    -allowProvisioningUpdates \
    ${DI_XCODE_AUTH_ARGS[@]+"${DI_XCODE_AUTH_ARGS[@]}"} \
    ARCHS=arm64 \
    ONLY_ACTIVE_ARCH=NO \
    KSAMINT_BUILD_COMMIT="$commit" \
    DEVELOPMENT_TEAM="$APPLE_TEAM_ID" \
    "$@"
  options="$work/ExportOptions.plist"
  plutil -create xml1 "$options"
  plutil -insert method -string developer-id "$options"
  plutil -insert teamID -string "$APPLE_TEAM_ID" "$options"
  plutil -insert signingStyle -string manual "$options"
  plutil -insert signingCertificate -string "$APPLE_DEVELOPER_ID_SHA1" "$options"
  /usr/libexec/PlistBuddy -c 'Add :provisioningProfiles dict' "$options"
  while IFS='|' read -r bundle_id profile_name; do
    /usr/libexec/PlistBuddy -c "Add :provisioningProfiles:$bundle_id string $profile_name" "$options"
  done <<<"$KSAMINT_DEVELOPER_ID_PROFILES"
  xcodebuild -exportArchive \
    -archivePath "$work/ksamint-MarkEdit.xcarchive" \
    -exportPath "$work/export" \
    -exportOptionsPlist "$options"
  test -d "$work/export/kmd.app"
}

# di_notary_submit FILE OUTPUT_JSON submits once and saves Apple's response.
di_notary_submit() {
  xcrun notarytool submit "$1" "${DI_NOTARY_ARGS[@]}" --output-format json > "$2"
  local id
  id=$(jq -r '.id' "$2")
  test -n "$id" && test "$id" != null
  echo "Notary submission for $(basename "$1"): $id"
}

# di_notary_status ID prints Accepted, In Progress, Invalid, or Rejected.
di_notary_status() {
  xcrun notarytool info "$1" "${DI_NOTARY_ARGS[@]}" --output-format json | jq -r '.status'
}

# di_notary_wait ID LOG_FILE [TIMEOUT_SECONDS] polls until Apple accepts the
# submission; Invalid, Rejected, or a timeout fails.
di_notary_wait() {
  local id=$1 log=$2 deadline status
  deadline=$(( $(date +%s) + ${3:-1800} ))
  while true; do
    if status=$(di_notary_status "$id"); then
      echo "Notary status for $id: $status"
      case "$status" in
        Accepted) return 0 ;;
        Invalid|Rejected)
          xcrun notarytool log "$id" "${DI_NOTARY_ARGS[@]}" "$log" || true
          return 1 ;;
      esac
    else
      echo 'Transient notary status request failure; retrying.' >&2
    fi
    if [ "$(date +%s)" -ge "$deadline" ]; then
      echo "Timed out waiting for notarization: $id" >&2
      return 1
    fi
    sleep 30
  done
}
