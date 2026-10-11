#!/usr/bin/env python3
"""Package one committed source snapshot, with release metadata and checksums."""
import argparse
import gzip
import hashlib
import io
import json
from pathlib import Path, PurePosixPath
import re
import shutil
import subprocess
import tarfile
import tempfile
import zipfile


REPO = Path(__file__).resolve().parents[1]
REQUIRED = {
    "README.md", "LICENSE", "PRIVACY.md",
    "ThirdPartyNotices.md", "ThirdPartyLicenses/imsg.txt",
    "Package.swift", "docs/install.md", "docs/use.md", "docs/local-models.md",
    "docs/phone-models.md", "docs/read-access.md",
}
PRIVATE_NAMES = {
    "control-chat-id.txt", "model-profile.txt", "self-handles.json", "source-access.json",
    "conversation-history.json", "conversation-inbox.json", "outbound-ledger.json",
    "cursors.json", "phone-pairing.png", "host.lock", ".cli.history.json",
}
EXCLUDED_PARTS = {
    ".git", ".build", ".swiftpm", ".codex", "__pycache__", "xcuserdata",
    "DerivedData", "DerivedDataDevice", "DerivedDataUITest",
}
EXCLUDED_SUFFIXES = (
    ".sqlite", ".sqlite-shm", ".sqlite-wal", ".db", ".pem", ".key", ".p12",
    ".mobileprovision", ".gguf", ".safetensors", ".dylib", ".xcuserstate",
    ".lpa-context", ".log",
)
SECRET_PATTERNS = [
    re.compile(rb"-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY-----(?:\r?\n|\\n)[A-Za-z0-9+/=]{32,}"),
    re.compile(rb"\bgh[pousr]_[A-Za-z0-9]{30,}\b"),
    re.compile(rb"\bgithub_pat_[A-Za-z0-9_]{30,}\b"),
    re.compile(rb"\bAKIA[A-Z0-9]{16}\b"),
]
FIXTURE_EMAIL = re.compile(rb"\b[A-Za-z0-9_.+%-]+@([A-Za-z0-9.-]+\.[A-Za-z]{2,})\b")
FIXTURE_PHONE = re.compile(rb"(?<![0-9])\+[1-9][0-9]{9,14}(?![0-9])")


def inspect_fixture(path, content):
    """Keep contact fixtures on reserved addresses and fictional number ranges."""
    if not str(path).startswith("Tests/"):
        return
    for match in FIXTURE_EMAIL.finditer(content):
        domain = match.group(1).lower()
        if domain not in (b"example.invalid", b"example.test", b"example.com"):
            raise ValueError(f"Non-example email address in fixture: {path}")
    for match in FIXTURE_PHONE.finditer(content):
        number = match.group()
        if not re.fullmatch(rb"(?:\+1[0-9]{3}55501[0-9]{2}|\+442079460[0-9]{3})", number):
            raise ValueError(f"Non-fictional phone number in fixture: {path}")


def git(*args):
    return subprocess.check_output(["git", "-C", str(REPO), *args], stderr=subprocess.PIPE)


def inspect_archive(data, version, prefix):
    """Validate exactly the content that will be published, not local working files."""
    files = {}
    with tarfile.open(fileobj=io.BytesIO(data)) as archive:
        for member in archive:
            if member.isdir() and member.name == prefix.rstrip("/"):
                continue
            if not member.name.startswith(prefix):
                raise ValueError("Archive path outside release root")
            path = PurePosixPath(member.name[len(prefix):])
            if path.is_absolute() or ".." in path.parts:
                raise ValueError("Unsafe archive path")
            if member.isdir():
                continue
            if not member.isfile():
                raise ValueError(f"Release contains a non-source entry: {path}")
            if (set(path.parts) & EXCLUDED_PARTS or path.name in PRIVATE_NAMES
                    or str(path).endswith(EXCLUDED_SUFFIXES)
                    or any(part.endswith((".app", ".framework", ".xcframework")) for part in path.parts)
                    or (path.name.startswith(".env") and path.name != ".env.example")):
                raise ValueError(f"Release contains runtime data or a binary payload: {path}")
            content = archive.extractfile(member).read()
            if any(pattern.search(content) for pattern in SECRET_PATTERNS):
                # Print the location only; never print the matched credential.
                raise ValueError(f"Possible credential in release file: {path}")
            inspect_fixture(path, content)
            files[str(path)] = content
    missing = REQUIRED - files.keys()
    if missing:
        raise ValueError("Missing release files: " + ", ".join(sorted(missing)))
    for name, content in files.items():
        if not name.endswith(".md"):
            continue
        for target in re.findall(r"!?\[[^\]]*\]\(([^\s)]+)(?:\s+[^)]*)?\)", content.decode("utf-8")):
            if re.match(r"[a-zA-Z][a-zA-Z0-9+.-]*:", target) or target.startswith("#"):
                continue
            target = target.split("#", 1)[0]
            local = PurePosixPath(name).parent / target
            # Normalize ../ without accessing or following the local filesystem.
            parts = []
            for part in local.parts:
                if part == "..":
                    if not parts:
                        raise ValueError(f"Link leaves release root in {name}")
                    parts.pop()
                elif part != ".":
                    parts.append(part)
            resolved = "/".join(parts)
            if resolved not in files and not any(p.startswith(resolved + "/") for p in files):
                raise ValueError(f"Broken source link in {name}: {target}")
    return files


def package(version, ref, output):
    if not re.fullmatch(r"v\d+\.\d+\.\d+(?:-[A-Za-z0-9]+(?:\.[A-Za-z0-9]+)*)?", version):
        raise ValueError("Use a snapshot label such as v0.0.0")
    output = Path(output).absolute()
    if output.exists() or output.is_symlink():
        raise ValueError("Output already exists; choose a new directory")
    commit = git("rev-parse", "--verify", "--end-of-options", f"{ref}^{{commit}}").decode().strip()
    tree = git("ls-tree", "-r", "--format=%(objectmode)", commit).decode().splitlines()
    if any(mode not in ("100644", "100755") for mode in tree):
        raise ValueError("Source release cannot contain symlinks or submodules")
    stem = f"local-proactive-assistant-{version}"
    prefix = stem + "/"
    tar_data = git("archive", "--format=tar", f"--prefix={prefix}", commit)
    files = inspect_archive(tar_data, version, prefix)
    zip_data = git("archive", "--format=zip", f"--prefix={prefix}", commit)
    with zipfile.ZipFile(io.BytesIO(zip_data)) as archive:
        zip_files = {p.filename[len(prefix):]: archive.read(p) for p in archive.infolist() if not p.is_dir()}
    if zip_files != files:
        raise ValueError("ZIP and tar source contents differ")
    output.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix=".source-release-", dir=output.parent) as temporary:
        staging = Path(temporary) / "assets"
        staging.mkdir()
        (staging / (stem + ".zip")).write_bytes(zip_data)
        with (staging / (stem + ".tar.gz")).open("wb") as raw:
            with gzip.GzipFile(filename="", mode="wb", fileobj=raw, mtime=0) as compressed:
                compressed.write(tar_data)
        (staging / "release.json").write_text(json.dumps({
            "version": version, "commit": commit, "kind": "source", "file_count": len(files),
        }, indent=2) + "\n")
        checksums = []
        for asset in sorted(staging.iterdir()):
            checksums.append(f"{hashlib.sha256(asset.read_bytes()).hexdigest()}  {asset.name}\n")
        (staging / "SHA256SUMS").write_text("".join(checksums))
        # Do not replace an output created after the initial check.
        output.mkdir()
        try:
            for asset in staging.iterdir():
                shutil.copyfile(asset, output / asset.name)
        except Exception:
            shutil.rmtree(output)
            raise
    return commit, len(files)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("version")
    parser.add_argument("--ref", default="HEAD")
    parser.add_argument("--output", required=True)
    args = parser.parse_args()
    try:
        commit, count = package(args.version, args.ref, args.output)
    except (ValueError, OSError, subprocess.CalledProcessError) as error:
        parser.exit(1, f"Source release failed: {error}\n")
    print(f"Packaged {count} source files from {commit} in {args.output}")


if __name__ == "__main__":
    main()
