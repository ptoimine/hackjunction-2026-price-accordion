"""coach: Nemotron explains the numbers money.py computed, in plain language (CLAUDE.md rule 2).

The model never calculates. It gets a FACTS block (the customer's typical month, what the price means, a
table of every what-if it may quote) and is told to use only those numbers. If Nemotron is unreachable the
answer falls back to the ready-made sentence from money.py, so the coach always says something grounded.
"""

from __future__ import annotations

import json
import logging

import money
from nemotron import NemotronError

log = logging.getLogger("coach")

SYSTEM_PROMPT = (
    "You are a friendly, honest money coach for young adults in Finland. You explain what a price means for the "
    "person's own money. You are not a licensed financial adviser and you never recommend specific investments, "
    "loans or products. You NEVER do arithmetic and never invent numbers: use only the numbers in FACTS, "
    "exactly as written. If the question needs a number that is not in FACTS, say you do not have it. "
    "The data is synthetic example data; treat it as the person's real month without saying 'synthetic' unless asked. "
    "If FACTS has thing_being_considered, its field in_short is the correct conclusion for that price: your answer "
    "must agree with it and never contradict it. Only say the person can afford something when verdict is "
    "fits-this-week or fits-this-month; for save-up, out-of-reach or no-room say it needs saving up or is out of reach. "
    "left_over_per_month is the money still free after everything else; moved_to_savings_per_month is a separate item."
)

_PROMPT = """FACTS (the person's typical month from their account history, in euros):
{facts}

QUESTION: {question}

Answer in the same language as the question (English or Finnish), in 2 to 4 short plain sentences. Name the
spending basket that matters (Mandatory regular, Mandatory irregular or Everyday leaks) and give one concrete,
kind next step. No bullet points, no headings."""

QUESTION_FALLBACKS = {
    "no-price": "Here is your typical month: €{income} comes in, €{regular} goes to regular must-pays, €{irregular} to lumpy must-pays "
    "and €{leaks} to everyday leaks, which leaves about €{spare} a month.",
}


def facts(profile: dict, context: dict | None) -> dict:
    """What the model may use: the typical month, the price context (if any) and the what-if table."""
    m, w = profile["per_month"], profile["per_week"]
    block: dict = {
        "typical_month": {
            "money_in_per_month": m["income"],
            "regular_must_pays_per_month": m["regular"],
            "lumpy_must_pays_per_month": m["irregular"],
            "everyday_leaks_per_month": m["leaks"],
            "moved_to_savings_per_month": m["saved"],
            "left_over_per_month": m["spare"],
        },
        "typical_week": {"everyday_leaks_per_week": w["leaks"], "left_over_per_week": w["spare"]},
        "baskets": [{"basket": b["title"], "per_month": b["per_month"], "categories": b["categories"]} for b in profile["baskets"]],
        "leaks_by_category_per_month": profile.get("leaks_by_category", {}),
        "account_balance": profile["balance_eur"],
        "what_if_savings_per_month": money.what_if_table(profile),
    }
    if profile.get("peers"):
        block["peers"] = profile["peers"]
    if context:
        block["thing_being_considered"] = {
            k: context[k]
            for k in (
                "name", "kind", "price_eur", "price_basis", "weeks_of_leaks", "pct_of_monthly_income", "pct_of_spare_money",
                "months_to_save", "verdict", "balance_after_purchase_eur", "would_overdraw", "what_if_cut_leaks_20",
            )
        }
        block["thing_being_considered"]["in_short"] = context["summary"]
        block["thing_being_considered"]["basket"] = context["basket"]["title"]
        block["thing_being_considered"]["why_this_basket"] = context["basket"]["why"]
    return block


def fallback_answer(profile: dict, context: dict | None) -> str:
    if context:
        return context["summary"]
    return QUESTION_FALLBACKS["no-price"].format(**profile["per_month"])


async def answer(client, question: str, profile: dict, context: dict | None) -> dict:
    """{answer, source, basket, numbers}: grounded in `facts`; falls back to the computed summary on any model error."""
    block = facts(profile, context)
    basket = context["basket"] if context else None
    base = {"basket": basket, "numbers": block}
    if client is None:
        return {**base, "answer": fallback_answer(profile, context), "source": "fallback", "note": "Nemotron is not configured"}
    prompt = _PROMPT.format(facts=json.dumps(block, ensure_ascii=False, indent=1), question=question.strip())
    try:
        reply = await client.chat(prompt, system=SYSTEM_PROMPT, max_tokens=400, temperature=0.3, thinking=False)
    except NemotronError as exc:
        log.warning("coach fell back to the computed summary: %s", exc)
        return {**base, "answer": fallback_answer(profile, context), "source": "fallback", "note": "the model was unavailable"}
    text = " ".join(reply.text.split())
    if not text:
        return {**base, "answer": fallback_answer(profile, context), "source": "fallback", "note": "the model gave no answer"}
    return {**base, "answer": text, "source": "nemotron"}
