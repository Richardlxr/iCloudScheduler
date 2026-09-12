#!/usr/bin/env python3
"""Generate and sign the universal release feed. Signing secrets stay in Keychain."""
from pathlib import Path
import datetime
import email.utils
import plistlib
import re
import subprocess
import sys
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parents[1]
SPARKLE = "http://www.andymatuschak.org/xml-namespaces/sparkle"
ET.register_namespace("sparkle", SPARKLE)
TOOLS = ROOT / ".build/artifacts/sparkle/Sparkle/bin"
ACCOUNT = "dev.icloudscheduler.updates"


def run(*args):
    return subprocess.check_output([str(a) for a in args], text=True).strip()


def main():
    app = ROOT / "dist/iCloudScheduler.app"
    info = plistlib.loads((app / "Contents/Info.plist").read_bytes())
    version, build = info["CFBundleShortVersionString"], info["CFBundleVersion"]
    if not re.fullmatch(r"\d+\.\d+\.\d+", version) or not build.isdecimal():
        raise ValueError("Stable version and monotonically increasing numeric build required")
    arch = run("lipo", "-archs", app / "Contents/MacOS/iCloudScheduler")
    if set(arch.split()) != {"arm64", "x86_64"}:
        raise ValueError("Public updates must support both Intel and Apple Silicon")
    public_key = run(TOOLS / "generate_keys", "--account", ACCOUNT, "-p")
    if public_key != info["SUPublicEDKey"]:
        raise ValueError("Keychain signing key does not match the bundled update public key")
    archive = ROOT / f"dist/iCloudScheduler-{version}-macos-universal.dmg"
    notes = ROOT / f"docs/releases/v{version}.md"
    if not archive.is_file() or not notes.is_file():
        raise ValueError("Package the release and write release notes before signing")
    signature = run(TOOLS / "sign_update", "--account", ACCOUNT, "-p", archive)
    feed = ET.Element("rss", version="2.0")
    channel = ET.SubElement(feed, "channel")
    ET.SubElement(channel, "title").text = "iCloudScheduler"
    item = ET.SubElement(channel, "item")
    ET.SubElement(item, "title").text = f"iCloudScheduler {version}"
    ET.SubElement(item, "link").text = f"https://github.com/Richardlxr/iCloudScheduler/releases/tag/v{version}"
    ET.SubElement(item, "pubDate").text = email.utils.format_datetime(datetime.datetime.now(datetime.timezone.utc))
    ET.SubElement(item, f"{{{SPARKLE}}}version").text = build
    ET.SubElement(item, f"{{{SPARKLE}}}shortVersionString").text = version
    ET.SubElement(item, f"{{{SPARKLE}}}minimumSystemVersion").text = info["LSMinimumSystemVersion"]
    ET.SubElement(item, "description", {f"{{{SPARKLE}}}format": "plain-text"}).text = notes.read_text()
    ET.SubElement(item, "enclosure", {
        "url": f"https://github.com/Richardlxr/iCloudScheduler/releases/download/v{version}/{archive.name}",
        "type": "application/octet-stream", "length": str(archive.stat().st_size),
        f"{{{SPARKLE}}}edSignature": signature,
    })
    output = ROOT / "dist/appcast.xml"
    ET.indent(feed)
    ET.ElementTree(feed).write(output, encoding="utf-8", xml_declaration=True)
    run(TOOLS / "sign_update", "--account", ACCOUNT, output)
    run(TOOLS / "sign_update", "--account", ACCOUNT, "--verify", output)
    run(TOOLS / "sign_update", "--account", ACCOUNT, "--verify", archive, signature)
    print(f"Signed and verified update {version} (build {build}): {output}")


if __name__ == "__main__":
    try:
        main()
    except (ValueError, OSError, subprocess.CalledProcessError) as error:
        sys.exit(str(error))
