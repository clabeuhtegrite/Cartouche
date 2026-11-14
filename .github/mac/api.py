"""The few calls of GitHub's REST API that route.py, watch.py and rescue.py
make, and what they write for their workflow (.github/mac/README.md)."""

from __future__ import annotations

import json
import os
import urllib.error
import urllib.request


class Error(Exception):
    pass


def call(method: str, path: str, token: str, body: dict | None = None, timeout: int = 15):
    """What GitHub answers METHOD PATH, decoded; None for an empty answer."""
    request = urllib.request.Request(
        os.environ.get("GITHUB_API_URL", "https://api.github.com") + path, method=method,
        data=None if body is None else json.dumps(body).encode())
    request.add_header("Accept", "application/vnd.github+json")
    request.add_header("X-GitHub-Api-Version", "2022-11-28")
    if token:
        request.add_header("Authorization", f"Bearer {token}")
    if body is not None:
        request.add_header("Content-Type", "application/json")
    try:
        with urllib.request.urlopen(request, timeout=timeout) as response:
            data = response.read()
    except urllib.error.HTTPError as error:
        said = error.read()[:300].decode(errors="replace")
        raise Error(f"{method} {path}: HTTP {error.code} {said}") from None
    except (urllib.error.URLError, OSError) as error:
        raise Error(f"{method} {path}: {error}") from None
    return json.loads(data) if data else None


def pages(path: str, key: str, token: str, per_page: int = 100, most: int = 10) -> list[dict]:
    """Every item under KEY of what GitHub answers GET PATH, page after page,
    MOST pages at most: a list answers PER_PAGE items a page, 30 unless
    asked."""
    items: list[dict] = []
    for page in range(1, most + 1):
        answer = call("GET", f"{path}{'&' if '?' in path else '?'}per_page={per_page}&page={page}", token) or {}
        found = answer.get(key, [])
        items += found
        if len(found) < per_page:
            break
    return items


def runners(repository: str, token: str) -> list[dict]:
    """The repository's self-hosted runners, as the API describes them."""
    return call("GET", f"/repos/{repository}/actions/runners?per_page=100", token).get("runners", [])


def labels(runner: dict) -> set[str]:
    return {label.get("name", "") for label in runner.get("labels", [])}


def output(**values: str) -> None:
    """The step's outputs (GITHUB_OUTPUT)."""
    path = os.environ.get("GITHUB_OUTPUT")
    if path:
        with open(path, "a") as file:
            for name, value in values.items():
                file.write(f"{name}={value}\n")


def summary(text: str) -> None:
    """A line of the run's summary (GITHUB_STEP_SUMMARY), and of the log."""
    print(text, flush=True)
    path = os.environ.get("GITHUB_STEP_SUMMARY")
    if path:
        with open(path, "a") as file:
            file.write(text + "\n")
