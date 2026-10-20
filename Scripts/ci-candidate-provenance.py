#!/usr/bin/env python3
"""Validate existing stapled draft bytes; never prepare or modify a release."""
import hashlib
import json
from pathlib import Path
import re
import sys

TEAM_ID = "A64LJ32AZT"


def require(condition, message):
    if not condition:
        raise ValueError(message)


def validate(tag, release, metadata, checksums, dmg):
    require(re.fullmatch(r"v[0-9]+\.[0-9]+\.[0-9]+", tag), "Invalid candidate tag")
    require(release.get("isDraft") is True and release.get("tagName") == tag,
            "Candidate must be the requested existing draft")
    require(metadata.get("schema") == 1 and metadata.get("tag") == tag,
            "Notarization metadata tag/schema mismatch")
    commit = metadata.get("commit", "")
    require(isinstance(commit, str) and re.fullmatch(r"[0-9a-f]{40}", commit),
            "Candidate needs an exact commit")
    require(metadata.get("teamID") == TEAM_ID, "Unexpected signing team")
    asset = f"ksamint-MarkEdit-{tag[1:]}.dmg"
    require(metadata.get("dmg", {}).get("asset") == asset and dmg.name == asset,
            "Candidate DMG name mismatch")
    digest = metadata["dmg"].get("stapledSHA256", "")
    require(isinstance(digest, str) and re.fullmatch(r"[0-9a-f]{64}", digest),
            "Candidate has no recorded stapled DMG hash")
    matches = []
    for line in checksums.splitlines():
        match = re.fullmatch(r"([0-9a-f]{64}) [ *](.+)", line)
        require(match is not None, "Malformed SHA256SUMS")
        if match[2] == asset:
            matches.append(match[1])
    require(matches == [digest], "Candidate checksum missing, duplicate, or mismatched")
    require(hashlib.sha256(dmg.read_bytes()).hexdigest() == digest,
            "Downloaded DMG differs from recorded stapled bytes")
    return {"tag": tag, "commit": commit, "asset": asset, "sha256": digest, "teamID": TEAM_ID}


if __name__ == "__main__":
    try:
        tag, directory = sys.argv[1:]
        root = Path(directory)
        # Validate the tag before constructing any path from it.
        require(re.fullmatch(r"v[0-9]+\.[0-9]+\.[0-9]+", tag), "Invalid candidate tag")
        result = validate(
            tag, json.loads((root / "Release.json").read_text()),
            json.loads((root / "NotarySubmission.json").read_text()),
            (root / "SHA256SUMS").read_text(), root / f"ksamint-MarkEdit-{tag[1:]}.dmg",
        )
        print(json.dumps(result, sort_keys=True))
    except (ValueError, KeyError, TypeError, OSError) as error:
        sys.exit(str(error))
