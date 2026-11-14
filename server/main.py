"""Price Accordion (Hintahaitari) – FastAPI server.

Run: cd server && uv run uvicorn main:app --reload --port 8000

/look identifies the object with Nemotron (cars, headphones, phones, laptops, or any other item with a
shop price) and starts a live price lookup in the background (Context.dev). Poll GET /look/{look_id} for the price as it
narrows. POST /confirm lets the user confirm or correct what it is; POST /guess locks the guess.
GET /money/personas, GET /money/profile and POST /money/context say what a price means for a customer of the
synthetic S-Pankki data (baskets, spare money, what-ifs: plain Python); POST /coach lets Nemotron explain
those numbers.
"""

import io
import logging
import os
from contextlib import asynccontextmanager

from dotenv import load_dotenv
from typing import Literal

from fastapi import FastAPI, HTTPException, Request
from PIL import Image, UnidentifiedImageError
from pydantic import BaseModel, Field, field_validator

import coach
import money
from looks import LookStore, initial_price
from nemotron import (
    REPO_ROOT,
    NemotronClient,
    NemotronConfigError,
    NemotronError,
    NemotronTimeout,
    NemotronUnavailable,
)
from price import ContextDevSource
from see import PRICEABLE_KINDS, IdentificationParseError, identify

load_dotenv(REPO_ROOT / ".env")
log = logging.getLogger("price-accordion")

MAX_LOOK_BYTES = 10 * 1024 * 1024
MIME_BY_FORMAT = {"JPEG": "image/jpeg", "PNG": "image/png", "WEBP": "image/webp"}


@asynccontextmanager
async def lifespan(app: FastAPI):
    # Short per-call timeout and few retries: the phone waits on this request.
    try:
        app.state.nemotron = NemotronClient(timeout_s=25, max_retries=2)
    except NemotronConfigError as exc:
        log.warning("Nemotron not configured: %s", exc)
        app.state.nemotron = None
    try:
        app.state.price_source = ContextDevSource()
    except RuntimeError as exc:
        log.warning("Context.dev not configured, prices disabled: %s", exc)
        app.state.price_source = None
    app.state.looks = LookStore()
    yield
    await app.state.looks.aclose()
    if app.state.nemotron is not None:
        await app.state.nemotron.aclose()
    if app.state.price_source is not None:
        await app.state.price_source.aclose()


app = FastAPI(title="Price Accordion – Hintahaitari", lifespan=lifespan)


def _store(request: Request) -> LookStore:
    if getattr(request.app.state, "looks", None) is None:  # e.g. tests that skip the lifespan
        request.app.state.looks = LookStore()
    return request.app.state.looks


@app.get("/health")
def health() -> dict:
    # Reports only whether secrets are configured, never their values.
    return {
        "status": "ok",
        "nemotron_configured": bool(os.getenv("NVIDIA_API_KEY") and os.getenv("NEMOTRON_MODEL")),
        "context_dev_configured": bool(os.getenv("CONTEXT_DEV_API_KEY")),
    }


@app.post("/look")
async def look(request: Request, kind: str | None = None) -> dict:
    """Identify the object in the photo and start pricing it.

    The iOS app POSTs the face-blurred, centre-cropped JPEG as the raw body
    (Content-Type: image/jpeg). Optional query `kind` (car|building|menu) is a hint.
    The image is held in memory only and never stored. The reply has a `look_id`; for cars,
    `price.status` starts as "searching" and GET /look/{look_id} shows it narrowing.
    """
    body = await request.body()
    if not body:
        raise HTTPException(status_code=400, detail="empty body: send the JPEG as the raw request body")
    if len(body) > MAX_LOOK_BYTES:
        raise HTTPException(status_code=413, detail=f"image larger than {MAX_LOOK_BYTES // (1024 * 1024)} MB")
    try:
        with Image.open(io.BytesIO(body)) as img:
            width, height, fmt = img.width, img.height, img.format
    except (UnidentifiedImageError, OSError):
        raise HTTPException(status_code=415, detail="body is not a readable image")
    mime = MIME_BY_FORMAT.get(fmt or "")
    if mime is None:
        raise HTTPException(status_code=415, detail=f"unsupported image format {fmt}; send JPEG or PNG")

    client: NemotronClient | None = getattr(request.app.state, "nemotron", None)
    if client is None:
        raise HTTPException(
            status_code=503,
            detail={"status": "unavailable", "message": "Nemotron is not configured on the server"},
        )

    try:
        identification, reply = await identify(client, body, mime=mime, kind_hint=kind)
    except NemotronTimeout:
        raise HTTPException(
            status_code=504,
            detail={"status": "thinking", "message": "The model is still thinking. Try again in a moment."},
        )
    except NemotronUnavailable:
        raise HTTPException(
            status_code=503,
            detail={"status": "unavailable", "message": "The model is busy or unreachable. Try again shortly."},
        )
    except IdentificationParseError as exc:
        log.warning("unreadable Nemotron reply: %s", exc)
        raise HTTPException(
            status_code=502,
            detail={"status": "unreadable_reply", "message": "The model's answer could not be understood."},
        )
    except NemotronError as exc:
        log.warning("Nemotron error: %s", exc)
        raise HTTPException(status_code=502, detail={"status": "model_error", "message": str(exc)})

    ident = identification.model_dump()
    source = getattr(request.app.state, "price_source", None)
    price = initial_price(ident, source)

    store = _store(request)
    record = store.create(
        ident, {"format": fmt, "width": width, "height": height, "bytes": len(body)}, price
    )
    if price["status"] == "searching":
        store.start_price_job(record, source)

    return {
        "status": "identified",
        **_look_view(record),
        "model": reply.model,
        "cached": reply.cached,
        "latency_s": round(reply.latency_s, 2),
    }


def _look_view(record: dict) -> dict:
    """The look as the phone sees it (never the private job bookkeeping)."""
    return {
        "look_id": record["look_id"],
        "identification": record["identification"],
        "confirmed": record["confirmed"],
        "price": record["price"],
        "guess": LookStore.guess_view(record),
        "image": record["image"],
    }


@app.get("/look/{look_id}")
async def get_look(look_id: str, request: Request) -> dict:
    """Current state of a look: the identification plus the price as far as it has got.

    `price.status`: searching | reading | done | insufficient | failed | skipped | unavailable.
    Poll every ~1.5 s until it is no longer searching/reading.
    """
    record = _store(request).get(look_id)
    if record is None:
        raise HTTPException(status_code=404, detail="unknown or expired look id")
    return _look_view(record)


class ConfirmIn(BaseModel):
    """What the user says it is. `kind` is needed when the model could not tell."""

    look_id: str
    kind: Literal["car", "headphones", "phone", "laptop", "item"] | None = None
    make: str = Field(default="", max_length=60, description="brand; may be empty for kind item")
    model: str = Field(max_length=60, description="model, or the name of the thing for kind item")
    variant: str | None = Field(default=None, max_length=40, description="storage or screen size, products only")
    year_from: int | None = Field(default=None, ge=1900, le=2100, description="cars only")
    year_to: int | None = Field(default=None, ge=1900, le=2100, description="cars only")

    @field_validator("model")
    @classmethod
    def _not_blank(cls, v: str) -> str:
        v = " ".join(v.split())
        if not v:
            raise ValueError("must not be empty")
        return v

    @field_validator("make")
    @classmethod
    def _tidy_make(cls, v: str) -> str:
        return " ".join((v or "").split())

    @field_validator("variant")
    @classmethod
    def _variant(cls, v: str | None) -> str | None:
        v = " ".join((v or "").split())
        return v or None


@app.post("/confirm")
async def post_confirm(body: ConfirmIn, request: Request) -> dict:
    """Confirm or correct what the model saw, before the guess.

    Sending what it already said just marks it confirmed. Anything else replaces the
    identification (confidence 1.0, the user vouches for it), cancels the running price lookup and
    starts a new one. Not possible once a guess is locked in: the price context would change.
    """
    store = _store(request)
    record = store.get(body.look_id)
    if record is None:
        raise HTTPException(status_code=404, detail="unknown or expired look id")
    if record.get("guess") is not None:
        raise HTTPException(
            status_code=409,
            detail={"status": "already_guessed", "message": "the guess is locked in; look again to change it"},
        )
    current = record["identification"]
    kind = body.kind or (current["kind"] if current["kind"] in PRICEABLE_KINDS else None)
    if kind is None:
        raise HTTPException(status_code=422, detail="say what it is: car, headphones, phone, laptop or another item")
    if kind != "item" and not body.make:
        raise HTTPException(status_code=422, detail="the brand (make) is needed for cars, headphones, phones and laptops")

    years = None
    if kind == "car" and (body.year_from or body.year_to):
        first, last = body.year_from or body.year_to, body.year_to or body.year_from
        years = [min(first, last), max(first, last)]
    corrected = {
        **current,
        "kind": kind,
        "make": body.make,
        "model": body.model,
        "variant": None if kind == "car" else body.variant,
        "year_range": years,
        "confidence": 1.0,
        # the Finnish search phrase belongs to the name the model gave; a new name gets a fresh search
        "search_fi": current.get("search_fi") if (kind == "item" and body.model == current.get("model")) else None,
    }
    same = all(corrected[k] == current.get(k) for k in ("kind", "make", "model", "variant")) and (
        corrected["year_range"] == (list(current["year_range"]) if current.get("year_range") else None)
        or kind != "car"
    )
    if same and record["price"].get("status") not in ("skipped", "unavailable"):
        record["confirmed"] = True  # "yes, that is it": keep the lookup that is already running
    else:
        store.correct(record, corrected, getattr(request.app.state, "price_source", None))
    return _look_view(record)


class GuessIn(BaseModel):
    look_id: str
    guess_eur: int = Field(gt=0, le=10_000_000, description="the user's price guess in whole euros")


@app.post("/guess")
async def post_guess(body: GuessIn, request: Request) -> dict:
    """Lock in the user's guess for a look (guess first, then see the price).

    A guess cannot be changed once locked; sending the same value again is fine (retries).
    `guess.result` is null until the price is final, then it holds the gap in EUR and %, the
    verdict, the score and a ready-made summary sentence. GET /look/{id} shows the same.
    """
    store = _store(request)
    record = store.get(body.look_id)
    if record is None:
        raise HTTPException(status_code=404, detail="unknown or expired look id")
    if record["price"].get("status") in ("skipped", "unavailable"):
        raise HTTPException(status_code=400, detail="this look has no price to guess against")
    existing = record.get("guess")
    if existing is not None and existing["guess_eur"] != body.guess_eur:
        raise HTTPException(
            status_code=409,
            detail={"status": "already_guessed", "guess_eur": existing["guess_eur"]},
        )
    if existing is None:
        store.set_guess(record, body.guess_eur)
    return {"look_id": record["look_id"], "guess": LookStore.guess_view(record), "price_status": record["price"]["status"]}


# ------------------------------------------------------------------------- money coach


def _money(request: Request) -> money.MoneyBook:
    """The S-Pankki synthetic data, loaded once (after scripts/build_money_profiles.py has made the tables)."""
    book = getattr(request.app.state, "money", None)
    if book is None:
        try:
            book = request.app.state.money = money.MoneyBook()
        except FileNotFoundError:
            raise HTTPException(
                status_code=503,
                detail={
                    "status": "unavailable",
                    "message": "the money data is not built: run `cd server && uv run python scripts/build_money_profiles.py`",
                },
            )
    return book


def _profile(request: Request, customer_id: str | None) -> dict:
    book = _money(request)
    if customer_id is None:
        if not book.personas:
            raise HTTPException(status_code=503, detail="no demo customers in the data")
        customer_id = next((p for p in book.personas if p["slot"] == "typical"), book.personas[0])["customer_id"]
    profile = book.profile(customer_id)
    if profile is None:
        raise HTTPException(status_code=404, detail="unknown customer")
    return profile


def _price_context_for(request: Request, profile: dict, price_eur: float | None, look_id: str | None, kind: str, name: str | None) -> dict:
    """What a price means for this customer. The price is given, or taken from a finished look (its median)."""
    basis = "new"
    if look_id is not None:
        record = _store(request).get(look_id)
        if record is None:
            raise HTTPException(status_code=404, detail="unknown or expired look id")
        price = record["price"]
        if not price.get("range"):
            raise HTTPException(status_code=409, detail={"status": "no_price_yet", "message": "this look has no price range yet"})
        price_eur = float(price["range"]["median"])
        basis = price.get("price_basis", "new")
        ident = record["identification"]
        kind = ident.get("kind") if ident.get("kind") in ("car", "headphones", "phone", "laptop", "item") else kind
        name = " ".join(p for p in (ident.get("make"), ident.get("model")) if p) or name
    if price_eur is None:
        raise HTTPException(status_code=422, detail="give price_eur or a look_id")
    return money.price_context(profile, price_eur, kind, name, basis)


@app.get("/money/personas")
async def get_personas(request: Request) -> dict:
    """Three demo customers (young adults of the synthetic data) from a tight to a comfortable month."""
    book = _money(request)
    return {"personas": book.personas, "data": "synthetic: Junction 2026 S-Pankki challenge dataset"}


@app.get("/money/profile")
async def get_profile(request: Request, customer_id: str | None = None) -> dict:
    """A customer's typical month: income, the three baskets, spare money, weekly figures and peers."""
    return _profile(request, customer_id)


class MoneyContextIn(BaseModel):
    customer_id: str | None = None
    price_eur: float | None = Field(default=None, gt=0, le=10_000_000)
    look_id: str | None = None
    kind: str = Field(default="item", max_length=20)
    name: str | None = Field(default=None, max_length=80)


@app.post("/money/context")
async def post_money_context(body: MoneyContextIn, request: Request) -> dict:
    """What a price means for the customer: basket, weeks of everyday leaks, share of spare money, a verdict,
    the 20 % what-if and a ready-made sentence. Everything is computed here, never by the model."""
    profile = _profile(request, body.customer_id)
    return {
        "customer_id": profile["customer_id"],
        "profile": profile,
        "context": _price_context_for(request, profile, body.price_eur, body.look_id, body.kind, body.name),
    }


class CoachIn(MoneyContextIn):
    question: str = Field(min_length=2, max_length=500)


@app.post("/coach")
async def post_coach(body: CoachIn, request: Request) -> dict:
    """Free-text money question -> a plain-language answer from Nemotron, grounded in the computed numbers.

    With a `look_id` or `price_eur` the answer is about that thing. Falls back to the computed sentence if the
    model is unreachable, and says so in `source`."""
    profile = _profile(request, body.customer_id)
    context = None
    if body.price_eur is not None or body.look_id is not None:
        context = _price_context_for(request, profile, body.price_eur, body.look_id, body.kind, body.name)
    client = getattr(request.app.state, "nemotron", None)
    result = await coach.answer(client, body.question, profile, context)
    return {"customer_id": profile["customer_id"], "question": body.question, **result, "context": context}
