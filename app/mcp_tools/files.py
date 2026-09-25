from __future__ import annotations

import os
from pathlib import Path

from mcp.server.mcpserver import Context

from app.mcp_tools.registry import mcp_server
from app.permissions.scopes import guarded

# Every file tool is jailed to this directory. Point it at wherever you sync
# device-node uploads / personal documents on the VPS. Never let a tool touch
# paths outside of it.
FILES_ROOT = Path(os.environ.get("FILES_ROOT", "/data/files")).resolve()


def _safe_join(relative_path: str) -> Path:
    candidate = (FILES_ROOT / relative_path).resolve()
    if not str(candidate).startswith(str(FILES_ROOT)):
        raise ValueError("Path escapes the allowed files root")
    return candidate


@mcp_server.tool()
@guarded("search_files")
async def search_files(ctx: Context, query: str, limit: int = 20) -> dict:
    """Search filenames under the personal files root for a query substring.

    Args:
        query: Substring to match against file names (case-insensitive).
        limit: Max results.
    """
    FILES_ROOT.mkdir(parents=True, exist_ok=True)
    query_lower = query.lower()
    matches = []
    for path in FILES_ROOT.rglob("*"):
        if path.is_file() and query_lower in path.name.lower():
            matches.append(str(path.relative_to(FILES_ROOT)))
            if len(matches) >= limit:
                break
    return {"status": "ok", "count": len(matches), "files": matches}


@mcp_server.tool()
@guarded("read_file")
async def read_file(ctx: Context, relative_path: str, max_chars: int = 8000) -> dict:
    """Read the text content of a file under the personal files root.

    Args:
        relative_path: Path relative to the files root (e.g. "warranties/laptop.pdf.txt").
        max_chars: Truncate returned text to this many characters.
    """
    try:
        path = _safe_join(relative_path)
    except ValueError as e:
        return {"status": "error", "message": str(e)}

    if not path.exists() or not path.is_file():
        return {"status": "not_found", "path": relative_path}

    try:
        text = path.read_text(errors="replace")
    except Exception as e:  # noqa: BLE001 - surface to caller instead of crashing the tool
        return {"status": "error", "message": f"Could not read as text: {e}"}

    return {"status": "ok", "path": relative_path, "content": text[:max_chars], "truncated": len(text) > max_chars}
