"""The update manifest: what the update server offers on one channel.

A manifest lists artifacts (the app, engine builds, build tools, pipeline
lists, compatibility sheets), each as a list of SHA-256-addressed chunks. It
is serialized as canonical JSON and signed with Ed25519; the app pins the
public key and refuses a manifest whose ``sequence`` is lower than the last
one it accepted, so an old manifest cannot be replayed.

Games are not an artifact kind, and nothing in the format can point to one.
"""

from __future__ import annotations

import json
import re
from dataclasses import dataclass, field
from typing import Any

SCHEMA_VERSION = 1

# The only things the server publishes. There is deliberately no kind for
# games, game updates, keys or firmware.
KINDS = ("app", "engine-host", "toolchain", "pipeline-list", "catalog")

_SHA256 = re.compile(r"^[0-9a-f]{64}$")
_CHANNEL = re.compile(r"^[a-z0-9][a-z0-9-]{0,31}$")
_ARTIFACT_ID = re.compile(r"^[a-z0-9][a-z0-9.-]{0,63}(/[A-Za-z0-9][A-Za-z0-9._-]{0,63})?$")
_VERSION = re.compile(r"^[0-9A-Za-z][0-9A-Za-z.+-]{0,63}$")
_TIMESTAMP = re.compile(r"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$")


class ManifestError(ValueError):
    """The manifest or one of its artifacts is malformed."""


def canonical_json(value: Any) -> bytes:
    """The exact bytes that get signed: sorted keys, no spaces, UTF-8."""
    return json.dumps(value, sort_keys=True, separators=(",", ":"), ensure_ascii=False).encode("utf-8")


def chunk_path(sha256: str) -> str:
    """Where a chunk lives in the bucket."""
    return f"chunks/{sha256[:2]}/{sha256}"


@dataclass(frozen=True)
class Chunk:
    sha256: str
    size: int

    def to_json(self) -> dict[str, Any]:
        return {"sha256": self.sha256, "size": self.size}


@dataclass(frozen=True)
class Artifact:
    id: str
    kind: str
    version: str
    size: int
    sha256: str
    chunks: tuple[Chunk, ...]

    def validate(self) -> None:
        if not _ARTIFACT_ID.match(self.id):
            raise ManifestError(f"bad artifact id {self.id!r}")
        if self.kind not in KINDS:
            raise ManifestError(f"{self.id}: kind {self.kind!r} is not one of {', '.join(KINDS)}")
        if not self.id.split("/", 1)[0] == self.kind:
            raise ManifestError(f"{self.id}: the id must start with its kind ({self.kind})")
        if not _VERSION.match(self.version):
            raise ManifestError(f"{self.id}: bad version {self.version!r}")
        if not _SHA256.match(self.sha256):
            raise ManifestError(f"{self.id}: bad sha256")
        for chunk in self.chunks:
            if not _SHA256.match(chunk.sha256) or chunk.size <= 0:
                raise ManifestError(f"{self.id}: bad chunk {chunk}")
        if sum(c.size for c in self.chunks) != self.size:
            raise ManifestError(f"{self.id}: chunk sizes do not add up to the artifact size")

    def to_json(self) -> dict[str, Any]:
        return {
            "id": self.id,
            "kind": self.kind,
            "version": self.version,
            "size": self.size,
            "sha256": self.sha256,
            "chunks": [c.to_json() for c in self.chunks],
        }

    @classmethod
    def from_json(cls, data: dict[str, Any]) -> "Artifact":
        try:
            return cls(
                id=data["id"],
                kind=data["kind"],
                version=data["version"],
                size=int(data["size"]),
                sha256=data["sha256"],
                chunks=tuple(Chunk(c["sha256"], int(c["size"])) for c in data["chunks"]),
            )
        except (KeyError, TypeError) as exc:
            raise ManifestError(f"malformed artifact: {exc}") from exc


@dataclass
class Manifest:
    channel: str
    sequence: int
    published: str
    artifacts: list[Artifact] = field(default_factory=list)
    schema: int = SCHEMA_VERSION

    def validate(self) -> None:
        if self.schema != SCHEMA_VERSION:
            raise ManifestError(f"unsupported schema {self.schema}")
        if not _CHANNEL.match(self.channel):
            raise ManifestError(f"bad channel {self.channel!r}")
        if self.sequence < 1:
            raise ManifestError("sequence must be at least 1")
        if not _TIMESTAMP.match(self.published):
            raise ManifestError("published must be an ISO 8601 UTC time like 2026-11-05T22:00:00Z")
        seen: set[str] = set()
        for artifact in self.artifacts:
            artifact.validate()
            if artifact.id in seen:
                raise ManifestError(f"artifact {artifact.id} is listed twice")
            seen.add(artifact.id)

    def to_json(self) -> dict[str, Any]:
        return {
            "schema": self.schema,
            "channel": self.channel,
            "sequence": self.sequence,
            "published": self.published,
            "artifacts": [a.to_json() for a in sorted(self.artifacts, key=lambda a: a.id)],
        }

    def to_bytes(self) -> bytes:
        self.validate()
        return canonical_json(self.to_json())

    @classmethod
    def from_bytes(cls, raw: bytes) -> "Manifest":
        try:
            data = json.loads(raw.decode("utf-8"))
            manifest = cls(
                schema=data["schema"],
                channel=data["channel"],
                sequence=int(data["sequence"]),
                published=data["published"],
                artifacts=[Artifact.from_json(a) for a in data["artifacts"]],
            )
        except (UnicodeDecodeError, json.JSONDecodeError, KeyError, TypeError) as exc:
            raise ManifestError(f"malformed manifest: {exc}") from exc
        manifest.validate()
        return manifest

    def artifact(self, artifact_id: str) -> Artifact | None:
        return next((a for a in self.artifacts if a.id == artifact_id), None)
