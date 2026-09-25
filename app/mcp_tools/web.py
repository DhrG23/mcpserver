from __future__ import annotations

import asyncio
import os

import httpx
from mcp.server.mcpserver import Context

from app.mcp_tools.registry import mcp_server
from app.permissions.scopes import guarded

# Pluggable so your own daily-use instance can run for free (DuckDuckGo, no
# key, no cost) while a build aimed at the Nebius submission can switch to
# Tavily -- worth doing there specifically because Nebius has a standalone
# "Best Use of Tavily" prize; Tavily also returns a synthesized `answer`
# field DuckDuckGo doesn't, which can matter for the Nemotron agent chaining
# multiple tool calls. Switch with SEARCH_PROVIDER=duckduckgo|tavily.
SEARCH_PROVIDER = os.environ.get("SEARCH_PROVIDER", "duckduckgo").lower()
TAVILY_API_KEY = os.environ.get("TAVILY_API_KEY", "")
TAVILY_SEARCH_URL = "https://api.tavily.com/search"


async def _search_duckduckgo(query: str, max_results: int) -> dict:
    # ddgs's client is sync; run it off the event loop so it doesn't block
    # other tool calls while it does its HTTP round-trip.
    from ddgs import DDGS

    def _run() -> list[dict]:
        return DDGS().text(query, max_results=max_results)

    raw = await asyncio.to_thread(_run)
    results = [
        {"title": r.get("title"), "url": r.get("href"), "snippet": r.get("body")}
        for r in raw
    ]
    return {"status": "ok", "answer": None, "results": results}


async def _search_tavily(query: str, max_results: int) -> dict:
    if not TAVILY_API_KEY:
        return {
            "status": "error",
            "message": "TAVILY_API_KEY is not set. Set it in .env, or set SEARCH_PROVIDER=duckduckgo to skip Tavily entirely.",
        }
    async with httpx.AsyncClient(timeout=15) as client:
        resp = await client.post(
            TAVILY_SEARCH_URL,
            json={
                "api_key": TAVILY_API_KEY,
                "query": query,
                "max_results": max_results,
                "include_answer": True,
            },
        )
        resp.raise_for_status()
        data = resp.json()
    results = [
        {"title": r.get("title"), "url": r.get("url"), "snippet": r.get("content")}
        for r in data.get("results", [])
    ]
    return {"status": "ok", "answer": data.get("answer"), "results": results}


@mcp_server.tool()
@guarded("search_web")
async def search_web(ctx: Context, query: str, max_results: int = 5) -> dict:
    """Search the web for current information.

    Args:
        query: Search query.
        max_results: Max results to return (default 5).
    """
    if SEARCH_PROVIDER == "tavily":
        return await _search_tavily(query, max_results)
    return await _search_duckduckgo(query, max_results)


@mcp_server.tool()
@guarded("fetch_webpage")
async def fetch_webpage(ctx: Context, url: str, max_chars: int = 4000) -> dict:
    """Fetch and return the text content of a specific web page.

    Args:
        url: The page URL to fetch.
        max_chars: Truncate returned text to this many characters.
    """
    async with httpx.AsyncClient(timeout=15, follow_redirects=True) as client:
        resp = await client.get(url, headers={"User-Agent": "PersonalAI-MCP/0.1"})
        resp.raise_for_status()
    text = resp.text
    return {"status": "ok", "url": url, "content": text[:max_chars], "truncated": len(text) > max_chars}
