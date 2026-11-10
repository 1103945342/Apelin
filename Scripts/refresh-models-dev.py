#!/usr/bin/env python3
"""Keep this repository's copy of models.dev's catalog: Apelin/Resources/models.dev.json.

The app ships this file and writes it into the data folder on the first launch,
so a device reads a model the catalog kwwk ships does not name without reaching
the network; the app replaces it when its copy is older than a week.

The trimming is the one `ModelDataSnapshot.parse` does in Swift — the fields a
conversation reads, nothing else — so the app decodes this file with the same
type it decodes models.dev's own api.json with. The file is rewritten only when
a model's figures change: its `generatedAt` is the moment Apelin's copy last
changed, which is what the app's week is measured from.

Usage: refresh-models-dev.py [repository root] [--source URL]
"""

import json
import sys
import urllib.request
from datetime import datetime, timezone
from pathlib import Path

RELATIVE = Path("Apelin/Resources/models.dev.json")
DEFAULT_SOURCE = "https://models.dev/api.json"


def number(value):
    """A positive number, or None. models.dev writes strings and floats alike."""
    if isinstance(value, bool):
        return None
    if isinstance(value, (int, float)):
        return int(value) if value > 0 else None
    if isinstance(value, str):
        try:
            parsed = int(value)
        except ValueError:
            try:
                parsed = int(float(value))
            except ValueError:
                return None
        return parsed if parsed > 0 else None
    return None


def decimal(value):
    if isinstance(value, bool):
        return None
    if isinstance(value, (int, float)):
        return float(value)
    if isinstance(value, str):
        try:
            return float(value)
        except ValueError:
            return None
    return None


def efforts(value):
    """models.dev's reasoning_options: an `effort` entry lists the levels."""
    if not isinstance(value, list):
        return None
    for option in value:
        if not isinstance(option, dict) or option.get("type") != "effort":
            continue
        values = option.get("values")
        if isinstance(values, list) and values:
            return [str(level).lower() for level in values]
    return None


def cost(value):
    if not isinstance(value, dict):
        return None
    entry = {
        key: decimal(value.get(source))
        for key, source in (
            ("input", "input"),
            ("output", "output"),
            ("cacheRead", "cache_read"),
            ("cacheWrite", "cache_write"),
        )
    }
    return {key: figure for key, figure in entry.items() if figure is not None} or None


def model(raw):
    """One model, as `ModelDataSnapshot.Model` keeps it."""
    limit = raw.get("limit") if isinstance(raw.get("limit"), dict) else {}
    modalities = raw.get("modalities") if isinstance(raw.get("modalities"), dict) else {}
    input_value = modalities.get("input", raw.get("input"))
    input_modalities = (
        [item for item in input_value if isinstance(item, str) and item]
        if isinstance(input_value, list)
        else None
    )
    entry = {
        "name": raw.get("name") if isinstance(raw.get("name"), str) else None,
        "context": number(limit.get("context", raw.get("context", raw.get("context_window")))),
        "output": number(limit.get("output", raw.get("output", raw.get("max_tokens")))),
        "input": input_modalities,
        "reasoning": raw.get("reasoning") if isinstance(raw.get("reasoning"), bool) else None,
        "efforts": efforts(raw.get("reasoning_options")),
        "cost": cost(raw.get("cost")),
    }
    return {key: value for key, value in entry.items() if value is not None}


def trim(catalog):
    """models.dev's whole catalog, as the snapshot keeps it."""
    models = {}
    for provider_id, provider in catalog.items():
        if not isinstance(provider, dict):
            continue
        listed = provider.get("models")
        if not isinstance(listed, dict):
            continue
        entries = {model_id: model(raw) for model_id, raw in listed.items() if isinstance(raw, dict)}
        if entries:
            models[provider_id] = entries
    return models


def read(url):
    # A browser's own headers: some hosts answer a script with 403.
    request = urllib.request.Request(
        url,
        headers={
            "Accept": "application/json",
            "Accept-Encoding": "identity",
            "User-Agent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) ApelinModelCatalog/1.0",
        },
    )
    with urllib.request.urlopen(request, timeout=120) as response:
        # A file:// source has no status, which is how a fixture is read.
        status = getattr(response, "status", None) or 200
        if status != 200:
            raise SystemExit(f"error: {url} answered {status}")
        return json.loads(response.read().decode("utf-8"))


def main(argv):
    root = Path(".")
    source = DEFAULT_SOURCE
    index = 0
    while index < len(argv):
        argument = argv[index]
        if argument == "--source":
            index += 1
            source = argv[index]
        elif argument.startswith("--source="):
            source = argument.split("=", 1)[1]
        else:
            root = Path(argument)
        index += 1

    target = root / RELATIVE
    try:
        catalog = read(source)
    except Exception as error:  # noqa: BLE001 - the reason is what the issue says
        raise SystemExit(f"error: {source} could not be read: {type(error).__name__}: {error}")
    models = trim(catalog)
    if not models:
        raise SystemExit("error: models.dev's catalog named no model")

    existing = {}
    generated = None
    if target.is_file():
        try:
            previous = json.loads(target.read_text(encoding="utf-8"))
            existing = previous.get("models") or {}
            generated = previous.get("generatedAt")
        except (OSError, ValueError):
            existing = {}

    # The same models are not a new copy: the stamp says when this file last
    # changed, so a day without a change leaves the repository alone.
    if existing == models and generated:
        print(f"unchanged: {sum(len(entries) for entries in models.values())} models")
        return 0

    stamp = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    payload = {"generatedAt": stamp, "source": source, "models": models}
    target.parent.mkdir(parents=True, exist_ok=True)
    target.write_text(json.dumps(payload, sort_keys=True, separators=(",", ":")) + "\n", encoding="utf-8")
    print(f"wrote {target}: {len(models)} providers, {sum(len(entries) for entries in models.values())} models, {stamp}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
