"""The bucket layout, built in a local folder that CI then syncs to R2.

    chunks/<aa>/<sha256>                    chunk bytes, content-addressed, never rewritten
    channels/<channel>/manifest.json        canonical JSON (manifest.py)
    channels/<channel>/manifest.json.sig    base64 Ed25519 signature of manifest.json

Publishing adds the new chunks, carries over the previous manifest's other
artifacts, raises the sequence by one and signs the result. Chunks are never
deleted here: a phone halfway through an update may still need them.
"""

from __future__ import annotations

import hashlib
import json
import os
import tempfile
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path

from . import guard, signing
from .chunker import DEFAULT, Params, chunk_stream
from .manifest import Artifact, Chunk, Manifest, ManifestError, chunk_path


class StoreError(RuntimeError):
    """The store is inconsistent or a publish cannot go ahead."""


def manifest_paths(root: Path, channel: str) -> tuple[Path, Path]:
    folder = root / "channels" / channel
    return folder / "manifest.json", folder / "manifest.json.sig"


def _write_atomic(path: Path, data: bytes) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, tmp = tempfile.mkstemp(dir=path.parent, prefix=f".{path.name}.")
    try:
        with os.fdopen(fd, "wb") as handle:
            handle.write(data)
        os.replace(tmp, path)
    except BaseException:
        Path(tmp).unlink(missing_ok=True)
        raise


def load_signed(root: Path, channel: str, public_key: str) -> Manifest | None:
    """The channel's current manifest, or None if the channel is new.
    Raises StoreError if it is there but its signature does not hold."""
    manifest_file, sig_file = manifest_paths(root, channel)
    if not manifest_file.exists() and not sig_file.exists():
        return None
    if not manifest_file.exists() or not sig_file.exists():
        raise StoreError(f"{channel}: manifest.json and manifest.json.sig must both be present")
    raw = manifest_file.read_bytes()
    if not signing.verify(raw, sig_file.read_text(), public_key):
        raise StoreError(f"{channel}: the manifest signature does not match the key")
    try:
        manifest = Manifest.from_bytes(raw)
    except ManifestError as exc:
        raise StoreError(f"{channel}: {exc}") from exc
    if manifest.channel != channel:
        raise StoreError(f"{channel}: the manifest says it is for channel {manifest.channel}")
    return manifest


def add_artifact(root: Path, path: Path, *, kind: str, artifact_id: str, version: str, params: Params = DEFAULT) -> Artifact:
    """Chunk ``path`` into the store and describe it. Does not run the guard."""
    whole = hashlib.sha256()
    chunks: list[Chunk] = []
    with path.open("rb") as handle:
        for data in chunk_stream(handle, params):
            digest = hashlib.sha256(data).hexdigest()
            target = root / chunk_path(digest)
            if not target.exists():
                _write_atomic(target, data)
            chunks.append(Chunk(digest, len(data)))
            whole.update(data)
    artifact = Artifact(
        id=artifact_id,
        kind=kind,
        version=version,
        size=sum(c.size for c in chunks),
        sha256=whole.hexdigest(),
        chunks=tuple(chunks),
    )
    artifact.validate()
    return artifact


@dataclass(frozen=True)
class ReleaseItem:
    id: str
    kind: str
    version: str
    file: Path


def read_spec(spec_file: Path) -> tuple[str, list[ReleaseItem]]:
    """A release spec names a channel and the files to publish on it:

    {"channel": "stable",
     "artifacts": [{"id": "app", "kind": "app", "version": "0.1.0", "file": "build/Cartouche.ipa"}]}

    File paths are relative to the current directory.
    """
    try:
        data = json.loads(spec_file.read_text(encoding="utf-8"))
        items = [
            ReleaseItem(a["id"], a["kind"], a["version"], Path(a["file"]))
            for a in data["artifacts"]
        ]
        channel = data["channel"]
    except (OSError, UnicodeDecodeError, json.JSONDecodeError, KeyError, TypeError) as exc:
        raise StoreError(f"cannot read the release spec {spec_file}: {exc}") from exc
    if not items:
        raise StoreError("the release spec lists no artifacts")
    return channel, items


def _now() -> str:
    return datetime.now(timezone.utc).replace(microsecond=0).strftime("%Y-%m-%dT%H:%M:%SZ")


def publish(
    root: Path,
    channel: str,
    items: list[ReleaseItem],
    *,
    private_key: str,
    app_bundle_id: str,
    published: str | None = None,
    params: Params = DEFAULT,
) -> Manifest:
    """Guard, chunk and sign. Nothing is written to the channel unless every
    item passes the guard."""
    public_key = signing.public_from_private(private_key)
    previous = load_signed(root, channel, public_key)
    for item in items:
        guard.check_file(item.file, item.kind, app_bundle_id_expected=app_bundle_id)
    artifacts = {a.id: a for a in previous.artifacts} if previous else {}
    for item in items:
        artifacts[item.id] = add_artifact(root, item.file, kind=item.kind, artifact_id=item.id, version=item.version, params=params)
    manifest = Manifest(
        channel=channel,
        sequence=previous.sequence + 1 if previous else 1,
        published=published or _now(),
        artifacts=list(artifacts.values()),
    )
    raw = manifest.to_bytes()
    manifest_file, sig_file = manifest_paths(root, channel)
    _write_atomic(manifest_file, raw)
    _write_atomic(sig_file, (signing.sign(raw, private_key) + "\n").encode())
    return manifest


def verify(root: Path, channel: str, public_key: str) -> list[str]:
    """Check the signature, then every chunk of every artifact. Returns the
    problems found; an empty list means the channel is sound."""
    try:
        manifest = load_signed(root, channel, public_key)
    except StoreError as exc:
        return [str(exc)]
    if manifest is None:
        return [f"{channel}: no manifest"]
    problems = []
    for artifact in manifest.artifacts:
        whole = hashlib.sha256()
        for chunk in artifact.chunks:
            target = root / chunk_path(chunk.sha256)
            if not target.exists():
                problems.append(f"{artifact.id}: chunk {chunk.sha256} is missing")
                continue
            data = target.read_bytes()
            if len(data) != chunk.size or hashlib.sha256(data).hexdigest() != chunk.sha256:
                problems.append(f"{artifact.id}: chunk {chunk.sha256} is damaged")
                continue
            whole.update(data)
        if not problems and whole.hexdigest() != artifact.sha256:
            problems.append(f"{artifact.id}: the chunks do not rebuild the artifact")
    return problems
