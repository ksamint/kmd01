#!/usr/bin/env python3
"""Compile the actual document read/write and Save All bodies with non-UI doubles."""
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parent.parent


def method(source: str, signature: str) -> str:
    start = source.index("  " + signature)
    # These Swift methods end at class-body indentation, including nested closures.
    end = source.index("\n  }", start) + len("\n  }")
    return source[start:end]


def check_readiness(document_source: str) -> None:
    controller = (ROOT / "MarkEditMac/Sources/Main/AppDocumentController.swift").read_text()
    harness = (ROOT / "Scripts/DocumentReadinessTestMain.swift").read_text()
    for marker, source, signature in [
        ("DOCUMENT_READ", document_source, "override func read(from data: Data, ofType typeName: String) throws {"),
        ("DOCUMENT_DATA", document_source, "override func data(ofType typeName: String) throws -> Data {"),
        ("SAVE_ALL", controller, "override func saveAllDocuments(_ sender: Any?) {"),
    ]:
        harness = harness.replace("  // " + marker, method(source, signature))
    with tempfile.TemporaryDirectory(prefix="kmd-document-readiness-") as temporary:
        source = Path(temporary) / "Readiness.swift"
        binary = Path(temporary) / "readiness"
        source.write_text(harness)
        subprocess.run(
            ["swiftc", "-swift-version", "6", "-parse-as-library", str(source), "-o", str(binary)],
            check=True, timeout=60,
        )
        subprocess.run([str(binary)], check=True, timeout=10)


if __name__ == "__main__":
    check_readiness((ROOT / "MarkEditMac/Sources/Editor/Models/EditorDocument.swift").read_text())
