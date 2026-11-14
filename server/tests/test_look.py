"""Tests for see.py and POST /look. No network: Nemotron is replaced by a fake client.

Run: cd server && uv run pytest -q
"""

import asyncio
import io

import pytest
from fastapi.testclient import TestClient
from PIL import Image

import see
from main import MAX_LOOK_BYTES, app
from nemotron import NemotronError, NemotronReply, NemotronTimeout, NemotronUnavailable

GOOD = '{"kind":"car","make":"Honda","model":"HR-V","year_range":[2016,2021],"confidence":0.9,"description":"A grey SUV."}'


def jpeg(size=(64, 48)) -> bytes:
    buf = io.BytesIO()
    Image.new("RGB", size, (120, 130, 140)).save(buf, "JPEG")
    return buf.getvalue()


class FakeClient:
    """Stands in for NemotronClient. `replies` items are strings or exceptions to raise."""

    def __init__(self, *replies):
        self.replies = list(replies)
        self.calls: list[dict] = []

    async def chat(self, prompt, *, image=None, image_mime="image/jpeg", system=None, **kw):
        self.calls.append({"prompt": prompt, "image": image, "mime": image_mime, "system": system, **kw})
        item = self.replies.pop(0)
        if isinstance(item, Exception):
            raise item
        return NemotronReply(text=item, model="fake-model", cached=False, attempts=1, latency_s=0.5)

    async def aclose(self):
        pass


# ------------------------------------------------------------------ parsing


def test_parse_clean_json():
    r = see.parse_identification(GOOD)
    assert (r.kind, r.make, r.model, r.year_range, r.confidence) == ("car", "Honda", "HR-V", (2016, 2021), 0.9)


def test_parse_tolerates_fences_and_chatter():
    assert see.parse_identification(f"```json\n{GOOD}\n```").make == "Honda"
    assert see.parse_identification(f"Sure! Here you go: {GOOD} Hope that helps.").model == "HR-V"


@pytest.mark.parametrize("text", ["", "no json here", "{not json", "[1, 2, 3]"])
def test_parse_rejects_garbage(text):
    with pytest.raises(see.IdentificationParseError):
        see.parse_identification(text)


def test_parse_normalises_odd_values():
    r = see.parse_identification(
        '{"kind":"Spaceship","make":"null","model":"  ","year_range":[2021,2016],"confidence":7,"description":null}'
    )
    assert r.kind == "other"
    assert r.make is None and r.model is None
    assert r.year_range == (2016, 2021)  # swapped into order
    assert r.confidence == 1.0  # clamped
    assert r.description == ""


def test_implausible_years_dropped():
    assert see.parse_identification('{"kind":"car","year_range":[1066,2021]}').year_range is None
    assert see.parse_identification('{"kind":"car","year_range":"recent"}').year_range is None


def test_prompt_hint_only_for_known_kinds():
    assert "expects this to be a car" in see.build_prompt("car")
    assert "expects" not in see.build_prompt("banana")
    assert "expects" not in see.build_prompt(None)


# ----------------------------------------------------------------- identify()


def test_identify_retries_once_on_non_json():
    fake = FakeClient("I think it is a Honda.", GOOD)
    ident, reply = asyncio.run(see.identify(fake, jpeg()))
    assert ident.model == "HR-V" and len(fake.calls) == 2
    assert "not valid JSON" in fake.calls[1]["prompt"]


def test_identify_gives_up_after_second_bad_reply():
    fake = FakeClient("nope", "still nope")
    with pytest.raises(see.IdentificationParseError):
        asyncio.run(see.identify(fake, jpeg()))
    assert len(fake.calls) == 2


def test_identify_sends_image_and_privacy_system_prompt():
    fake = FakeClient(GOOD)
    img = jpeg()
    asyncio.run(see.identify(fake, img, mime="image/jpeg", kind_hint="car"))
    call = fake.calls[0]
    assert call["image"] == img and call["mime"] == "image/jpeg"
    assert "never read or report licence plate" in call["system"]
    assert call["thinking"] is False  # fast mode: ~3 s instead of 13-26 s
    assert call["response_format"]["json_schema"]["schema"]["required"][0] == "kind"


# ------------------------------------------------------------------- /look


@pytest.fixture
def client():
    c = TestClient(app)
    yield c
    app.state.nemotron = None


def post(client, content, **params):
    return client.post("/look", content=content, headers={"Content-Type": "image/jpeg"}, params=params)


def test_look_identifies(client):
    fake = FakeClient(GOOD)
    app.state.nemotron = fake
    r = post(client, jpeg(), kind="car")
    assert r.status_code == 200
    body = r.json()
    assert body["status"] == "identified"
    assert body["identification"]["make"] == "Honda"
    assert body["identification"]["year_range"] == [2016, 2021]
    assert body["price"]["status"] == "unavailable"  # no listing source configured in this test
    assert body["look_id"]
    assert body["image"] == {"format": "JPEG", "width": 64, "height": 48, "bytes": len(jpeg())}
    assert body["model"] == "fake-model" and body["cached"] is False
    assert "expects this to be a car" in fake.calls[0]["prompt"]


def test_look_input_validation(client):
    app.state.nemotron = FakeClient()
    assert post(client, b"").status_code == 400
    assert post(client, b"not an image").status_code == 415
    assert post(client, b"\0" * (MAX_LOOK_BYTES + 1)).status_code == 413
    gif = io.BytesIO()
    Image.new("P", (4, 4)).save(gif, "GIF")
    assert post(client, gif.getvalue()).status_code == 415


def test_look_without_nemotron_is_503(client):
    app.state.nemotron = None
    r = post(client, jpeg())
    assert r.status_code == 503 and r.json()["detail"]["status"] == "unavailable"


@pytest.mark.parametrize(
    "error, status, label",
    [
        (NemotronTimeout("slow"), 504, "thinking"),
        (NemotronUnavailable("busy"), 503, "unavailable"),
        (NemotronError("API error 400: bad image"), 502, "model_error"),
    ],
)
def test_look_maps_model_errors(client, error, status, label):
    app.state.nemotron = FakeClient(error)
    r = post(client, jpeg())
    assert r.status_code == status and r.json()["detail"]["status"] == label


def test_look_unreadable_reply_is_502(client):
    app.state.nemotron = FakeClient("garbage", "more garbage")
    r = post(client, jpeg())
    assert r.status_code == 502 and r.json()["detail"]["status"] == "unreadable_reply"
