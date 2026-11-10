"""A batch's report: what was built and why, what failed and where its log is,
and what nxnative's authors said front ends should know (Front-ends: lines)."""

from __future__ import annotations

import time
from pathlib import Path

from .i18n import t


def write(folder: Path, head: str, built: list, failed: list, stopped: bool, notes: list, waiting: int, duration: float) -> Path:
    """BUILT: (entry, build); FAILED: (entry, error, log path)."""
    folder.mkdir(parents=True, exist_ok=True)
    path = folder / time.strftime("%Y-%m-%d_%H-%M-%S.md")
    lines = [f"# {t('report.title', date=time.strftime('%Y-%m-%d %H:%M'))}", ""]
    lines.append(t("report.engine", commit=head[:12]))
    lines.append(t("report.duration", minutes=int(duration // 60)))
    if stopped:
        lines.append(t("report.stopped"))
    lines.append("")
    lines.append(f"## {t('report.built', count=len(built))}")
    lines.append("")
    for entry, build in built:
        lines.append(f"- **{entry.game.display_name}** (`{entry.title_id}`): {build.ipa}, {t('report.version', version=build.version or '?')}, {int(build.duration // 60)} min")
        if entry.detail:
            lines.append(f"  - {entry.detail}")
    if not built:
        lines.append(t("report.none"))
    lines.append("")
    if failed:
        lines.append(f"## {t('report.failed', count=len(failed))}")
        lines.append("")
        for entry, error, log in failed:
            lines.append(f"- **{entry.game.display_name}** (`{entry.title_id}`): {error}")
            lines.append(f"  - {t('report.log', path=log)}")
        lines.append("")
    if waiting:
        lines.append(t("report.waiting", count=waiting))
        lines.append("")
    if notes:
        lines.append(f"## {t('report.notes')}")
        lines.append("")
        for commit, kind, text in notes:
            lines.append(f"- `{commit}` {kind}: {text}")
        lines.append("")
    path.write_text("\n".join(lines), encoding="utf-8")
    return path


def prune(folder: Path, days: int, pattern: str = "*") -> None:
    """Removes the builder's own logs and reports older than DAYS."""
    if not folder.is_dir():
        return
    limit = time.time() - days * 86400
    for path in folder.rglob(pattern):
        try:
            if path.is_file() and path.suffix in (".log", ".md") and path.stat().st_mtime < limit:
                path.unlink()
        except OSError:
            pass
