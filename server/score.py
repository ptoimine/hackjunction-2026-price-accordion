"""score: compare the user's guess with the real price range.

Plain Python, no LLM arithmetic (CLAUDE.md rule 2). The sentence in `summary` is a template filled
with these numbers, so the phone, the screen reader and the glasses' voice all say the same thing.

Price-sense score: 100 when the guess equals the median, 0 when it is off by a factor of two or
more (half or double). It works on the ratio, so over- and under-guessing are treated alike.
"""

from __future__ import annotations

import math

CLOSE_PCT = 5.0  # within +-5% of the median counts as "close"


def euros(value: float) -> str:
    """12345.6 -> '€12,346' (English style, whole euros)."""
    return f"€{round(value):,}"


def round_for_speech(value: float) -> int:
    """Round the real range for display: to 100 EUR above 2,000, otherwise to 10."""
    step = 100 if value >= 2_000 else 10
    return int(round(value / step) * step)


def guess_result(guess_eur: int, price_range: dict, basis: str = "new") -> dict:
    """Compare a guess with a finished price range ({low, median, high} in EUR).

    `basis` is "used" when the model is only sold used or refurbished now; the sentence says so.
    """
    low, median, high = (float(price_range[k]) for k in ("low", "median", "high"))
    gap_eur = guess_eur - median
    gap_pct = gap_eur / median * 100.0
    in_range = low <= guess_eur <= high
    if abs(gap_pct) <= CLOSE_PCT:
        verdict = "close"
    else:
        verdict = "high" if gap_eur > 0 else "low"
    score = round(100 * max(0.0, 1.0 - abs(math.log(guess_eur / median)) / math.log(2)))

    pct = round(abs(gap_pct))
    if verdict == "close":
        how = f"You were within {int(CLOSE_PCT)}% of the median. Close!"
    elif in_range:
        where = "above" if verdict == "high" else "below"
        how = f"You were inside the real range, {pct}% {where} the median."
    else:
        how = f"You were {pct}% {verdict}."  # "35% low" / "35% high"
    summary = (
        f"You guessed {euros(guess_eur)}. "
        f"The real range{' for used ones' if basis == 'used' else ''} is "
        f"{euros(round_for_speech(low))} to {euros(round_for_speech(high))}, "
        f"median {euros(round_for_speech(median))}. {how}"
    )
    return {
        "guess_eur": guess_eur,
        "gap_eur": round(gap_eur / 10) * 10,
        "gap_pct": round(gap_pct, 1),
        "verdict": verdict,
        "in_range": in_range,
        "score": int(score),
        "summary": summary,
    }
