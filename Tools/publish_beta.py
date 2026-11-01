#!/usr/bin/env python3
"""Publish unchanged, verified Actions IPAs using the repository's Actions token."""
from __future__ import annotations

import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import shutil
import subprocess
import tempfile
import zipfile

ROOT = Path(__file__).resolve().parents[1]
REPOSITORY = "MeezaUni/Erhu-iOS"
VARIANTS = {"static": "without-animated-art", "animated": "with-animated-art"}
BUILD_PATHS = ["Erhu", "Support", "project.yml", ".github/workflows/ios.yml"]


def command(arguments, *, stdin=None):
    result = subprocess.run(arguments, input=stdin, text=True, capture_output=True, cwd=ROOT)
    if result.returncode:
        raise RuntimeError(result.stderr.strip() or result.stdout.strip() or f"{arguments[0]} failed")
    return result.stdout


def api(path, *, method="GET", data=None, missing_ok=False):
    arguments = ["gh", "api", "--method", method, path]
    if data is not None:
        arguments += ["--input", "-"]
    try:
        result = command(arguments, stdin=json.dumps(data) if data is not None else None)
    except RuntimeError as error:
        if missing_ok and re.search(r"HTTP\s+404", str(error)):
            return None
        raise
    return json.loads(result) if result.strip() else None


def annotation(kind, message):
    escaped = str(message).replace("%", "%25").replace("\r", "%0D").replace("\n", "%0A")
    print(f"::{kind}::{escaped}", flush=True)


def validate_tag(tag):
    if not re.fullmatch(r"v\d+\.\d+(?:\.\d+)?-beta(?:\.\d+)?", tag):
        raise ValueError("Use a beta tag such as v1.0-beta or v1.0.0-beta.1")
    return tag


def ensure_new_release(tag):
    if api(f"repos/{REPOSITORY}/releases/tags/{tag}", missing_ok=True) is not None:
        raise RuntimeError(f"Release {tag} already exists; existing releases will not be overwritten")
    if api(f"repos/{REPOSITORY}/git/ref/tags/{tag}", missing_ok=True) is not None:
        raise RuntimeError(f"Tag {tag} already exists; choose a new beta tag")
    releases = api(f"repos/{REPOSITORY}/releases?per_page=100")
    if any(release["tag_name"] == tag for release in releases):
        raise RuntimeError(f"A release or draft for {tag} already exists")


def choose_build(variant, branch):
    runs = api(f"repos/{REPOSITORY}/actions/workflows/ios.yml/runs"
               f"?branch={branch}&status=success&event=push&per_page=30")["workflow_runs"]
    for run in runs:
        if run["head_branch"] != branch or run["conclusion"] != "success":
            continue
        artifacts = api(f"repos/{REPOSITORY}/actions/runs/{run['id']}/artifacts?per_page=100")["artifacts"]
        available = [item for item in artifacts if item["name"] == "Erhu-ipa" and not item["expired"]]
        if not available:
            continue
        if len(available) != 1:
            raise RuntimeError(f"Expected exactly one IPA artifact for run {run['id']}")
        sha = run["head_sha"]
        if not re.fullmatch(r"[a-f0-9]{40}", sha):
            raise RuntimeError("Invalid build commit")
        command(["git", "cat-file", "-e", f"{sha}^{{commit}}"])
        # Documentation may be newer; executable code and build configuration must match.
        diff = subprocess.run(["git", "diff", "--quiet", sha, f"origin/{branch}", "--", *BUILD_PATHS], cwd=ROOT)
        if diff.returncode:
            raise RuntimeError(f"Latest available successful {variant} IPA does not match current app code; wait for a green build")
        artifact = available[0]
        artifact_sha = artifact.get("workflow_run", {}).get("head_sha", sha)
        if artifact_sha != sha:
            raise RuntimeError("Artifact commit differs from its workflow run")
        return {"variant": variant, "branch": branch, "commit": sha, "run_id": run["id"],
                "run_url": run["html_url"], "artifact_id": artifact["id"]}
    raise RuntimeError(f"No retained successful IPA artifact found for {branch}")


def inspect_ipa(path):
    with zipfile.ZipFile(path) as archive:
        names = archive.namelist()
        info_names = [name for name in names if re.fullmatch(r"Payload/[^/]+\.app/Info\.plist", name)]
        if len(info_names) != 1:
            raise RuntimeError("IPA must contain exactly one main app")
        info = plistlib.loads(archive.read(info_names[0]))
        if info.get("CFBundleIdentifier") != "com.erhu":
            raise RuntimeError("Unexpected app bundle identifier")
        executable = info.get("CFBundleExecutable", "")
        executable_path = info_names[0].rsplit("/", 1)[0] + "/" + executable
        if not executable or executable_path not in names:
            raise RuntimeError("The app executable is missing")
        if archive.testzip() is not None:
            raise RuntimeError("IPA checksum verification failed")
        return {"bundle_identifier": info["CFBundleIdentifier"],
                "app_version": info.get("CFBundleShortVersionString", "unknown"),
                "build_number": info.get("CFBundleVersion", "unknown"),
                "minimum_ios": info.get("MinimumOSVersion", "unknown")}


def prepare_assets(tag, builds, destination):
    destination.mkdir(parents=True, exist_ok=False)
    for build in builds:
        variant = build["variant"]
        with tempfile.TemporaryDirectory(prefix="erhu-ipa-") as directory:
            command(["gh", "run", "download", str(build["run_id"]), "--repo", REPOSITORY,
                     "--name", "Erhu-ipa", "--dir", directory])
            ipas = list(Path(directory).rglob("*.ipa"))
            if len(ipas) != 1:
                raise RuntimeError("Expected exactly one IPA in the downloaded artifact")
            build.update(inspect_ipa(ipas[0]))
            build["ipa"] = f"Erhu-{tag}-{variant}.ipa"
            shutil.copyfile(ipas[0], destination / build["ipa"])
        build["ipa_bytes"] = (destination / build["ipa"]).stat().st_size
        build["source"] = f"Erhu-{tag}-{variant}-source.zip"
        prefix = f"Erhu-{variant}-source/"
        source = destination / build["source"]
        command(["git", "archive", "--format=zip", f"--prefix={prefix}", f"--output={source}", build["commit"]])
        with zipfile.ZipFile(source, "a", compression=zipfile.ZIP_DEFLATED) as archive:
            if prefix + "LICENSE" not in archive.namelist():
                archive.write(ROOT / "LICENSE", prefix + "LICENSE")
    shutil.copyfile(ROOT / "LICENSE", destination / "LICENSE.txt")
    with zipfile.ZipFile(destination / "THIRD-PARTY-NOTICES.zip", "w", compression=zipfile.ZIP_DEFLATED) as archive:
        for path in sorted((ROOT / "ThirdParty").rglob("*")):
            if path.is_file():
                archive.write(path, path.relative_to(ROOT))
        archive.write(ROOT / "Erhu/Resources/Vybe/vybe-model-license.txt", "vybe-model-license.txt")
    manifest = {"tag": tag, "repository": REPOSITORY, "builds": builds,
                "source_note": "Each source archive is the built commit, with GPLv3 LICENSE included if absent."}
    (destination / "build-manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
    checksums = [f"{hashlib.sha256(path.read_bytes()).hexdigest()}  {path.name}"
                 for path in sorted(destination.iterdir()) if path.is_file()]
    (destination / "SHA256SUMS.txt").write_text("\n".join(checksums) + "\n")


def publish(tag, title, builds, assets, target):
    notes = (ROOT / "docs/releases/v1.0-beta.md").read_text()
    notes += "\n### Verified build provenance\n\n"
    notes += "These are the original IPAs from successful workflow runs. App code and build configuration match the current variant branches.\n\n"
    notes += "| Variant | App version (build) | Successful workflow | Source commit |\n| --- | --- | --- | --- |\n"
    for build in builds:
        notes += (f"| {build['variant'].title()} | {build['app_version']} ({build['build_number']}) | "
                  f"[Run {build['run_id']}]({build['run_url']}) | "
                  f"[`{build['commit'][:7]}`](https://github.com/{REPOSITORY}/tree/{build['commit']}) |\n")
    notes += "\nThe GitHub beta label is separate from the embedded app version shown above. Source archives correspond to each binary; GPLv3 text is included if absent from the original source commit.\n"
    release = api(f"repos/{REPOSITORY}/releases", method="POST", data={
        "tag_name": tag, "target_commitish": target, "name": title, "body": notes,
        "draft": True, "prerelease": True, "make_latest": "false"})
    published = False
    try:
        files = [str(path) for path in sorted(assets.iterdir()) if path.is_file()]
        command(["gh", "release", "upload", tag, "--repo", REPOSITORY, *files])
        uploaded = api(f"repos/{REPOSITORY}/releases/{release['id']}/assets?per_page=100")
        expected = {Path(path).name: Path(path).stat().st_size for path in files}
        actual = {asset["name"]: asset["size"] for asset in uploaded}
        if actual != expected:
            raise RuntimeError("Uploaded release assets do not match prepared files")
        release = api(f"repos/{REPOSITORY}/releases/{release['id']}", method="PATCH",
                      data={"draft": False, "prerelease": True, "make_latest": "false"})
        published = True
        return release["html_url"]
    finally:
        if not published:
            try:
                current = api(f"repos/{REPOSITORY}/releases/{release['id']}")
                if current["draft"]:
                    api(f"repos/{REPOSITORY}/releases/{release['id']}", method="DELETE")
            except RuntimeError as error:
                annotation("warning", f"Unable to clean up this workflow's draft release: {error}")


def apply_repository_details():
    details = json.loads((ROOT / ".github/repository-details.json").read_text())
    results = {}
    for name, action in [
        ("description", lambda: api(f"repos/{REPOSITORY}", method="PATCH", data={"description": details["description"]})),
        ("topics", lambda: api(f"repos/{REPOSITORY}/topics", method="PUT", data={"names": sorted(set(
            api(f"repos/{REPOSITORY}/topics")["names"] + details["topics"]))})),
        ("private_vulnerability_reporting", lambda: api(f"repos/{REPOSITORY}/private-vulnerability-reporting", method="PUT")),
    ]:
        try:
            action()
            results[name] = "updated"
        except RuntimeError as error:
            results[name] = f"Manual setup required: {error}"
            annotation("warning", f"{name}: {results[name]}")
    # Homepage/website and sidebar settings are deliberately not sent to the API.
    return results


def main():
    if os.environ.get("GITHUB_REPOSITORY") != REPOSITORY:
        raise RuntimeError("This publisher is configured only for MeezaUni/Erhu-iOS")
    request = json.loads((ROOT / ".github/beta-release.json").read_text())
    tag = validate_tag(os.environ.get("RELEASE_TAG") or request["tag"])
    target = os.environ["GITHUB_SHA"]
    if not re.fullmatch(r"[a-f0-9]{40}", target):
        raise RuntimeError("Invalid release target")
    ensure_new_release(tag)
    builds = [choose_build(variant, branch) for variant, branch in VARIANTS.items()]
    assets = ROOT / "build/beta-release"
    prepare_assets(tag, builds, assets)
    title = request["title"] if tag == request["tag"] else f"Erhu {tag}"
    url = publish(tag, title, builds, assets, target)
    annotation("notice", f"Published beta release: {url}")
    details = apply_repository_details()
    result = {"release_url": url, "tag": tag, "builds": builds, "repository_details": details}
    (ROOT / "build/release-result.json").write_text(json.dumps(result, indent=2) + "\n")
    print(json.dumps(result, indent=2), flush=True)
    if summary := os.environ.get("GITHUB_STEP_SUMMARY"):
        with open(summary, "a") as output:
            output.write(f"## Published beta\n\n[{title}]({url})\n\n")
            for name, status in details.items():
                output.write(f"- **{name}**: {status}\n")
            output.write("\nWebsite unchanged. Sidebar setup: see docs/REPOSITORY_SETUP.md.\n")


if __name__ == "__main__":
    try:
        main()
    except Exception as error:
        annotation("error", error)
        raise
