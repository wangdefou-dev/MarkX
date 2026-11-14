import html
import json
import plistlib
import re
import sys
from pathlib import Path


app = Path(__file__).resolve().parent.parent
website = Path(sys.argv[1])
with (app / "Config/Info.plist").open("rb") as plist:
    info = plistlib.load(plist)
version = info["CFBundleShortVersionString"]
build = info["CFBundleVersion"]

changelog = (app / "CHANGELOG.md").read_text(encoding="utf-8")
sections = re.split(r"^## ", changelog, flags=re.MULTILINE)
section = next((s for s in sections if s.splitlines()[0] == f"{version} 更新"), "")
notes = [line[2:] for line in section.splitlines() if line.startswith("- ")]
if not notes:
    sys.exit(f"No changelog bullets for MarkX {version}.")

source_path = website / "src/App.tsx"
source = source_path.read_text(encoding="utf-8")
current_version = re.search(r"^const APP_VERSION = '([0-9.]+)';$", source, re.MULTILINE)
current_build = re.search(r"^const BUILD_NUMBER = '([0-9]+)';$", source, re.MULTILINE)
if not current_version or not current_build:
    sys.exit("Could not find the current website version and build.")

version_parts = lambda value: tuple(map(int, value.split(".")))
if version_parts(current_version[1]) > version_parts(version) or int(current_build[1]) > int(build):
    sys.exit(f"Website already lists a newer release ({current_version[1]} / {current_build[1]}).")
if current_version[1] == version and current_build[1] != build:
    sys.exit("Website already lists this version with a different build.")

if current_version[1] != version:
    source = source.replace(current_version[0], f"const APP_VERSION = '{version}';")
    source = source.replace(current_build[0], f"const BUILD_NUMBER = '{build}';")
    # Escape JSX text, including braces that would otherwise become expressions.
    escaped_notes = [html.escape(note).replace("{", "&#123;").replace("}", "&#125;") for note in notes]
    note_rows = "\n".join(f'            <p className="release-note">{note}</p>' for note in escaped_notes)
    source, matches = re.subn(
        r'^[ \t]*<p className="release-note">.*?</p>(?:\n[ \t]*<p className="release-note">.*?</p>)*',
        lambda _: note_rows,
        source,
        flags=re.MULTILINE | re.DOTALL,
    )
    if matches != 1:
        sys.exit("Expected exactly one block of release notes on the website.")

    readme_path = website / "README.md"
    readme = readme_path.read_text(encoding="utf-8")
    old = current_version[1]
    readme = readme.replace(f"download.markx.defou.ai/{old}/MarkX-{old}.dmg", f"download.markx.defou.ai/{version}/MarkX-{version}.dmg")
    readme = readme.replace(f"/downloads/markx/{old}/SHA256SUMS.txt", f"/downloads/markx/{version}/SHA256SUMS.txt")
    readme_path.write_text(readme, encoding="utf-8")

checksum = (Path(sys.argv[2]) / "SHA256SUMS.txt").read_text(encoding="utf-8").split()[0]
receipt = json.dumps({"version": version, "build": build, "sha256": checksum}) + "\n"
source_path.write_text(source, encoding="utf-8")
(website / "public/release.json").write_text(receipt, encoding="utf-8")
