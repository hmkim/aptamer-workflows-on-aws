import re
import unittest
from pathlib import Path


ROOT = Path(__file__).parents[1]
LINK_RE = re.compile(r"\[[^\]]+\]\(([^)\s]+)\)")
FENCE_RE = re.compile(r"^\s*(```|~~~)", re.MULTILINE)
HEADING_RE = re.compile(r"^(#{1,6})\s", re.MULTILINE)
# Directories that hold generated or third-party Markdown.
EXCLUDED_DIRS = {".git", "node_modules", "cdk.out", "dist", "build", "inputs", "work", ".scratch", ".pytest_cache"}
GETTING_STARTED = [
    "00-prerequisites",
    "05-local",
    "10-network",
    "20-batch",
    "25-nextflow",
    "30-healthomics",
    "40-both",
    "90-cleanup",
]


def markdown_files():
    return sorted(
        path
        for path in ROOT.rglob("*.md")
        if not EXCLUDED_DIRS.intersection(path.relative_to(ROOT).parts)
    )


def is_korean(path):
    return path.name.endswith(".ko.md")


def english_twin(path):
    return path.with_name(path.name[: -len(".ko.md")] + ".md")


def korean_twin(path):
    return path.with_name(path.name[: -len(".md")] + ".ko.md")


def switch_line(english):
    return f"[English]({english.name}) | [한국어]({korean_twin(english).name})"


def without_code(text):
    """Drop fenced code blocks so links and headings inside examples are ignored."""
    return re.sub(r"^\s*(```|~~~).*?^\s*\1[^\n]*$", "", text, flags=re.MULTILINE | re.DOTALL)


def relative_links(path):
    for target in LINK_RE.findall(without_code(path.read_text(encoding="utf-8"))):
        target = target.split("#", 1)[0]
        if not target or "://" in target or target.startswith("mailto:"):
            continue
        yield target


def rel(path):
    return str(path.relative_to(ROOT))


class DocumentationTest(unittest.TestCase):
    def test_relative_markdown_links_exist(self):
        missing = []
        for document in markdown_files():
            for target in relative_links(document):
                if not (document.parent / target).resolve().exists():
                    missing.append(f"{rel(document)} -> {target}")
        self.assertEqual(missing, [], "missing relative links:\n" + "\n".join(missing))

    def test_every_english_document_has_korean_twin(self):
        missing = [rel(p) for p in markdown_files() if not is_korean(p) and not korean_twin(p).exists()]
        self.assertEqual(missing, [], "English documents without a .ko.md twin:\n" + "\n".join(missing))

    def test_every_korean_document_has_english_twin(self):
        missing = [rel(p) for p in markdown_files() if is_korean(p) and not english_twin(p).exists()]
        self.assertEqual(missing, [], "Korean documents without an English twin:\n" + "\n".join(missing))

    def test_language_switch_line_at_top(self):
        problems = []
        for path in markdown_files():
            english = english_twin(path) if is_korean(path) else path
            head = [line.strip() for line in path.read_text(encoding="utf-8").splitlines() if line.strip()][:3]
            if switch_line(english) not in head:
                problems.append(f"{rel(path)}: expected {switch_line(english)!r} in the first lines")
        self.assertEqual(problems, [], "\n".join(problems))

    def test_korean_links_point_to_korean_twins(self):
        problems = []
        for path in markdown_files():
            if not is_korean(path):
                continue
            english_name = english_twin(path).name
            for target in relative_links(path):
                if target == english_name or not target.endswith(".md") or target.endswith(".ko.md"):
                    continue
                if korean_twin((path.parent / target).resolve()).exists():
                    problems.append(f"{rel(path)} -> {target} (use the .ko.md twin)")
        self.assertEqual(problems, [], "\n".join(problems))

    def test_twins_have_same_structure(self):
        problems = []
        for path in markdown_files():
            if is_korean(path) or not korean_twin(path).exists():
                continue
            english = path.read_text(encoding="utf-8")
            korean = korean_twin(path).read_text(encoding="utf-8")
            if len(FENCE_RE.findall(english)) != len(FENCE_RE.findall(korean)):
                problems.append(f"{rel(path)}: code block count differs from its Korean twin")
            if HEADING_RE.findall(without_code(english)) != HEADING_RE.findall(without_code(korean)):
                problems.append(f"{rel(path)}: heading levels differ from its Korean twin")
        self.assertEqual(problems, [], "\n".join(problems))

    def test_getting_started_guides_exist(self):
        base = ROOT / "docs" / "getting-started"
        missing = [
            f"{name}{suffix}"
            for name in GETTING_STARTED
            for suffix in (".md", ".ko.md")
            if not (base / f"{name}{suffix}").exists()
        ]
        self.assertEqual(missing, [])

    def test_readme_links_every_path(self):
        readme = (ROOT / "README.md").read_text(encoding="utf-8")
        for target in (
            "docs/getting-started/20-batch.md#cpu-only",
            "docs/getting-started/20-batch.md#cpu--gpu",
            "docs/getting-started/20-batch.md#gpu-only",
            "docs/getting-started/30-healthomics.md",
            "docs/getting-started/40-both.md#both-at-once",
            "docs/getting-started/40-both.md#one-after-another",
            "docs/raptgen/batch.md",
            "docs/getting-started/90-cleanup.md",
        ):
            with self.subTest(target=target):
                self.assertIn(f"]({target})", readme)

    def test_healthomics_vpc_mode_marked_not_validated(self):
        for name, marker in (("30-healthomics.md", "not yet validated"), ("30-healthomics.ko.md", "아직 검증되지 않")):
            with self.subTest(document=name):
                text = (ROOT / "docs" / "getting-started" / name).read_text(encoding="utf-8")
                self.assertIn(marker, text)

    def test_no_sensitive_strings_in_documents(self):
        terms_file = ROOT / ".sensitive-terms"
        terms = []
        if terms_file.exists():
            terms = [
                t.strip()
                for t in terms_file.read_text(encoding="utf-8").splitlines()
                if t.strip() and not t.startswith("#")
            ]
        real_id = re.compile(r"\b(i|sg|vpc|subnet|vpce|nat)-0[0-9a-f]{8,17}\b|\bvo_[A-Za-z0-9]+")
        account_id = re.compile(r"(?<![0-9A-Za-z])(?!123456789012)[0-9]{12}(?![0-9A-Za-z])")
        problems = []
        for path in markdown_files():
            text = path.read_text(encoding="utf-8")
            for term in terms:
                if term in text:
                    # Report file and line only: never echo any part of a forbidden term.
                    problems.append(f"{rel(path)}:{text.count(chr(10), 0, text.find(term)) + 1}: forbidden term")
            for rx in (real_id, account_id):
                for match in rx.finditer(text):
                    problems.append(f"{rel(path)}:{text.count(chr(10), 0, match.start()) + 1}: identifier-like value")
        self.assertEqual(problems, [], "\n".join(problems))


if __name__ == "__main__":
    unittest.main()
