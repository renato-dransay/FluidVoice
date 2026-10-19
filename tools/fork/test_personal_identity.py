"""Guards the personal app identity in the Xcode project.

An upstream merge can auto-merge the project file cleanly while leaving a second copy of
PRODUCT_BUNDLE_IDENTIFIER, PRODUCT_NAME or MARKETING_VERSION inside the app's build
configurations. Xcode keeps the later (upstream) copy, so the build silently turns back into
the official app. These tests fail on that state before anything is built.
"""

from pathlib import Path
import plistlib
import re
import unittest

ROOT = Path(__file__).resolve().parents[2]
PROJECT = ROOT / "Fluid.xcodeproj" / "project.pbxproj"
INFO_PLIST = ROOT / "Info.plist"

PERSONAL_BUNDLE_ID = "com.renatobeltrao.fluidvoice.personal"
PERSONAL_APP_NAME = "FluidVoice Personal"

CONFIGURATION = re.compile(
    r"isa = XCBuildConfiguration;\s*buildSettings = \{(?P<settings>.*?)\n\t\t\t\};\s*name = (?P<name>\w+);",
    re.DOTALL,
)
SETTING = re.compile(r"^\t\t\t\t(?P<key>[A-Za-z_][A-Za-z0-9_\[\]=*,\" -]*?) = ", re.MULTILINE)


def build_configurations(text):
    """Yields (name, settings text) for every XCBuildConfiguration in the project file."""
    for match in CONFIGURATION.finditer(text):
        yield match.group("name"), match.group("settings")


def setting_keys(settings):
    """Top-level keys of one buildSettings block, in file order, duplicates included."""
    return [match.group("key").strip() for match in SETTING.finditer(settings)]


def setting_value(settings, key):
    values = re.findall(rf"^\t\t\t\t{re.escape(key)} = (.*);$", settings, re.MULTILINE)
    return [value.strip().strip('"') for value in values]


class PersonalIdentityTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.project = PROJECT.read_text()
        cls.app_configurations = [
            (name, settings)
            for name, settings in build_configurations(cls.project)
            if setting_value(settings, "INFOPLIST_FILE") == ["Info.plist"]
        ]

    def test_app_has_debug_and_release_configurations(self):
        names = sorted(name for name, _ in self.app_configurations)
        self.assertEqual(names, ["Debug", "Release"])

    def test_no_build_configuration_repeats_a_key(self):
        for name, settings in build_configurations(self.project):
            keys = setting_keys(settings)
            duplicates = sorted({key for key in keys if keys.count(key) > 1})
            self.assertEqual(duplicates, [], f"{name} build settings repeat {duplicates}")

    def test_app_uses_personal_bundle_identifier_and_name(self):
        for name, settings in self.app_configurations:
            with self.subTest(configuration=name):
                self.assertEqual(setting_value(settings, "PRODUCT_BUNDLE_IDENTIFIER"), [PERSONAL_BUNDLE_ID])
                self.assertEqual(setting_value(settings, "PRODUCT_NAME"), ["$(FLUIDVOICE_APP_NAME)"])
                self.assertEqual(setting_value(settings, "FLUIDVOICE_APP_NAME"), [PERSONAL_APP_NAME])

    def test_marketing_version_matches_info_plist(self):
        with INFO_PLIST.open("rb") as handle:
            plist_version = plistlib.load(handle)["CFBundleShortVersionString"]
        for name, settings in self.app_configurations:
            with self.subTest(configuration=name):
                self.assertEqual(setting_value(settings, "MARKETING_VERSION"), [plist_version])

    def test_every_referenced_swift_file_exists(self):
        # A cherry-pick or merge can carry upstream-only test files into the project file without
        # the files themselves, and the build then fails with "Build input files cannot be found".
        referenced = set(re.findall(r"isa = PBXFileReference;[^}]*?path = \"?([^\";]+\.swift)\"?;", self.project))
        present = {
            path.name
            for top in ("Sources", "Tests")
            for path in (ROOT / top).rglob("*.swift")
        }
        missing = sorted(Path(name).name for name in referenced if Path(name).name not in present)
        self.assertEqual(missing, [], f"project file references missing files {missing}")

    def test_info_plist_reads_identity_from_build_settings(self):
        with INFO_PLIST.open("rb") as handle:
            plist = plistlib.load(handle)
        self.assertEqual(plist["CFBundleIdentifier"], "$(PRODUCT_BUNDLE_IDENTIFIER)")
        self.assertEqual(plist["CFBundleName"], "$(PRODUCT_NAME)")


class DuplicateDetectionTests(unittest.TestCase):
    """The parser itself must see the duplicate shape an upstream merge leaves behind."""

    MERGED = (
        "\t\tABC /* Debug */ = {\n"
        "\t\t\tisa = XCBuildConfiguration;\n"
        "\t\t\tbuildSettings = {\n"
        "\t\t\t\tINFOPLIST_FILE = Info.plist;\n"
        f"\t\t\t\tPRODUCT_BUNDLE_IDENTIFIER = {PERSONAL_BUNDLE_ID};\n"
        "\t\t\t\tPRODUCT_BUNDLE_IDENTIFIER = com.FluidApp.app.debug;\n"
        '\t\t\t\t"OTHER_LDFLAGS[arch=*]" = "-ObjC";\n'
        "\t\t\t};\n"
        "\t\t\tname = Debug;\n"
        "\t\t};\n"
    )

    def test_finds_repeated_key(self):
        [(name, settings)] = list(build_configurations(self.MERGED))
        keys = setting_keys(settings)
        self.assertEqual(name, "Debug")
        self.assertEqual(keys.count("PRODUCT_BUNDLE_IDENTIFIER"), 2)
        self.assertEqual(
            setting_value(settings, "PRODUCT_BUNDLE_IDENTIFIER"),
            [PERSONAL_BUNDLE_ID, "com.FluidApp.app.debug"],
        )


if __name__ == "__main__":
    unittest.main()
