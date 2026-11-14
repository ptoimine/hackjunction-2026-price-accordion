"""In-memory store of recent looks and their background price jobs.

POST /look answers with the identification straight away (~2 s) and starts the price lookup
(~6-20 s) as a background job. The phone polls GET /look/{id} and sees the price range squeeze as
each source answers. The user confirms or corrects what it is and guesses while this runs ("the
guess hides latency"). A correction (POST /confirm) cancels the running job and starts a new one.

Nothing here is persisted and no image is kept, only the identification and the price snapshot.
"""

from __future__ import annotations

import asyncio
import logging
import secrets
import time
from typing import Any

from price import price_car_cached
from products import price_product_cached
from score import guess_result
from see import PRICEABLE_KINDS

log = logging.getLogger("looks")

MIN_CONFIDENCE_TO_PRICE = 0.5
MIN_CONFIDENCE_TO_PRICE_ITEM = 0.3  # a generic name ("wooden chair") is a safe guess; the user confirms anyway


def price_eligibility(identification: dict, confirmed: bool = False) -> str | None:
    """None if we can price this; otherwise a plain-language reason why not.

    A user-confirmed identification skips the confidence bar: the user vouches for it.
    """
    kind = identification.get("kind")
    if kind not in PRICEABLE_KINDS:
        if kind == "building":
            return "flats and houses are not priced yet (prices per square metre are coming)"
        if kind == "menu":
            return "menus are not priced yet"
        return "this does not look like something with a shop price; tell me what it is if it does"
    if kind == "item":
        # any purchasable object: a name is enough (a brand and exact model are a bonus)
        if not identification.get("model"):
            return "I could not tell what this object is; tell me what it is"
        if not confirmed and identification.get("confidence", 0.0) < MIN_CONFIDENCE_TO_PRICE_ITEM:
            return "not sure what this is; tell me what it is"
        return None
    if not identification.get("make") or not identification.get("model"):
        return "the make and model are not clear enough to price; tell me what it is"
    if not confirmed and identification.get("confidence", 0.0) < MIN_CONFIDENCE_TO_PRICE:
        return (
            f"not confident enough about the model (confidence {identification.get('confidence', 0.0):.2f}) "
            "to price it; tell me what it is"
        )
    return None


def initial_price(identification: dict, source: Any, confirmed: bool = False) -> dict:
    """The price object a look starts with, before any job has reported."""
    reason = price_eligibility(identification, confirmed)
    if reason is not None:
        return {"status": "skipped", "reason": reason, "range": None}
    if source is None:
        return {"status": "unavailable", "reason": "Context.dev is not configured on the server", "range": None}
    return {"status": "searching", "range": None, "sources": [], "notes": []}


class LookStore:
    def __init__(self, ttl_s: float = 3600.0, max_items: int = 200) -> None:
        self.ttl_s = ttl_s
        self.max_items = max_items
        self._items: dict[str, dict[str, Any]] = {}
        self._tasks: set[asyncio.Task] = set()

    def create(self, identification: dict, image: dict, price: dict) -> dict:
        self._purge()
        look_id = secrets.token_urlsafe(8)
        record = {
            "look_id": look_id,
            "identification": identification,
            "confirmed": False,
            "image": image,
            "price": price,
            "guess": None,
            "created_at": time.time(),
            "_job": 0,  # counts price jobs; a stale job never overwrites a newer one
            "_task": None,
        }
        self._items[look_id] = record
        return record

    def get(self, look_id: str) -> dict | None:
        self._purge()
        return self._items.get(look_id)

    def set_guess(self, record: dict, guess_eur: int) -> None:
        """Lock in the guess. It cannot be changed afterwards: guess first, then see."""
        record["guess"] = {"guess_eur": guess_eur, "submitted_at": time.time()}

    @staticmethod
    def guess_view(record: dict) -> dict | None:
        """The guess with its result, once the price is final (the median still moves while reading)."""
        guess = record.get("guess")
        if guess is None:
            return None
        price = record["price"]
        result = None
        if price.get("status") == "done" and price.get("range"):
            result = guess_result(guess["guess_eur"], price["range"], price.get("price_basis", "new"))
        return {"guess_eur": guess["guess_eur"], "result": result}

    def _purge(self) -> None:
        now = time.time()
        for key in [k for k, v in self._items.items() if now - v["created_at"] > self.ttl_s]:
            self._stop(self._items[key])
            del self._items[key]
        while len(self._items) > self.max_items:  # oldest first
            self._stop(self._items[next(iter(self._items))])
            del self._items[next(iter(self._items))]

    # ---------------------------------------------------------------- price jobs

    @staticmethod
    def _stop(record: dict) -> None:
        task = record.get("_task")
        if task is not None and not task.done():
            task.cancel()

    def start_price_job(self, record: dict, source: Any) -> None:
        """(Re)start the price lookup for the record's current identification."""
        self._stop(record)
        record["_job"] += 1
        ident = record["identification"]
        if ident["kind"] == "car":
            years = tuple(ident["year_range"]) if ident.get("year_range") else None
            stream = price_car_cached(source, ident["make"], ident["model"], years)
        else:
            stream = price_product_cached(
                source, ident["kind"], ident.get("make") or "", ident["model"], ident.get("variant"),
                search=ident.get("search_fi"),
            )
        task = asyncio.create_task(self._run(record, record["_job"], stream))
        record["_task"] = task
        self._tasks.add(task)  # keep a reference so it is not garbage-collected mid-flight
        task.add_done_callback(self._tasks.discard)

    async def _run(self, record: dict, job: int, stream) -> None:
        try:
            async for snapshot in stream:
                if record["_job"] != job:  # the identification was corrected meanwhile
                    return
                record["price"] = snapshot
        except asyncio.CancelledError:
            raise
        except Exception as exc:  # the job must never die silently with a "searching" status
            log.exception("price job failed")
            if record["_job"] == job:
                record["price"] = {
                    "status": "failed",
                    "notes": [f"price lookup crashed: {type(exc).__name__}"],
                    "range": None,
                    "sources": [],
                }

    def correct(self, record: dict, identification: dict, source: Any) -> None:
        """The user says what it is: replace the identification and price it again."""
        record["identification"] = identification
        record["confirmed"] = True
        record["price"] = initial_price(identification, source, confirmed=True)
        if record["price"]["status"] == "searching":
            self.start_price_job(record, source)
        else:
            self._stop(record)
            record["_job"] += 1

    async def aclose(self) -> None:
        for task in list(self._tasks):
            task.cancel()
        await asyncio.gather(*self._tasks, return_exceptions=True)
