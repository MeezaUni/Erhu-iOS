import importlib.util
import json
from pathlib import Path
import plistlib
from types import SimpleNamespace
import tempfile
import unittest
from unittest.mock import patch
import zipfile

SPEC = importlib.util.spec_from_file_location("publish_beta", Path(__file__).parents[1] / "publish_beta.py")
publisher = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(publisher)


def fixture_ipa(path, identifier="com.erhu"):
    info = {"CFBundleIdentifier": identifier, "CFBundleExecutable": "Erhu",
            "CFBundleShortVersionString": "0.1.0", "CFBundleVersion": "1", "MinimumOSVersion": "17.0"}
    with zipfile.ZipFile(path, "w") as archive:
        archive.writestr("Payload/Erhu.app/Info.plist", plistlib.dumps(info))
        archive.writestr("Payload/Erhu.app/Erhu", b"fixture executable")


class PublisherTests(unittest.TestCase):
    def test_existing_release_is_never_modified(self):
        with patch.object(publisher, "api", return_value={"id": 10}) as api:
            with self.assertRaisesRegex(RuntimeError, "will not be overwritten"):
                publisher.ensure_new_release("v1.0-beta")
        self.assertEqual(api.call_count, 1)

    def test_tags_reject_paths_and_shell_syntax(self):
        self.assertEqual(publisher.validate_tag("v1.0-beta"), "v1.0-beta")
        for value in ["../main", "v1.0-beta;echo nope", "main", "v1.0-beta\n", "v1.0"]:
            with self.subTest(value=value), self.assertRaises(ValueError):
                publisher.validate_tag(value)

    def test_latest_retained_successful_artifact_is_selected(self):
        runs = [{"id": i, "head_branch": "without-animated-art", "conclusion": "success",
                 "head_sha": "a" * 40, "html_url": f"https://example.test/{i}"} for i in [11, 10]]
        responses = [{"workflow_runs": runs}, {"artifacts": [{"name": "Erhu-ipa", "expired": True, "id": 2}]},
                     {"artifacts": [{"name": "Erhu-ipa", "expired": False, "id": 1}]}]
        with patch.object(publisher, "api", side_effect=responses), patch.object(publisher, "command"), \
                patch.object(publisher.subprocess, "run", return_value=SimpleNamespace(returncode=0)):
            build = publisher.choose_build("static", "without-animated-art")
        self.assertEqual(build["run_id"], 10)
        self.assertEqual(build["artifact_id"], 1)

    def test_stale_binary_cannot_be_released_for_changed_app_code(self):
        run = {"id": 10, "head_branch": "with-animated-art", "conclusion": "success",
               "head_sha": "a" * 40, "html_url": "https://example.test/10"}
        responses = [{"workflow_runs": [run]}, {"artifacts": [{"name": "Erhu-ipa", "expired": False, "id": 1}]}]
        with patch.object(publisher, "api", side_effect=responses), patch.object(publisher, "command"), \
                patch.object(publisher.subprocess, "run", return_value=SimpleNamespace(returncode=1)):
            with self.assertRaisesRegex(RuntimeError, "does not match current app code"):
                publisher.choose_build("animated", "with-animated-art")

    def test_wrong_app_in_an_ipa_is_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "sample.ipa"
            fixture_ipa(path)
            self.assertEqual(publisher.inspect_ipa(path)["app_version"], "0.1.0")
            fixture_ipa(path, identifier="other.app")
            with self.assertRaisesRegex(RuntimeError, "bundle identifier"):
                publisher.inspect_ipa(path)

    def test_assets_keep_binaries_and_include_sources_licences_and_checksums(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "LICENSE").write_text("GPLv3 fixture")
            (root / "ThirdParty").mkdir()
            (root / "ThirdParty/NOTICE.md").write_text("fixture notice")
            (root / "Erhu/Resources/Vybe").mkdir(parents=True)
            (root / "Erhu/Resources/Vybe/vybe-model-license.txt").write_text("Apache fixture")

            def command(args, **kwargs):
                if args[:3] == ["gh", "run", "download"]:
                    fixture_ipa(Path(args[-1]) / "Erhu.ipa")
                elif args[:2] == ["git", "archive"]:
                    destination = next(value.split("=", 1)[1] for value in args if value.startswith("--output="))
                    prefix = next(value.split("=", 1)[1] for value in args if value.startswith("--prefix="))
                    with zipfile.ZipFile(destination, "w") as archive:
                        archive.writestr(prefix + "project.yml", "fixture source")
                else:
                    self.fail(f"Unexpected command: {args}")

            builds = [{"variant": name, "run_id": i, "commit": "a" * 40} for i, name in enumerate(["static", "animated"])]
            destination = root / "assets"
            with patch.object(publisher, "ROOT", root), patch.object(publisher, "command", side_effect=command):
                publisher.prepare_assets("v1.0-beta", builds, destination)
            self.assertEqual(len(list(destination.iterdir())), 8)
            self.assertEqual(len((destination / "SHA256SUMS.txt").read_text().splitlines()), 7)
            for build in builds:
                with zipfile.ZipFile(destination / build["source"]) as archive:
                    self.assertIn(f"Erhu-{build['variant']}-source/LICENSE", archive.namelist())
                self.assertEqual(publisher.inspect_ipa(destination / build["ipa"])["bundle_identifier"], "com.erhu")

    def test_upload_mismatch_keeps_release_unpublished_and_removes_own_draft(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "docs/releases").mkdir(parents=True)
            (root / "docs/releases/v1.0-beta.md").write_text("Beta notes")
            assets = root / "assets"
            assets.mkdir()
            (assets / "example.ipa").write_bytes(b"fixture")
            calls = []

            def api(path, *, method="GET", data=None, **kwargs):
                calls.append((path, method, data))
                if method == "POST":return {"id": 42, "draft": True}
                if "/assets?" in path:return []
                if method == "DELETE":return None
                if method == "GET":return {"id": 42, "draft": True}
                self.fail("An incomplete draft must never be published")

            with patch.object(publisher, "ROOT", root), patch.object(publisher, "api", side_effect=api), \
                    patch.object(publisher, "command"):
                with self.assertRaisesRegex(RuntimeError, "assets do not match"):
                    publisher.publish("v1.0-beta", "Beta", [], assets, "a" * 40)
            self.assertTrue(any(method == "DELETE" and path.endswith("/42") for path, method, _ in calls))
            self.assertFalse(any(method == "PATCH" for _, method, _ in calls))

    def test_repository_details_preserve_website_and_existing_topics(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / ".github").mkdir()
            (root / ".github/repository-details.json").write_text(json.dumps({"description": "Erhu", "topics": ["ios"]}))
            calls = []

            def api(path, *, method="GET", data=None, **kwargs):
                calls.append((path, method, data))
                return {"names": ["existing"]} if method == "GET" else None

            with patch.object(publisher, "ROOT", root), patch.object(publisher, "api", side_effect=api):
                result = publisher.apply_repository_details()
            self.assertTrue(all(status == "updated" for status in result.values()))
            patches = [data for _, method, data in calls if method == "PATCH"]
            self.assertEqual(patches, [{"description": "Erhu"}])
            topics = [data for path, method, data in calls if path.endswith("/topics") and method == "PUT"]
            self.assertEqual(topics, [{"names": ["existing", "ios"]}])


if __name__ == "__main__":
    unittest.main()
