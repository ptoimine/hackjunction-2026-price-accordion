"""see: identify what is in a photo with Nemotron (vision).

The phone sends a crop that is already face-blurred (CLAUDE.md hard rule 1). This module
only asks the model for *what* the object is (make/model/year range, or brand/model/variant for
headphones, phones and laptops), never whose it is, and never for licence plates. Prices are a
separate step (price.py for cars, products.py for the product kinds).
"""

from __future__ import annotations

import json
import re
from typing import Literal

from pydantic import BaseModel, ValidationError, field_validator

from nemotron import NemotronClient, NemotronReply

Kind = Literal["car", "headphones", "phone", "laptop", "item", "building", "menu", "other"]
KINDS: tuple[str, ...] = ("car", "headphones", "phone", "laptop", "item", "building", "menu", "other")
# Kinds that have a price engine: price.py for cars, products.py for everything sold in shops.
# "item" is any other purchasable object (furniture, a bike, a jacket, a toy ...): priced from live
# search results by name, not by an exact model.
PRICEABLE_KINDS: tuple[str, ...] = ("car", "headphones", "phone", "laptop", "item")
PRODUCT_KINDS: tuple[str, ...] = ("headphones", "phone", "laptop", "item")

SYSTEM_PROMPT = (
    "You identify everyday objects in photos for a price-guessing app for young adults. "
    "You are precise and honest about uncertainty. You never identify people, never read or "
    "report licence plate numbers, and never describe a person: you identify the object only."
)

_PROMPT = """Identify the main object in this photo.
The camera is aimed at the object nearest the centre of the photo (it may sit a bit off-centre): identify that one.
Reply with ONLY one JSON object, no other text, no markdown:
{{"kind": "car" | "headphones" | "phone" | "laptop" | "item" | "building" | "menu" | "other",
 "make": string or null,
 "model": string or null,
 "variant": string or null,
 "year_range": [first_year, last_year] or null,
 "search_fi": string or null,
 "confidence": number from 0 to 1,
 "description": string}}

Rules:
- kind "car": give make and model (include the generation or trim only if clearly visible).
  year_range is the production years of that generation or facelift, at most about 6 years wide.
- kinds "headphones", "phone", "laptop": make is the brand, model is the product name the way a shopper
  would search for it, with its generation (for example "WH-1000XM5", "iPhone 15", "MacBook Air 13 M2").
  Only name a model you can really tell from a logo, text or a distinctive shape. If you can see the
  brand but not the model, give the brand and set model to null with low confidence.
  variant is a storage size or screen size only when clearly visible, otherwise null. year_range is null.
  Cables, cases and accessories are not the product itself.
- kind "item": ANY other object someone could buy new or used (furniture, a bike, clothing, shoes, a bag, a
  tool, a kitchen appliance, a toy, a musical instrument, sports gear, a watch, a bottle, a book ...). Prefer
  "item" over "other" whenever the object has a shop price. model is what a shopper would search for: the
  specific product name when you can tell it ("Brompton C Line", "Stanley Quencher 1.2L"), otherwise a short
  generic name ("wooden dining chair", "grey wool coat"). make is the brand only when visible, else null.
  search_fi is the same thing as a Finnish shopper search phrase ("tammi ruokapöydän tuoli"), at most five
  words, no price words. search_fi is null for every other kind.
- variant is null for every kind except headphones, phone, laptop and item (a size or capacity only when clearly shown).
- kind "building": a flat block or house; make/model null; year_range is the likely construction decade.
- kind "menu": a cafe or restaurant menu; make/model null.
- kind "other": only things that are not sold in shops (sky, landscape, an empty room) or an unclear photo;
  make/model/year_range null, low confidence.
- confidence is your honest probability that make and model are right. Use below 0.5 when unsure.
- description is one or two plain sentences saying what the object is and what stands out (colour, material,
  condition, notable features), nothing about people.{hint}"""


# Reasoning off + a JSON schema: ~3 s instead of 13-26 s, and valid JSON (measured on
# a test photo of a car; without the schema the no-reasoning reply once had unquoted text).
CHAT_OPTIONS: dict = {
    "thinking": False,
    "max_tokens": 800,
    "response_format": {
        "type": "json_schema",
        "json_schema": {
            "name": "identification",
            "schema": {
                "type": "object",
                "properties": {
                    "kind": {"type": "string", "enum": list(KINDS)},
                    "make": {"type": ["string", "null"]},
                    "model": {"type": ["string", "null"]},
                    "variant": {"type": ["string", "null"]},
                    "year_range": {
                        "type": ["array", "null"],
                        "items": {"type": "integer"},
                        "minItems": 2,
                        "maxItems": 2,
                    },
                    "search_fi": {"type": ["string", "null"]},
                    "confidence": {"type": "number"},
                    "description": {"type": "string"},
                },
                "required": [
                    "kind", "make", "model", "variant", "year_range", "search_fi", "confidence", "description"
                ],
            },
        },
    },
}


class IdentificationParseError(ValueError):
    """The model's reply was not the JSON we asked for."""


class Identification(BaseModel):
    kind: Kind = "other"
    make: str | None = None
    model: str | None = None
    variant: str | None = None  # storage or screen size for products; None for cars
    year_range: tuple[int, int] | None = None
    search_fi: str | None = None  # Finnish shopper search phrase, for kind "item"
    confidence: float = 0.0
    description: str = ""

    @field_validator("kind", mode="before")
    @classmethod
    def _kind(cls, v: object) -> str:
        v = str(v or "").strip().lower()
        return v if v in KINDS else "other"

    @field_validator("make", "model", "variant", "search_fi", mode="before")
    @classmethod
    def _clean_text(cls, v: object) -> str | None:
        if v is None:
            return None
        v = str(v).strip()
        return None if v.lower() in ("", "null", "none", "unknown", "n/a") else v

    @field_validator("year_range", mode="before")
    @classmethod
    def _years(cls, v: object) -> tuple[int, int] | None:
        try:
            first, last = (int(x) for x in v)  # type: ignore[union-attr]
        except (TypeError, ValueError):
            return None
        if first > last:
            first, last = last, first
        return (first, last) if 1900 <= first and last <= 2100 else None

    @field_validator("confidence", mode="before")
    @classmethod
    def _confidence(cls, v: object) -> float:
        try:
            return min(1.0, max(0.0, float(v)))  # type: ignore[arg-type]
        except (TypeError, ValueError):
            return 0.0

    @field_validator("description", mode="before")
    @classmethod
    def _description(cls, v: object) -> str:
        return str(v or "").strip()[:400]


def build_prompt(kind_hint: str | None = None) -> str:
    hint = ""
    if kind_hint and kind_hint.lower() in KINDS and kind_hint.lower() != "other":
        hint = f"\n- The user expects this to be a {kind_hint.lower()}; still answer honestly if it is not."
    return _PROMPT.format(hint=hint)


_FENCE = re.compile(r"^```(?:json)?\s*|\s*```$", re.IGNORECASE)


def parse_identification(text: str) -> Identification:
    """Pull the first JSON object out of the reply (tolerates code fences and chatter)."""
    cleaned = _FENCE.sub("", text.strip())
    start = cleaned.find("{")
    if start < 0:
        raise IdentificationParseError("no JSON object in reply")
    try:
        data, _ = json.JSONDecoder().raw_decode(cleaned[start:])
    except json.JSONDecodeError as exc:
        raise IdentificationParseError(f"invalid JSON: {exc.msg}") from exc
    if not isinstance(data, dict):
        raise IdentificationParseError("JSON is not an object")
    try:
        return Identification.model_validate(data)
    except ValidationError as exc:  # validators are lenient, so this is rare
        raise IdentificationParseError(str(exc)) from exc


async def identify(
    client: NemotronClient,
    image: bytes,
    *,
    mime: str = "image/jpeg",
    kind_hint: str | None = None,
) -> tuple[Identification, NemotronReply]:
    """Ask Nemotron what is in `image`. One retry with a stricter prompt if the reply is not JSON.

    Raises NemotronError subclasses (timeouts, rate limits...) or IdentificationParseError.
    """
    prompt = build_prompt(kind_hint)
    reply = await client.chat(prompt, image=image, image_mime=mime, system=SYSTEM_PROMPT, **CHAT_OPTIONS)
    try:
        return parse_identification(reply.text), reply
    except IdentificationParseError:
        retry = prompt + "\n\nYour previous reply was not valid JSON. Reply with ONLY the JSON object."
        reply = await client.chat(retry, image=image, image_mime=mime, system=SYSTEM_PROMPT, **CHAT_OPTIONS)
        return parse_identification(reply.text), reply
