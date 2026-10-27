import importlib.util
import unittest
from pathlib import Path


def load_publisher():
    path = Path(__file__).with_name("publish_hcp_provider.py")
    spec = importlib.util.spec_from_file_location("publish_hcp_provider", path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


class ParsePlatformsTest(unittest.TestCase):
    def test_prerelease_archive_keeps_os_and_arch(self):
        publisher = load_publisher()
        sums = (
            "abc123  terraform-provider-postgresql_1.26.0-zb.1_linux_amd64.zip\n"
            "def456  terraform-provider-postgresql_1.26.0-zb.1_SHA256SUMS\n"
        )

        platforms = publisher.parse_platforms(sums, "1.26.0-zb.1")

        self.assertEqual(
            platforms,
            [("abc123", "terraform-provider-postgresql_1.26.0-zb.1_linux_amd64.zip", "linux", "amd64")],
        )

    def test_release_version_strips_a_single_leading_v(self):
        publisher = load_publisher()
        self.assertEqual(publisher.release_version("v1.26.0-zb.1"), "1.26.0-zb.1")


if __name__ == "__main__":
    unittest.main()
