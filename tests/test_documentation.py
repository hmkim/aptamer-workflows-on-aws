import re
import unittest
from pathlib import Path


ROOT = Path(__file__).parents[1]
LINK_RE = re.compile(r"\[[^\]]+\]\(([^)]+)\)")


class DocumentationTest(unittest.TestCase):
    def test_relative_markdown_links_exist(self):
        missing = []
        for document in ROOT.rglob("*.md"):
            for target in LINK_RE.findall(document.read_text()):
                target = target.split("#", 1)[0]
                if not target or "://" in target or target.startswith("mailto:"):
                    continue
                resolved = (document.parent / target).resolve()
                if not resolved.exists():
                    missing.append(f"{document.relative_to(ROOT)} -> {target}")
        self.assertEqual(missing, [], "missing relative links:\n" + "\n".join(missing))


if __name__ == "__main__":
    unittest.main()
