"""Nemotron client (OpenAI-compatible API on build.nvidia.com).

Implements the CLAUDE.md hard rules for the LLM client:
  * disk cache keyed by (prompt, image hash)   -> ../cache/nemotron/ (git-ignored)
  * retries with exponential backoff + jitter  -> 429, 5xx, timeouts, connection errors
  * ~40 requests/minute client-side limit
  * explicit timeouts; failures surface as NemotronError so callers can show a
    graceful "still thinking" state instead of hanging
  * secrets only from .env

Privacy (rule 1): NVIDIA's hosted API must not receive personal data. This client
does not look inside images, so callers must only pass images that were already
cropped to the object with faces and licence plates blurred on the phone. Image
bytes are never written to disk or logged here; only their SHA-256 is.
"""

from __future__ import annotations

import asyncio
import base64
import hashlib
import json
import logging
import os
import random
import time
from collections import deque
from dataclasses import dataclass
from pathlib import Path

import openai
from dotenv import load_dotenv
from openai import AsyncOpenAI

log = logging.getLogger("nemotron")

REPO_ROOT = Path(__file__).resolve().parent.parent
load_dotenv(REPO_ROOT / ".env")

DEFAULT_BASE_URL = "https://integrate.api.nvidia.com/v1"
DEFAULT_CACHE_DIR = REPO_ROOT / "cache" / "nemotron"


class NemotronError(Exception):
    """Base error. Callers should catch this and show a graceful fallback."""


class NemotronConfigError(NemotronError):
    """Missing API key or model id."""


class NemotronTimeout(NemotronError):
    """The model did not answer in time, even after retries ("still thinking")."""


class NemotronUnavailable(NemotronError):
    """Rate-limited or server-side failure that persisted through all retries."""


@dataclass
class NemotronReply:
    text: str
    model: str
    cached: bool
    attempts: int  # API calls made for this reply (0 on a cache hit)
    latency_s: float


def image_to_data_url(image: bytes, mime: str = "image/jpeg") -> str:
    return f"data:{mime};base64,{base64.b64encode(image).decode('ascii')}"


class _RateLimiter:
    """Sliding-window limiter: at most `max_calls` per `period` seconds."""

    def __init__(self, max_calls: int, period: float = 60.0) -> None:
        self.max_calls = max_calls
        self.period = period
        self._stamps: deque[float] = deque()
        self._lock = asyncio.Lock()

    async def acquire(self) -> None:
        async with self._lock:
            while True:
                now = time.monotonic()
                while self._stamps and now - self._stamps[0] >= self.period:
                    self._stamps.popleft()
                if len(self._stamps) < self.max_calls:
                    self._stamps.append(now)
                    return
                await asyncio.sleep(self.period - (now - self._stamps[0]))


class NemotronClient:
    def __init__(
        self,
        *,
        api_key: str | None = None,
        model: str | None = None,
        base_url: str | None = None,
        cache_dir: Path | str | None = DEFAULT_CACHE_DIR,
        timeout_s: float = 45.0,
        max_retries: int = 4,
        backoff_base_s: float = 1.0,
        backoff_max_s: float = 20.0,
        requests_per_minute: int = 40,
    ) -> None:
        self.api_key = api_key or os.getenv("NVIDIA_API_KEY")
        self.model = model or os.getenv("NEMOTRON_MODEL")
        if not self.api_key:
            raise NemotronConfigError("NVIDIA_API_KEY is not set (put it in .env)")
        if not self.model:
            raise NemotronConfigError("NEMOTRON_MODEL is not set (exact ID from build.nvidia.com)")

        self.timeout_s = timeout_s
        self.max_retries = max_retries
        self.backoff_base_s = backoff_base_s
        self.backoff_max_s = backoff_max_s
        self.cache_dir = Path(cache_dir) if cache_dir else None
        if self.cache_dir:
            self.cache_dir.mkdir(parents=True, exist_ok=True)

        self._limiter = _RateLimiter(requests_per_minute)
        # We own the retry loop (backoff, Retry-After, rate limiter), so the SDK's is off.
        self._client = AsyncOpenAI(
            api_key=self.api_key,
            base_url=base_url or os.getenv("NVIDIA_BASE_URL", DEFAULT_BASE_URL),
            timeout=timeout_s,
            max_retries=0,
        )

    # ------------------------------------------------------------------ public

    async def chat(
        self,
        prompt: str,
        *,
        image: bytes | None = None,
        image_mime: str = "image/jpeg",
        system: str | None = None,
        max_tokens: int = 1024,
        temperature: float = 0.0,
        thinking: bool = True,
        response_format: dict | None = None,
        use_cache: bool = True,
    ) -> NemotronReply:
        """One text prompt, optionally with one image. Returns the model's text.

        thinking=False turns the model's hidden reasoning off (several times faster; fine
        for simple tasks such as identification). response_format is passed through, e.g.
        {"type": "json_schema", "json_schema": {...}} to constrain the output.
        """
        image_hash = hashlib.sha256(image).hexdigest() if image else None
        key = self._cache_key(prompt, image_hash, system, max_tokens, temperature, thinking, response_format)

        if use_cache and (hit := self._cache_get(key)) is not None:
            log.info("cache hit %s", key[:12])
            return NemotronReply(text=hit, model=self.model, cached=True, attempts=0, latency_s=0.0)

        user_content: str | list[dict]
        if image is not None:
            user_content = [
                {"type": "text", "text": prompt},
                {"type": "image_url", "image_url": {"url": image_to_data_url(image, image_mime)}},
            ]
        else:
            user_content = prompt
        messages: list[dict] = []
        if system:
            messages.append({"role": "system", "content": system})
        messages.append({"role": "user", "content": user_content})

        started = time.monotonic()
        text, attempts = await self._complete_with_retries(
            messages,
            max_tokens=max_tokens,
            temperature=temperature,
            thinking=thinking,
            response_format=response_format,
        )
        latency = time.monotonic() - started

        if use_cache:
            self._cache_put(key, text, image_hash)
        return NemotronReply(
            text=text, model=self.model, cached=False, attempts=attempts, latency_s=latency
        )

    async def aclose(self) -> None:
        await self._client.close()

    # ----------------------------------------------------------------- private

    async def _complete_with_retries(
        self,
        messages: list[dict],
        *,
        max_tokens: int,
        temperature: float,
        thinking: bool = True,
        response_format: dict | None = None,
    ) -> tuple[str, int]:
        last_exc: Exception | None = None
        total_attempts = self.max_retries + 1

        extra: dict = {}
        if response_format is not None:
            extra["response_format"] = response_format
        if not thinking:
            extra["extra_body"] = {"chat_template_kwargs": {"enable_thinking": False}}

        for attempt in range(1, total_attempts + 1):
            await self._limiter.acquire()
            try:
                resp = await self._client.chat.completions.create(
                    model=self.model,
                    messages=messages,
                    max_tokens=max_tokens,
                    temperature=temperature,
                    **extra,
                )
                text = (resp.choices[0].message.content or "").strip()
                if not text:
                    # Not retried and not cached: usually reasoning ate the token budget.
                    raise NemotronError(
                        f"empty reply (finish_reason={resp.choices[0].finish_reason}); "
                        "try a larger max_tokens"
                    )
                return text, attempt
            except NemotronError:
                raise
            except (openai.APITimeoutError, openai.APIConnectionError, openai.RateLimitError) as exc:
                last_exc = exc
                retry_after = _retry_after(exc)
            except openai.APIStatusError as exc:
                if exc.status_code < 500:  # 4xx other than 429: our fault, retrying won't help
                    raise NemotronError(f"API error {exc.status_code}: {exc.message}") from exc
                last_exc = exc
                retry_after = _retry_after(exc)

            if attempt == total_attempts:
                break
            delay = self._backoff(attempt, retry_after)
            log.warning(
                "nemotron attempt %d/%d failed (%s); retrying in %.1fs",
                attempt, total_attempts, type(last_exc).__name__, delay,
            )
            await asyncio.sleep(delay)

        if isinstance(last_exc, openai.APITimeoutError):
            raise NemotronTimeout(
                f"no answer within {self.timeout_s:.0f}s after {total_attempts} attempts"
            ) from last_exc
        raise NemotronUnavailable(
            f"{type(last_exc).__name__} after {total_attempts} attempts: {last_exc}"
        ) from last_exc

    def _backoff(self, attempt: int, retry_after: float | None) -> float:
        delay = min(self.backoff_max_s, self.backoff_base_s * 2 ** (attempt - 1))
        delay *= random.uniform(0.5, 1.0)  # jitter
        if retry_after is not None:
            delay = max(delay, min(retry_after, self.backoff_max_s))
        return delay

    # cache -------------------------------------------------------------------

    def _cache_key(
        self, prompt: str, image_hash: str | None, system: str | None,
        max_tokens: int, temperature: float,
        thinking: bool = True, response_format: dict | None = None,
    ) -> str:
        # (prompt, image hash) per CLAUDE.md, plus everything else that changes the answer.
        parts: list = [self.model, system, prompt, image_hash, max_tokens, temperature]
        if not thinking or response_format is not None:  # defaults keep the old keys valid
            parts += [thinking, response_format]
        payload = json.dumps(parts, ensure_ascii=False, sort_keys=True)
        return hashlib.sha256(payload.encode("utf-8")).hexdigest()

    def _cache_path(self, key: str) -> Path | None:
        return self.cache_dir / f"{key}.json" if self.cache_dir else None

    def _cache_get(self, key: str) -> str | None:
        path = self._cache_path(key)
        if not path or not path.exists():
            return None
        try:
            return json.loads(path.read_text("utf-8"))["text"]
        except (OSError, ValueError, KeyError):
            return None  # corrupt entry: treat as a miss

    def _cache_put(self, key: str, text: str, image_hash: str | None) -> None:
        path = self._cache_path(key)
        if not path:
            return
        entry = {"text": text, "model": self.model, "image_sha256": image_hash, "cached_at": time.time()}
        tmp = path.with_suffix(".tmp")
        try:
            tmp.write_text(json.dumps(entry, ensure_ascii=False), "utf-8")
            tmp.replace(path)  # atomic
        except OSError as exc:
            log.warning("cache write failed: %s", exc)


def _retry_after(exc: Exception) -> float | None:
    response = getattr(exc, "response", None)
    if response is None:
        return None
    try:
        return float(response.headers.get("retry-after"))
    except (TypeError, ValueError):
        return None
