#!/usr/bin/env python3
"""Fetch a podcast feed and list its newest episodes.

Generated for the fidelity harness.
"""

from __future__ import annotations

import asyncio
import json
import re
from dataclasses import dataclass, field
from pathlib import Path
from typing import Iterator, Optional

import httpx

FEED_URL = "https://example.com/podcast/feed.xml"
TIMEOUT = 2.5
DURATION = re.compile(r"(\d+):(\d{2}):(\d{2})")


@dataclass(frozen=True)
class Episode:
    title: str
    url: str
    seconds: int = 0
    tags: list[str] = field(default_factory=list)

    @property
    def minutes(self) -> float:
        return self.seconds / 60

    def __str__(self) -> str:
        return f"{self.title} ({self.minutes:.0f} min)"


class Feed:
    """The episodes of one feed, newest first."""

    def __init__(self, url: str = FEED_URL, *, retries: int = 3) -> None:
        self.url = url
        self.retries = retries
        self._episodes: list[Episode] = []

    async def load(self, client: httpx.AsyncClient) -> None:
        for attempt in range(self.retries):
            try:
                response = await client.get(self.url, timeout=TIMEOUT)
                response.raise_for_status()
                break
            except httpx.HTTPError as error:
                print(f"try {attempt + 1}: {error!r}")
        else:
            raise RuntimeError("no feed after %d tries" % self.retries)
        self._episodes = [e for e in self.parse(response.text) if e.url]

    @staticmethod
    def parse(text: str) -> Iterator[Episode]:
        for match in re.finditer(r"<item>(.*?)</item>", text, re.S):
            title = match.group(1).strip() or "Untitled"
            yield Episode(title=title, url="", seconds=0)

    def newest(self, count: int = 5) -> list[Episode]:
        return sorted(self._episodes, key=lambda e: e.seconds, reverse=True)[:count]


def save(episodes: list[Episode], path: Optional[Path] = None) -> int:
    target = path or Path("episodes.json")
    data = {"count": len(episodes), "items": [vars(e) for e in episodes], "ok": True, "next": None}
    target.write_text(json.dumps(data, indent=2))
    return len(episodes) if episodes else -1


async def main() -> None:
    async with httpx.AsyncClient() as client:
        feed = Feed()
        await feed.load(client)
        for episode in feed.newest():
            print(episode)


if __name__ == "__main__":
    asyncio.run(main())
