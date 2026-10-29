"""Tiny in-memory sliding-window limiter. One process, so a dict is enough."""
from __future__ import annotations

import time
from collections import defaultdict, deque


class SlidingWindow:
    def __init__(self, limit: int, window_s: float) -> None:
        self.limit, self.window_s = limit, window_s
        self._hits: dict[str, deque[float]] = defaultdict(deque)

    def _prune(self, key: str, now: float) -> deque[float]:
        q = self._hits[key]
        while q and now - q[0] > self.window_s:
            q.popleft()
        if not q:
            self._hits.pop(key, None)
            return self._hits[key]
        return q

    def retry_after(self, key: str) -> int:
        """Seconds until a new hit would be allowed (0 = allowed now). Does not record a hit."""
        now = time.monotonic()
        q = self._prune(key, now)
        if len(q) < self.limit:
            return 0
        return max(1, int(self.window_s - (now - q[0])) + 1)

    def hit(self, key: str) -> int:
        """Record a hit. Returns 0 if allowed, else seconds to wait (and records nothing)."""
        wait = self.retry_after(key)
        if wait == 0:
            self._hits[key].append(time.monotonic())
        return wait

    def record(self, key: str) -> None:
        self._hits[key].append(time.monotonic())

    def reset(self, key: str) -> None:
        self._hits.pop(key, None)
