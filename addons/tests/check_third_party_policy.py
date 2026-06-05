import os
from pathlib import Path
from typing import Iterator


PROJECT_PATH = Path(__file__).resolve().parents[2]

SKIPPED_PARTS = {".agent", ".git", ".godot", "__pycache__", "trash_scripts"}
THIRD_PARTY_DIR_NAMES = {"third_party", "thirdparty", "vendor", "vendors", "external"}
ALLOWED_THIRD_PARTY_ROOTS = {
    Path("addons/third_party"),
    Path("addons/gdextension_setup"),
}
LICENSE_MARKERS = (
    "MIT License",
    "Apache License",
    "BSD License",
    "GNU GENERAL PUBLIC LICENSE",
    "GNU LESSER GENERAL PUBLIC LICENSE",
)
TEXT_SUFFIXES = {
    ".gd",
    ".cs",
    ".cpp",
    ".h",
    ".hpp",
    ".py",
    ".md",
    ".txt",
    ".json",
    ".cfg",
    ".toml",
    ".scons",
    ".gdextension",
}
TEXT_SIZE_LIMIT_BYTES = 512 * 1024


def _is_skipped(path: Path) -> bool:
    return any(part in SKIPPED_PARTS for part in path.parts)


def _is_under(path: Path, root: Path) -> bool:
    return path == root or root in path.parents


def _is_allowed_third_party_path(relative_path: Path) -> bool:
    return any(_is_under(relative_path, allowed_root) for allowed_root in ALLOWED_THIRD_PARTY_ROOTS)


def _read_text(path: Path) -> str:
    return path.read_text(encoding="utf-8", errors="ignore")


def _should_scan_text_file(path: Path) -> bool:
    name = path.name.lower()
    if name in {"license", "copying", "notice", "authors"} or name.startswith("license"):
        return True
    if path.suffix.lower() not in TEXT_SUFFIXES:
        return False
    if path.stat().st_size > TEXT_SIZE_LIMIT_BYTES and not name.startswith(("license", "readme", "notice", "copying")):
        return False
    return True


def _iter_project_paths(skip_allowed_third_party_contents: bool = False) -> Iterator[Path]:
    for root, dirnames, filenames in os.walk(PROJECT_PATH):
        root_path = Path(root)
        relative_root = root_path.relative_to(PROJECT_PATH)
        kept_dirnames: list[str] = []
        for dirname in dirnames:
            relative_dir = relative_root / dirname
            if dirname in SKIPPED_PARTS or _is_skipped(relative_dir):
                continue
            if skip_allowed_third_party_contents and _is_allowed_third_party_path(relative_dir):
                continue
            kept_dirnames.append(dirname)
            yield root_path / dirname
        dirnames[:] = kept_dirnames
        for filename in filenames:
            relative_file = relative_root / filename
            if _is_skipped(relative_file):
                continue
            yield root_path / filename


def _discover_disallowed_third_party_dirs() -> list[str]:
    failures: list[str] = []
    for path in _iter_project_paths(skip_allowed_third_party_contents=True):
        relative_path = path.relative_to(PROJECT_PATH)
        if _is_skipped(relative_path) or not path.is_dir():
            continue
        if path.name.lower() in THIRD_PARTY_DIR_NAMES and not _is_allowed_third_party_path(relative_path):
            failures.append(f"{relative_path}: third-party directories must live under addons/third_party or addons/gdextension_setup")
    return failures


def _discover_disallowed_license_markers() -> list[str]:
    failures: list[str] = []
    for path in _iter_project_paths(skip_allowed_third_party_contents=True):
        relative_path = path.relative_to(PROJECT_PATH)
        if _is_skipped(relative_path) or path.name == Path(__file__).name or not path.is_file():
            continue
        if _is_allowed_third_party_path(relative_path):
            continue
        if not _should_scan_text_file(path):
            continue
        text = _read_text(path)
        if any(marker in text for marker in LICENSE_MARKERS):
            failures.append(f"{relative_path}: non-CC0 license marker found outside approved third-party roots")
    return failures


def _check_addons_third_party_packages() -> list[str]:
    failures: list[str] = []
    root = PROJECT_PATH / "addons" / "third_party"
    if not root.exists():
        return failures
    for package_dir in root.iterdir():
        if not package_dir.is_dir():
            continue
        readme_path = package_dir / "README.md"
        if not readme_path.exists():
            failures.append(f"{readme_path.relative_to(PROJECT_PATH)}: third-party package must document source, license, and reason")
            continue
        readme = _read_text(readme_path)
        required_terms = ("Source:", "License:", "Reason:")
        missing_terms = [term for term in required_terms if term not in readme]
        if missing_terms:
            failures.append(
                f"{readme_path.relative_to(PROJECT_PATH)}: missing required provenance fields: {', '.join(missing_terms)}"
            )
    return failures


def main() -> int:
    failures: list[str] = []
    failures.extend(_discover_disallowed_third_party_dirs())
    failures.extend(_discover_disallowed_license_markers())
    failures.extend(_check_addons_third_party_packages())

    if failures:
        print("Third-party policy check failed:")
        for failure in failures:
            print(f"  - {failure}")
        return 1

    print("Third-party policy check passed.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
