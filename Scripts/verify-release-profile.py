#!/usr/bin/env python3
"""Compare a signed component with its source entitlements and Apple profile."""
import datetime
import fnmatch
import plistlib
import sys


def require(condition, message):
    if not condition:
        raise ValueError(message)


def validate(profile, signed, source, bundle_id, team, now=None):
    now = now or datetime.datetime.now(datetime.timezone.utc)
    expiry = profile["ExpirationDate"]
    if expiry.tzinfo is None:
        expiry = expiry.replace(tzinfo=datetime.timezone.utc)
    require(expiry > now, "Provisioning profile expired")
    require(profile.get("TeamIdentifier") == [team], "Profile Team ID mismatch")
    require(profile.get("ProvisionsAllDevices") is True, "Not a Developer ID distribution profile")
    allowed = profile["Entitlements"]
    identity = f"{team}.{bundle_id}"
    require(signed.get("com.apple.application-identifier") == identity, "Signed bundle identity mismatch")
    require(allowed.get("com.apple.application-identifier") == identity, "Profile bundle identity mismatch")
    require(signed.get("com.apple.developer.team-identifier") == team, "Signed Team ID mismatch")
    require(not signed.get("com.apple.security.get-task-allow"), "Debug entitlement in release")
    require(not allowed.get("com.apple.security.get-task-allow"), "Development profile in release")
    require(allowed.get("com.apple.developer.team-identifier") == team, "Profile entitlement Team ID mismatch")
    generated = {"com.apple.application-identifier", "com.apple.developer.team-identifier",
                 "com.apple.security.get-task-allow", "keychain-access-groups"}
    require(set(signed) <= set(source) | generated, "Unexpected signed entitlement absent from source")
    for key, expected in source.items():
        if isinstance(expected, list):
            expected = [v.replace("$(AppIdentifierPrefix)", team + ".") for v in expected]
        require(signed.get(key) == expected, f"Source/signature mismatch: {key}")
    for key in ("com.apple.security.application-groups", "keychain-access-groups"):
        for value in signed.get(key, []):
            grants = allowed.get(key, [])
            if key == "com.apple.security.application-groups":
                require(value in grants, f"Profile does not explicitly authorize app group: {value}")
            else:
                require(any(fnmatch.fnmatchcase(value, grant) for grant in grants), f"Profile denies {key}")


if __name__ == "__main__":
    profile_path, signed_path, source_path, bundle_id, team = sys.argv[1:]
    with open(profile_path, "rb") as f:
        profile = plistlib.load(f)
    with open(signed_path, "rb") as f:
        signed = plistlib.load(f)
    with open(source_path, "rb") as f:
        source = plistlib.load(f)
    validate(profile, signed, source, bundle_id, team)
    print(f"Verified profile and entitlements: {bundle_id}")
