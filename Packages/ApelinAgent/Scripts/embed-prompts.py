#!/usr/bin/env python3
"""Writes Packages/ApelinAgent/Prompts/*.md into ApelinAgent as Swift raw strings.

The Markdown files are the system prompt's text; SystemPrompt.make puts them in
order and decides which ones a session gets. They are compiled in, not shipped
as resources: a resource bundle's accessor would carry the build machine's path
into the binary. Run this after editing a prompt file; `make check` runs it
with --check, which fails when the generated file and the prompts differ.

Each file is `NN-name.md`. A leading `<!-- ... -->` comment says what the
section is and when it is used, and is left out. `{{UPPER_SNAKE}}` is a
placeholder: a file with none becomes `static let name`, one with some
`static func name(upperSnake: String, ...)`, its parameters in the order the
placeholders first appear.
"""
import re
import sys
from pathlib import Path

PACKAGE = Path(__file__).resolve().parents[1]
REPOSITORY = PACKAGE.parents[1]
PROMPTS = PACKAGE / "Prompts"
TARGET = PACKAGE / "Sources/ApelinAgent/Session/SystemPromptText.swift"

FILE_NAME = re.compile(r"^(\d{2})-([a-z][a-z0-9]*(?:-[a-z0-9]+)*)\.md$")
PLACEHOLDER = re.compile(r"\{\{([A-Z][A-Z0-9]*(?:_[A-Z0-9]+)*)\}\}")
LEADING_COMMENT = re.compile(r"\A<!--.*?-->\n", re.DOTALL)


def camel(words: str, separator: str) -> str:
    parts = words.split(separator)
    return parts[0].lower() + "".join(part.lower().capitalize() for part in parts[1:])


def fail(message: str) -> None:
    raise SystemExit(f"error: {message}")


def member(path: Path) -> list[str]:
    match = FILE_NAME.match(path.name)
    if not match:
        fail(f"{path.relative_to(REPOSITORY)} is not named NN-name.md")
    name = camel(match.group(2), "-")
    raw = path.read_text(encoding="utf-8")
    comment = LEADING_COMMENT.match(raw)
    note = comment.group(0)[4:-4].strip() if comment else ""
    text = (raw[comment.end():] if comment else raw).rstrip("\n")
    if not text.strip():
        fail(f"{path.relative_to(REPOSITORY)} has no text")
    if "{{" in PLACEHOLDER.sub("", text) or "}}" in PLACEHOLDER.sub("", text):
        fail(f"{path.relative_to(REPOSITORY)} has a placeholder not spelled {{{{UPPER_SNAKE}}}}")
    hashes = "#"
    while f'"""{hashes}' in text or f"\\{hashes}" in text:
        hashes += "#"
    parameters: list[str] = []
    for placeholder in PLACEHOLDER.findall(text):
        parameter = camel(placeholder, "_")
        if parameter not in parameters:
            parameters.append(parameter)
    body = PLACEHOLDER.sub(lambda m: f"\\{hashes}({camel(m.group(1), '_')})", text)
    lines = [f"    /// {path.name}{': ' + note if note else ''}"]
    if parameters:
        signature = ", ".join(f"{parameter}: String" for parameter in parameters)
        lines.append(f"    static func {name}({signature}) -> String {{")
        lines.append(f'        {hashes}"""')
        lines += [f"        {line}" if line else "" for line in body.split("\n")]
        lines.append(f'        """{hashes}')
        lines.append("    }")
    else:
        lines.append(f'    static let {name} = {hashes}"""')
        lines += [f"    {line}" if line else "" for line in body.split("\n")]
        lines.append(f'    """{hashes}')
    return lines


def generate() -> str:
    files = sorted(path for path in PROMPTS.iterdir() if path.suffix == ".md" and path.name != "README.md")
    if not files:
        fail(f"no prompt files in {PROMPTS.relative_to(REPOSITORY)}")
    numbers = [path.name[:2] for path in files]
    for number in set(numbers):
        if numbers.count(number) > 1:
            fail(f"two prompt files are numbered {number}")
    lines = [
        "// Generated from Packages/ApelinAgent/Prompts/*.md; do not edit.",
        "// `make check` fails when this file and the prompts differ. Regenerate with:",
        "//   Packages/ApelinAgent/Scripts/embed-prompts.py",
        "",
        "/// The system prompt's text, one member per file in `Prompts/`, in their",
        "/// order. `SystemPrompt.make` decides which a session gets.",
        "enum SystemPromptText {",
    ]
    for index, path in enumerate(files):
        if index:
            lines.append("")
        lines += member(path)
    lines.append("}")
    return "\n".join(lines) + "\n"


def main() -> None:
    text = generate()
    if sys.argv[1:] == ["--check"]:
        current = TARGET.read_text(encoding="utf-8") if TARGET.exists() else ""
        if current != text:
            fail(f"{TARGET.relative_to(REPOSITORY)} differs from Packages/ApelinAgent/Prompts: run Packages/ApelinAgent/Scripts/embed-prompts.py")
        print(f"ok: {TARGET.relative_to(REPOSITORY)} matches the prompts")
        return
    if sys.argv[1:]:
        fail("usage: embed-prompts.py [--check]")
    TARGET.write_text(text, encoding="utf-8")
    print(f"wrote {TARGET.relative_to(REPOSITORY)}")


if __name__ == "__main__":
    main()
