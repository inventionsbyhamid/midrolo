"""Unit tests for script/platform_stats.py (bin/platform-stats). No network: the connectors' own code runs, with
requests.get and requests.post (Spotify's sign in) and requests.Session.get (every data call) faked.

Run: python3 -m unittest discover -s test/python   (with requirements-stats.txt installed)

Every payload here is hand written, shaped like the real answers (key names from Midrolo's live check and the
connectors' source); none of it is real data.
"""

from __future__ import annotations

import contextlib
import datetime as dt
import email.utils
import importlib.util
import io
import json
import os
import pathlib
import subprocess
import sys
import time
import unittest
from unittest import mock

import requests
from loguru import logger

ROOT = pathlib.Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "script" / "platform_stats.py"
spec = importlib.util.spec_from_file_location("platform_stats", SCRIPT)
ps = importlib.util.module_from_spec(spec)
spec.loader.exec_module(ps)

TODAY = dt.date(2026, 10, 30)
SPOTIFY_SHOW = "4rOoJ6Egrf8K2IrywzwOMk"
APPLE_SHOW = "1500000001"
SP_DC = "AQDfakeSpDcCookieValue-0123456789abcdefSECRET"
SP_KEY = "11111111-2222-3333-4444-fakespkeySECRET"
MYACINFO = "DAWTKNV2fakeMyacinfo|value=with|pipes-SECRET"
ITCTX = "eyJmakeItctxSECRET0123456789"
BEARER = "BQfakeBearerTokenSECRET-abcdefghijklmnop"
CACHED = "BQcachedBearerSECRET-from-an-earlier-run"
ALL_SECRETS = (SP_DC, SP_KEY, MYACINFO, ITCTX, BEARER, CACHED, "SECRET")


def day_range(start: str, end: str):
    day, last = dt.date.fromisoformat(start), dt.date.fromisoformat(end)
    while day <= last:
        yield day.isoformat()
        day += dt.timedelta(days=1)


class FakeResponse:
    def __init__(self, status=200, payload=None, text=None, headers=None):
        self.status_code = status
        self._payload = payload
        self.headers = headers or {}
        self.text = text if text is not None else (json.dumps(payload) if payload is not None else "")

    @property
    def ok(self):
        return self.status_code < 400

    def json(self):
        if self._payload is None:
            raise requests.exceptions.JSONDecodeError("Expecting value", self.text or " ", 0)
        return self._payload

    def raise_for_status(self):
        if self.status_code >= 400:
            raise requests.exceptions.HTTPError(f"{self.status_code} for url with {SP_DC}", response=self)


# --------------------------------------------------------------------------------------------------------------------
# Hand written payloads

SPOTIFY_METADATA = {
    "artworkUrl": "https://i.scdn.co/image/fake", "categories": ["Business"], "consumptionOrder": "EPISODIC",
    "coverImage": "https://i.scdn.co/image/fake", "description": "A made up show.", "explict": False,
    "followers": 212, "hasPassthroughEnabled": False, "id": SPOTIFY_SHOW, "language": "en", "listeners": 1830,
    "name": "  The Made Up Show\n", "network": {"id": "n", "name": "Indie", "doingBusinessAs": "Indie"},
    "published": True, "publisher": "Made Up Media", "releaseDate": "2024-03-04", "shouldAllowVideoReplace": False,
    "sparkLine": [3, 4, 5], "starts": 9100, "streams": 7400,
}

SPOTIFY_AGGREGATE = {
    "count": 40, "start": "2026-09-30", "end": "2026-10-29",
    "ageFacetedCounts": {
        "0-17": {"counts": {"FEMALE": 0, "MALE": 0, "NON_BINARY": 0, "NOT_SPECIFIED": 0}},
        "18-22": {"counts": {"FEMALE": 2, "MALE": 2, "NON_BINARY": 0, "NOT_SPECIFIED": 0}},
        "23-27": {"counts": {"FEMALE": 4, "MALE": 6, "NON_BINARY": 0, "NOT_SPECIFIED": 0}},
        "28-34": {"counts": {"FEMALE": 6, "MALE": 8, "NON_BINARY": 1, "NOT_SPECIFIED": 1}},
        "35-44": {"counts": {"FEMALE": 3, "MALE": 3, "NON_BINARY": 0, "NOT_SPECIFIED": 0}},
        "45-59": {"counts": {"FEMALE": 1, "MALE": 1, "NON_BINARY": 0, "NOT_SPECIFIED": 0}},
        "60-150": {"counts": {"FEMALE": 0, "MALE": 0, "NON_BINARY": 0, "NOT_SPECIFIED": 0}},
        "unknown": {"counts": {"FEMALE": 0, "MALE": 0, "NON_BINARY": 0, "NOT_SPECIFIED": 2}},
    },
    "countryFacetedCounts": {
        "United States": {"counts": {"FEMALE": 8, "MALE": 12, "NON_BINARY": 0, "NOT_SPECIFIED": 0}, "countryCode": "US"},
        "Canada": {"counts": {"FEMALE": 4, "MALE": 4, "NON_BINARY": 1, "NOT_SPECIFIED": 1}, "countryCode": "CA"},
        "United Kingdom": {"counts": {"FEMALE": 4, "MALE": 4, "NON_BINARY": 0, "NOT_SPECIFIED": 2},
                           "countryCode": "gb"},
    },
    "genderedCounts": {"counts": {"FEMALE": 16, "MALE": 20, "NON_BINARY": 1, "NOT_SPECIFIED": 3}},
}

APPLE_LISTENERS = {
    "measure": "LISTENERS", "dimension": "BY_EPISODES",
    "content": [["1000000000002", "Episode two", "2026-10-07T05:00:00Z", -1.0, None],
                ["1000000000001", "Episode one", "2026-09-23T05:00:00Z", -1.0, None]],
    "episodesPlayCount": {"1000000000002": {"latestValue": {
        "episodeid": "1000000000002", "followstate": "*", "playscount": 210.0, "podcastid": APPLE_SHOW,
        "timebucket": 20261001.0, "totaltimelistened": 41000.0, "uniqueengagedlistenerscount": 30.0,
        "uniquelistenerscount": 55.0}}},
    "episodesPlayCountTrends": {"1000000000002": [{
        "episodeid": "1000000000002", "followstate": "*", "playscount": 20.0, "podcastid": APPLE_SHOW,
        "timebucket": 20261007.0, "totaltimelistened": 4000.0, "uniqueengagedlistenerscount": 3.0,
        "uniquelistenerscount": 6.0}]},
    "showPlayCount": {
        "latestValue": {"followstate": "*", "playscount": 640.0, "podcastid": APPLE_SHOW, "timebucket": 20261001.0,
                        "totaltimelistened": 152000.0, "uniqueengagedlistenerscount": 81.0,
                        "uniquelistenerscount": 133.0},
        "previousValue": {"followstate": "*", "playscount": 590.0, "podcastid": APPLE_SHOW,
                          "timebucket": 20260901.0, "totaltimelistened": 140000.0,
                          "uniqueengagedlistenerscount": 75.0, "uniquelistenerscount": 128.0},
    },
    "showPlayCountTrends": [
        {"followstate": "*", "playscount": 300.0, "podcastid": APPLE_SHOW, "timebucket": 20261001.0,
         "totaltimelistened": 70000.0, "uniqueengagedlistenerscount": 40.0, "uniquelistenerscount": 70.0},
        {"followstate": "*", "playscount": 340.0, "podcastid": APPLE_SHOW, "timebucket": 20261015.0,
         "totaltimelistened": 82000.0, "uniqueengagedlistenerscount": 45.0, "uniquelistenerscount": 80.0},
        {"followstate": "*", "playscount": 999.0, "podcastid": APPLE_SHOW, "timebucket": 20261101.0,
         "totaltimelistened": 1.0, "uniqueengagedlistenerscount": 1.0, "uniquelistenerscount": 1.0},
    ],
    "showTopCities": ["5128581", "6167865"],
    "showTopCountries": ["840", "124", "826", "999"],
}

APPLE_FOLLOWERS = {
    "measure": "FOLLOWERS",
    "allTimeFollowers": {"base": {"previous": 400.0, "current": 410.0}, "all": {"previous": 410.0, "current": 418.0}},
    "changeInFollowers": {"lost": {"previous": 1.0, "current": 2.0}, "gained": {"previous": 4.0, "current": 10.0}},
    "followerAllTimeTrends": [[20261001.0, 450.0, 40.0], [20261030.0, 460.0, 42.0], [20261015.0, 455.0, 41.0]],
    "followerGrowthTrends": [[20261010.0, 3.0, 1.0]],
}

APPLE_EPISODES = {"content": {"results": {
    "1000000000002": {"id": "1000000000002", "name": "Episode two", "collectionName": "The Made Up Show",
                      "podcastEpisodeGuid": "guid-2", "podcastEpisodeType": "full", "kind": "podcastEpisode",
                      "releaseDateTime": "2026-10-07T05:00:00Z", "releaseDate": "2026-10-07",
                      "offers": [{"assets": [{"duration": 1800.0}], "download": {"url": "https://example.com/2.mp3"}}]},
}}, "episodesPlayCount": {}}

APPLE_COUNTRIES = {"measure": "PLAYS", "dimension": "BY_COUNTRY",
                   "showTopCountries": {"840": {"latestValue": 400.0}, "124": {"latestValue": 160.0},
                                        "826": {"latestValue": 80.0}}}


# --------------------------------------------------------------------------------------------------------------------
# Fakes for the network


class FakeSpotify:
    """Spotify's sign in (requests.get, requests.post) and data calls (requests.Session.get)."""

    def __init__(self, routes=None, auth="ok", bearers=(BEARER,)):
        self.routes = routes or {}
        self.auth = auth
        self.auth_calls = 0
        self.calls = []
        self.bearers = set(bearers)  # the tokens Spotify still accepts; any other gets a 401
        self.bearers_used = []

    def auth_get(self, url, params=None, cookies=None, timeout=None, **kwargs):
        assert url == "https://accounts.spotify.com/oauth2/v2/auth"
        assert timeout is not None and timeout[1] <= ps.READ_TIMEOUT, "sign in must use the helper's timeouts"
        assert cookies["sp_dc"] == SP_DC
        self.auth_calls += 1
        auth = self.auth(self.auth_calls) if callable(self.auth) else self.auth
        if isinstance(auth, FakeResponse):
            return auth
        if auth == "login_required":
            return FakeResponse(200, text='<script>const authorizationResponse = {type: "authorization_response", '
                                          'response: {error: "login_required", state: "x"}};</script>')
        if isinstance(auth, int):
            return FakeResponse(auth, text=f"error page mentioning {SP_DC}")
        return FakeResponse(200, text='<script>const authorizationResponse = {type: "authorization_response", '
                                      f'response: {{code: "AUTHCODE", state: "{params["state"]}"}}}};</script>')

    def auth_post(self, url, data=None, timeout=None, **kwargs):
        assert url == "https://accounts.spotify.com/api/token" and data["code"] == "AUTHCODE"
        return FakeResponse(200, payload={"access_token": BEARER, "expires_in": 3600})

    def session_get(self, session, url, params=None, headers=None, cookies=None, timeout=None, allow_redirects=True):
        assert allow_redirects is False and timeout is not None
        assert url.startswith(f"{ps.SPOTIFY_BASE_URL}/shows/{SPOTIFY_SHOW}/")
        endpoint = url.rsplit("/", 1)[-1]
        self.calls.append((endpoint, dict(params or {})))
        bearer = headers["Authorization"].removeprefix("Bearer ")
        self.bearers_used.append(bearer)
        if bearer not in self.bearers:
            return FakeResponse(401, {"error": "token expired"})
        handler = self.routes.get(endpoint) or DEFAULT_SPOTIFY_ROUTES[endpoint]
        return handler(dict(params or {}))

    @contextlib.contextmanager
    def installed(self):
        with mock.patch.object(requests, "get", self.auth_get), mock.patch.object(requests, "post", self.auth_post), \
                mock.patch.object(requests.Session, "get", lambda session, url, **kw: self.session_get(session, url, **kw)):
            yield self


def spotify_streams(params):
    return FakeResponse(200, {"detailedStreams": [{"date": day, "starts": 3, "streams": 2}
                                                  for day in day_range(params["start"], params["end"])]})


def spotify_listeners(params):
    return FakeResponse(200, {"counts": [{"date": day, "count": 1} for day in day_range(params["start"], params["end"])]})


DEFAULT_SPOTIFY_ROUTES = {
    "metadata": lambda params: FakeResponse(200, SPOTIFY_METADATA),
    "detailedStreams": spotify_streams,
    "listeners": spotify_listeners,
    "aggregate": lambda params: FakeResponse(200, {**SPOTIFY_AGGREGATE, "start": params["start"], "end": params["end"]}),
    "followers": lambda params: FakeResponse(200, {"counts": [{"date": params["end"], "count": 99}]}),
}


def npe_until(last_good_end: str, handler):
    """Spotify's 500 for a window whose numbers aren't computed yet ("starts is null")."""
    def route(params):
        if params["end"] > last_good_end:
            return FakeResponse(500, {"error": "java.lang.NullPointerException: starts is null"})
        return handler(params)
    return route


class FakeApple:
    def __init__(self, routes=None):
        self.routes = routes or {}
        self.calls = []

    def session_get(self, session, url, params=None, headers=None, cookies=None, timeout=None, allow_redirects=True):
        assert allow_redirects is False and timeout is not None
        assert cookies == {"myacinfo": MYACINFO, "itctx": ITCTX}
        assert url.startswith("https://podcastsconnect.apple.com/podcasts/pcc/v1/analytics/")
        assert params["showId"] == APPLE_SHOW
        endpoint = url.rsplit("/", 1)[-1]
        key = endpoint if endpoint != "showTrendsV2" else f"trends:{params['metric']}"
        self.calls.append((key, dict(params)))
        handler = self.routes.get(key) or DEFAULT_APPLE_ROUTES[key]
        return handler(dict(params))

    @contextlib.contextmanager
    def installed(self):
        with mock.patch.object(requests.Session, "get", lambda session, url, **kw: self.session_get(session, url, **kw)):
            yield self


DEFAULT_APPLE_ROUTES = {
    "trends:LISTENERS": lambda params: FakeResponse(200, APPLE_LISTENERS),
    "trends:FOLLOWERS": lambda params: FakeResponse(200, APPLE_FOLLOWERS),
    "trends:PLAYS": lambda params: FakeResponse(200, APPLE_COUNTRIES),
    "episodes": lambda params: FakeResponse(200, APPLE_EPISODES),
}


def spotify_request(**overrides):
    request = {"platform": "spotify", "session": {"sp_dc": SP_DC, "sp_key": SP_KEY}, "show_id": SPOTIFY_SHOW,
               "start": "2026-10-01", "end": "2026-10-30"}
    request.update(overrides)
    return request


def apple_request(**overrides):
    request = {"platform": "apple", "session": {"myacinfo": MYACINFO, "itctx": ITCTX}, "show_id": APPLE_SHOW,
               "start": "2026-10-01", "end": "2026-10-30"}
    request.update(overrides)
    return request


def invoke(request, argv=None):
    """main() as Rails runs it: the request on stdin, stdout and stderr captured. Returns (code, result, out, err).

    A fresh bearer token is the one secret the helper may write: once, in result["token"]. `out` comes back with that
    one occurrence taken out, so every test can still check stdout for secrets."""
    raw = request if isinstance(request, bytes) else json.dumps(request).encode()
    stdin = io.TextIOWrapper(io.BytesIO(raw), encoding="utf-8")
    out, err = io.StringIO(), io.StringIO()
    with mock.patch.object(sys, "stdin", stdin), mock.patch.object(sys, "stdout", out), \
            mock.patch.object(sys, "stderr", err), mock.patch.object(ps, "utc_today", return_value=TODAY):
        code = ps.main(argv or [])
    lines = out.getvalue().splitlines()
    assert len(lines) == 1, f"stdout must be exactly one line, got {out.getvalue()!r}"
    result = json.loads(lines[0])
    stdout = out.getvalue()
    if "token" in result:
        value = result["token"]["value"]
        assert stdout.count(value) == 1, "the bearer token appears once, in the token field"
        stdout = stdout.replace(value, "", 1)
    return code, result, stdout, err.getvalue()


class SecretsCheck(unittest.TestCase):
    def assertNoSecrets(self, *texts):
        for text in texts:
            for secret in ALL_SECRETS:
                self.assertNotIn(secret, text)


# --------------------------------------------------------------------------------------------------------------------
# Normalization


class SpotifyNormalizationTest(unittest.TestCase):
    window = (dt.date(2026, 9, 30), dt.date(2026, 10, 29))

    def normalize(self, **answers):
        base = {"metadata": SPOTIFY_METADATA, "streams": None, "listeners": None, "aggregate": None, "followers": None}
        base.update(answers)
        windows = {"streams": self.window if base["streams"] is not None else None,
                   "listeners": self.window if base["listeners"] is not None else None,
                   "audience": self.window if base["aggregate"] is not None else None}
        notes = []
        return ps.normalize_spotify(SPOTIFY_SHOW, dt.date(2026, 10, 1), TODAY, self.window, TODAY, base, windows, notes)

    def test_window_sums_all_time_totals_and_breakdowns(self):
        streams = {"detailedStreams": [{"date": "2026-09-30", "starts": 10, "streams": 7},
                                       {"date": "2026-10-12", "starts": 5, "streams": 5},
                                       {"date": "2026-10-29", "starts": 0, "streams": 0},
                                       {"date": "2026-09-01", "starts": 100, "streams": 100}]}  # outside the window
        listeners = {"counts": [{"date": "2026-09-30", "count": 6}, {"date": "2026-10-12", "count": 4}]}
        result = self.normalize(streams=streams, listeners=listeners, aggregate=SPOTIFY_AGGREGATE)

        self.assertEqual(result["show"], {"id": SPOTIFY_SHOW, "name": "The Made Up Show", "release_date": "2024-03-04"})
        self.assertEqual(result["metrics"], {
            "streams": 12, "starts": 15, "listeners": 10,
            "streams_all_time": 7400, "starts_all_time": 9100, "listeners_all_time": 1830, "followers": 212,
            "audience_listeners": 40,
        })
        self.assertEqual(result["breakdowns"]["age"], {
            "0-17": 0.0, "18-22": 0.1, "23-27": 0.25, "28-34": 0.4, "35-44": 0.15, "45-59": 0.05, "60+": 0.0,
            "unknown": 0.05,
        })
        self.assertEqual(result["breakdowns"]["gender"],
                         {"female": 0.4, "male": 0.5, "non_binary": 0.025, "not_specified": 0.075})
        self.assertEqual(result["breakdowns"]["country"], {"US": 0.5, "CA": 0.25, "GB": 0.25})
        self.assertEqual(result["period"]["start"], "2026-09-30")
        self.assertEqual(result["period"]["end"], "2026-10-29")
        self.assertEqual(result["period"]["days"], 30)
        self.assertEqual(result["period"]["requested"], {"start": "2026-10-01", "end": "2026-10-30"})
        self.assertEqual(result["period"]["all_time"], {"start": "2024-03-04", "end": "2026-10-30"})
        self.assertEqual(result["notes"], [])

    def test_a_quiet_month_is_zero_not_missing(self):
        zeros = {"detailedStreams": [{"date": "2026-10-01", "starts": 0, "streams": 0}]}
        result = self.normalize(streams=zeros, listeners={"counts": []})
        self.assertEqual(result["metrics"]["streams"], 0)
        self.assertEqual(result["metrics"]["starts"], 0)
        self.assertEqual(result["metrics"]["listeners"], 0)
        self.assertEqual(result["metrics"]["streams_all_time"], 7400)

    def test_calls_not_made_leave_their_keys_out(self):
        result = self.normalize()
        self.assertEqual(set(result["metrics"]), {"streams_all_time", "starts_all_time", "listeners_all_time",
                                                  "followers"})
        self.assertEqual(result["breakdowns"], {})
        self.assertEqual(result["period"]["windows"], {})

    def test_an_unreadable_shape_is_a_note_not_a_zero(self):
        result = self.normalize(streams={"detailedStreams": [{"day": "2026-10-01", "plays": 4}]})
        self.assertNotIn("streams", result["metrics"])
        self.assertTrue(any("shape" in note for note in result["notes"]))

    def test_an_empty_aggregate_leaves_the_breakdowns_out(self):
        empty = {"count": 0, "ageFacetedCounts": {}, "countryFacetedCounts": {},
                 "genderedCounts": {"counts": {"FEMALE": 0, "MALE": 0, "NON_BINARY": 0, "NOT_SPECIFIED": 0}}}
        result = self.normalize(aggregate=empty)
        self.assertEqual(result["metrics"]["audience_listeners"], 0)
        self.assertEqual(result["breakdowns"], {})
        self.assertTrue(any("breakdowns" in note for note in result["notes"]))

    def test_top_25_countries_then_other(self):
        countries = {f"Country {index}": {"counts": {"FEMALE": 100 - index, "MALE": 0}, "countryCode": code}
                     for index, code in enumerate(sorted(set(ps.ISO_NUMERIC.values()))[:30])}
        result = self.normalize(aggregate={"count": 1, "countryFacetedCounts": countries})
        country = result["breakdowns"]["country"]
        self.assertEqual(len(country), 26)
        self.assertEqual(list(country)[-1], "other")
        self.assertAlmostEqual(sum(country.values()), 1.0, places=3)

    def test_followers_fall_back_to_the_daily_counts_and_skip_a_trailing_zero(self):
        metadata = {key: value for key, value in SPOTIFY_METADATA.items() if key != "followers"}
        followers = {"counts": [{"date": "2026-10-27", "count": 205}, {"date": "2026-10-28", "count": 207},
                                {"date": "2026-10-29", "count": 0}]}
        result = self.normalize(metadata=metadata, followers=followers)
        self.assertEqual(result["metrics"]["followers"], 207)

    def test_feed_url_when_spotify_gives_one(self):
        result = self.normalize(metadata={**SPOTIFY_METADATA, "feedUrl": "https://feeds.example.com/show.xml"})
        self.assertEqual(result["show"]["rss_url"], "https://feeds.example.com/show.xml")
        result = self.normalize(metadata={**SPOTIFY_METADATA, "feedUrl": "javascript:alert(1)"})
        self.assertNotIn("rss_url", result["show"])

    def test_the_built_in_sample(self):
        result = ps.sample_spotify_result()
        for key, value in ps.SAMPLE_SPOTIFY_EXPECTED.items():
            self.assertEqual(result[key], value)


class AppleNormalizationTest(unittest.TestCase):
    start, end = dt.date(2026, 10, 1), dt.date(2026, 10, 30)

    def normalize(self, listeners=APPLE_LISTENERS, followers=APPLE_FOLLOWERS, episodes=APPLE_EPISODES,
                  countries=APPLE_COUNTRIES):
        return ps.normalize_apple(APPLE_SHOW, self.start, self.end, listeners, followers, episodes, countries, [])

    def test_totals_followers_and_countries(self):
        result = self.normalize()
        self.assertEqual(result["show"], {"id": APPLE_SHOW, "name": "The Made Up Show"})
        self.assertEqual(result["metrics"], {"plays": 640, "listeners": 133, "engaged_listeners": 81, "followers": 418})
        self.assertEqual(result["breakdowns"]["country"], {"US": 0.625, "CA": 0.25, "GB": 0.125})
        self.assertEqual(result["breakdowns"]["country_rank"], ["US", "CA", "GB"])  # 999 is no country
        self.assertEqual(result["period"], {"start": "2026-10-01", "end": "2026-10-30", "days": 30,
                                            "requested": {"start": "2026-10-01", "end": "2026-10-30"}})

    def test_totals_for_another_window_fall_back_to_daily_plays(self):
        shifted = {**APPLE_LISTENERS, "showPlayCount": {"latestValue": {
            **APPLE_LISTENERS["showPlayCount"]["latestValue"], "timebucket": 20260915.0}}}
        result = self.normalize(listeners=shifted)
        self.assertEqual(result["metrics"]["plays"], 640)  # 300 + 340; the November row is outside the window
        self.assertNotIn("listeners", result["metrics"])
        self.assertNotIn("engaged_listeners", result["metrics"])
        self.assertTrue(result["notes"])

    def test_an_unknown_country_shape_is_named_in_a_note(self):
        result = self.normalize(countries={"measure": "PLAYS", "countryTrends": {"840": [[20261001.0, 4.0]]}})
        self.assertNotIn("country", result["breakdowns"])
        self.assertEqual(result["breakdowns"]["country_rank"], ["US", "CA", "GB"])
        self.assertTrue(any("countryTrends" in note for note in result["notes"]))

    def test_followers_fall_back_to_the_all_time_summary(self):
        result = self.normalize(followers={"measure": "FOLLOWERS", "allTimeFollowers": {"all": {"current": 77.0}}})
        self.assertEqual(result["metrics"]["followers"], 77)

    def test_missing_answers_are_left_out(self):
        result = self.normalize(followers=None, episodes=None, countries=None)
        self.assertEqual(result["show"], {"id": APPLE_SHOW})
        self.assertNotIn("followers", result["metrics"])
        self.assertNotIn("country", result["breakdowns"])

    def test_the_built_in_sample(self):
        result = ps.sample_apple_result()
        for key, value in ps.SAMPLE_APPLE_EXPECTED.items():
            self.assertEqual(result[key], value)


class SpotifyWindowsTest(unittest.TestCase):
    def test_a_window_ending_today_moves_back_a_day_keeping_its_length(self):
        main, fallback = ps.spotify_windows(dt.date(2026, 10, 1), TODAY, TODAY)
        self.assertEqual(main, (dt.date(2026, 9, 30), dt.date(2026, 10, 29)))
        self.assertEqual(fallback, (dt.date(2026, 9, 29), dt.date(2026, 10, 28)))

    def test_a_window_ending_yesterday_stays_and_can_fall_back(self):
        main, fallback = ps.spotify_windows(dt.date(2026, 9, 30), dt.date(2026, 10, 29), TODAY)
        self.assertEqual(main, (dt.date(2026, 9, 30), dt.date(2026, 10, 29)))
        self.assertEqual(fallback, (dt.date(2026, 9, 29), dt.date(2026, 10, 28)))

    def test_an_older_window_stays_and_has_no_fallback(self):
        main, fallback = ps.spotify_windows(dt.date(2026, 9, 1), dt.date(2026, 9, 30), TODAY)
        self.assertEqual(main, (dt.date(2026, 9, 1), dt.date(2026, 9, 30)))
        self.assertIsNone(fallback)


# --------------------------------------------------------------------------------------------------------------------
# The request


class RequestParsingTest(unittest.TestCase):
    def parse(self, request):
        return ps.parse_request(json.dumps(request).encode(), ps.Secrets())

    def assertInvalid(self, request, words):
        with self.assertRaises(ps.PlatformError) as caught:
            self.parse(request) if isinstance(request, dict) else ps.parse_request(request, ps.Secrets())
        self.assertEqual(caught.exception.code, "failed")
        self.assertIn(words, caught.exception.message)

    def test_sp_key_is_optional(self):
        for session in ({"sp_dc": SP_DC}, {"sp_dc": SP_DC, "sp_key": ""}, {"sp_dc": SP_DC, "sp_key": None}):
            self.assertEqual(self.parse(spotify_request(session=session))["session"], {"sp_dc": SP_DC, "sp_key": ""})
        self.assertEqual(self.parse(spotify_request())["session"], {"sp_dc": SP_DC, "sp_key": SP_KEY})

    def test_defaults_and_overrides(self):
        parsed = self.parse(spotify_request())
        self.assertEqual((parsed["base_url"], parsed["client_id"]), (ps.SPOTIFY_BASE_URL, ps.SPOTIFY_CLIENT_ID))
        session = {"sp_dc": SP_DC, "base_url": "https://generic.wg.spotify.com/podcasters/v1/", "client_id": "a" * 32}
        parsed = self.parse(spotify_request(session=session))
        self.assertEqual(parsed["base_url"], "https://generic.wg.spotify.com/podcasters/v1")

    def test_invalid_requests(self):
        self.assertInvalid(b"not json " + SP_DC.encode(), "one JSON object")
        self.assertInvalid(b"[1, 2]", "one JSON object")
        self.assertInvalid(b"{" + b" " * ps.MAX_STDIN_BYTES + b"}", "64 KB")
        self.assertInvalid(spotify_request(platform="youtube"), "platform")
        self.assertInvalid(spotify_request(session="cookie"), "session must be an object")
        self.assertInvalid(spotify_request(session={"sp_key": SP_KEY}), "needs sp_dc")
        self.assertInvalid(apple_request(session={"myacinfo": MYACINFO}), "needs itctx")
        self.assertInvalid(spotify_request(session={"sp_dc": "short"}), "doesn't look right")
        self.assertInvalid(spotify_request(session={"sp_dc": SP_DC + "\n"}), "doesn't look right")
        self.assertInvalid(spotify_request(show_id="../../user/me"), "22 letters and digits")
        self.assertInvalid(apple_request(show_id="12a"), "digits")
        self.assertInvalid(spotify_request(start="2026-10-1"), "YYYY-MM-DD")
        self.assertInvalid(spotify_request(start="2026-02-30"), "not a real date")
        self.assertInvalid(spotify_request(start="2026-11-01"), "end is before start")
        self.assertInvalid(spotify_request(start="2025-01-01"), "longer than")
        self.assertInvalid(spotify_request(session={"sp_dc": SP_DC, "base_url": "https://evil.example.com"}), "base_url")
        self.assertInvalid(spotify_request(session={"sp_dc": SP_DC, "base_url": "http://x.spotify.com"}), "base_url")
        self.assertInvalid(spotify_request(session={"sp_dc": SP_DC, "client_id": "nope"}), "client_id")


# --------------------------------------------------------------------------------------------------------------------
# End to end with the network faked


class SpotifyFetchTest(SecretsCheck):
    def test_success_reads_the_window_ending_yesterday(self):
        with FakeSpotify().installed() as fake:
            code, result, out, err = invoke(spotify_request())
        self.assertEqual(code, 0)
        self.assertTrue(result["ok"])
        self.assertEqual(result["connector"], "spotifyconnector==0.8.3")
        self.assertEqual(result["show"]["name"], "The Made Up Show")
        self.assertEqual(result["metrics"]["streams"], 60)  # 30 days of 2
        self.assertEqual(result["metrics"]["starts"], 90)
        self.assertEqual(result["metrics"]["listeners"], 30)
        self.assertEqual(result["metrics"]["streams_all_time"], 7400)
        self.assertEqual(result["metrics"]["followers"], 212)
        self.assertEqual(result["metrics"]["audience_listeners"], 40)
        self.assertEqual(result["period"]["windows"]["streams"], {"start": "2026-09-30", "end": "2026-10-29", "days": 30})
        self.assertEqual(result["unavailable"], [])
        windows = {(endpoint, params.get("start"), params.get("end")) for endpoint, params in fake.calls}
        self.assertEqual(windows, {("metadata", None, None), ("detailedStreams", "2026-09-30", "2026-10-29"),
                                   ("listeners", "2026-09-30", "2026-10-29"), ("aggregate", "2026-09-30", "2026-10-29")})
        self.assertEqual(fake.auth_calls, 1)
        self.assertNoSecrets(out, err)

    def test_works_without_sp_key(self):
        with FakeSpotify().installed():
            code, result, out, err = invoke(spotify_request(session={"sp_dc": SP_DC, "sp_key": ""}))
        self.assertEqual((code, result["ok"]), (0, True))

    def test_a_500_is_tried_once_more_ending_the_day_before_yesterday(self):
        routes = {"detailedStreams": npe_until("2026-10-28", spotify_streams),
                  "listeners": npe_until("2026-10-28", spotify_listeners)}
        with FakeSpotify(routes).installed() as fake:
            code, result, out, err = invoke(spotify_request())
        self.assertTrue(result["ok"])
        self.assertEqual(result["period"]["windows"]["streams"], {"start": "2026-09-29", "end": "2026-10-28", "days": 30})
        self.assertEqual(result["period"]["windows"]["listeners"]["end"], "2026-10-28")
        self.assertEqual(result["period"]["windows"]["audience"]["end"], "2026-10-29")
        self.assertEqual(result["metrics"]["streams"], 60)
        self.assertEqual([endpoint for endpoint, _ in fake.calls].count("detailedStreams"), 2)

    def test_a_window_call_that_keeps_failing_is_unavailable_not_fatal(self):
        always_500 = lambda params: FakeResponse(500, {"error": "starts is null"})  # noqa: E731
        routes = {"detailedStreams": always_500, "listeners": always_500,
                  "aggregate": lambda params: FakeResponse(403, {"error": "forbidden"})}
        with FakeSpotify(routes).installed() as fake:
            code, result, out, err = invoke(spotify_request())
        self.assertEqual((code, result["ok"]), (0, True))
        self.assertEqual(result["unavailable"], ["streams", "starts", "listeners", "audience_listeners", "age",
                                                 "gender", "country"])
        self.assertEqual(set(result["metrics"]), {"streams_all_time", "starts_all_time", "listeners_all_time",
                                                  "followers"})
        self.assertEqual(len(result["notes"]), 3)
        self.assertEqual([endpoint for endpoint, _ in fake.calls].count("detailedStreams"), 2)  # one retry, no more
        self.assertNoSecrets(out, err)

    def test_expired_session(self):
        with FakeSpotify(auth="login_required").installed() as fake:
            code, result, out, err = invoke(spotify_request())
        self.assertEqual((code, result), (0, {"ok": False, "error": "expired", "message": mock.ANY}))
        self.assertEqual(fake.auth_calls, 1)
        self.assertNoSecrets(out, err)

    def test_sign_in_4xx_is_expired_without_retrying(self):
        with FakeSpotify(auth=400).installed() as fake:
            code, result, out, err = invoke(spotify_request())
        self.assertEqual(result["error"], "expired")
        self.assertEqual(fake.auth_calls, 1)
        self.assertNoSecrets(out, err)

    def test_sign_in_5xx_is_retried_then_failed(self):
        with FakeSpotify(auth=503).installed() as fake, mock.patch.object(time, "sleep"):
            code, result, out, err = invoke(spotify_request())
        self.assertEqual(result["error"], "failed")
        self.assertIn("503", result["message"])
        self.assertEqual(fake.auth_calls, 3)
        self.assertNoSecrets(out, err)

    def test_status_codes_on_the_required_call(self):
        for status, error in ((403, "forbidden"), (404, "not_found"), (500, "failed"), (400, "failed")):
            routes = {"metadata": lambda params, status=status: FakeResponse(status, {"error": SP_DC})}
            with self.subTest(status=status), FakeSpotify(routes).installed():
                code, result, out, err = invoke(spotify_request())
                self.assertEqual((code, result["ok"], result["error"]), (0, False, error))
                self.assertIn(str(status), result["message"])
                self.assertNoSecrets(out, err)

    def test_401_signs_in_again_once_then_is_expired(self):
        routes = {"metadata": lambda params: FakeResponse(401, {"error": "unauthorized"})}
        with FakeSpotify(routes).installed() as fake:
            code, result, out, err = invoke(spotify_request())
        self.assertEqual(result["error"], "expired")
        self.assertEqual(fake.auth_calls, 2)
        self.assertEqual([endpoint for endpoint, _ in fake.calls], ["metadata", "metadata"])

    def test_a_503_on_the_required_call_is_retried(self):
        answers = iter([FakeResponse(503), FakeResponse(200, SPOTIFY_METADATA)])
        with FakeSpotify({"metadata": lambda params: next(answers)}).installed(), mock.patch.object(time, "sleep"):
            code, result, out, err = invoke(spotify_request())
        self.assertTrue(result["ok"])

    def test_network_errors_never_print_the_exception(self):
        def broken(params):
            raise requests.exceptions.ConnectionError(f"connection reset; cookie sp_dc={SP_DC}")
        with FakeSpotify({"metadata": broken}).installed():
            code, result, out, err = invoke(spotify_request())
        self.assertEqual((result["error"], result["message"]), ("failed", "Spotify could not connect on metadata."))
        self.assertNoSecrets(out, err)

    def test_library_logs_are_scrubbed(self):
        def noisy(params):
            logger.error(f"Error in API: Cookie: sp_dc={SP_DC}; sp_key={SP_KEY}; Bearer {BEARER}")
            logger.info(f"headers {SP_DC}")
            return FakeResponse(403, {})
        with FakeSpotify({"metadata": noisy}).installed():
            code, result, out, err = invoke(spotify_request())
        self.assertIn("[redacted]", err)
        self.assertNotIn("headers", err)  # below ERROR
        self.assertNoSecrets(out, err)

    def test_a_crash_prints_only_the_class_name(self):
        with FakeSpotify().installed(), \
                mock.patch.object(ps, "normalize_spotify", side_effect=KeyError(f"cookie {SP_DC}")):
            code, result, out, err = invoke(spotify_request())
        self.assertEqual(code, 1)
        token = result.pop("token")  # it signed in before the crash: the token still saves the next run a sign in
        self.assertEqual(token["value"], BEARER)
        self.assertEqual(result, {"ok": False, "error": "failed", "message": "Unexpected error in the stats helper "
                                                                             "(KeyError)."})
        self.assertNoSecrets(out, err)

    def test_it_stops_at_the_time_limit(self):
        def slow(params):
            time.sleep(5)
            return FakeResponse(200, SPOTIFY_METADATA)
        with FakeSpotify({"metadata": slow}).installed(), mock.patch.object(ps, "TOTAL_TIMEOUT", 1.0):
            started = time.monotonic()
            code, result, out, err = invoke(spotify_request())
        self.assertLess(time.monotonic() - started, 3)
        self.assertEqual((code, result["error"]), (0, "failed"))
        self.assertIn("Timed out", result["message"])

    def test_optional_calls_are_skipped_when_time_is_short(self):
        def metadata_then_late(params):
            return FakeResponse(200, SPOTIFY_METADATA)
        with FakeSpotify({"metadata": metadata_then_late}).installed(), \
                mock.patch.object(ps, "OPTIONAL_CALL_MIN_SECONDS", ps.TOTAL_TIMEOUT + 1):
            code, result, out, err = invoke(spotify_request())
        self.assertTrue(result["ok"])
        self.assertIn("streams", result["unavailable"])
        self.assertTrue(all(note.startswith("Skipped") for note in result["notes"]))


class AppleFetchTest(SecretsCheck):
    def test_success(self):
        with FakeApple().installed() as fake:
            code, result, out, err = invoke(apple_request())
        self.assertEqual(code, 0)
        self.assertTrue(result["ok"])
        self.assertEqual(result["connector"], "appleconnector==0.4.1")
        self.assertEqual(result["metrics"], {"plays": 640, "listeners": 133, "engaged_listeners": 81, "followers": 418})
        self.assertEqual(result["breakdowns"]["country"], {"US": 0.625, "CA": 0.25, "GB": 0.125})
        self.assertEqual(result["show"]["name"], "The Made Up Show")
        listeners_call = dict(fake.calls)["trends:LISTENERS"]
        self.assertEqual((listeners_call["start"], listeners_call["end"], listeners_call["dimension"]),
                         ("2026-10-01", "2026-10-30", "BY_EPISODES"))
        self.assertEqual(dict(fake.calls)["trends:PLAYS"]["dimension"], "BY_COUNTRY")
        self.assertNoSecrets(out, err)

    def test_status_codes_and_redirects(self):
        cases = (
            (FakeResponse(401, text="unauthorized"), "expired"),
            (FakeResponse(403, {"errors": [MYACINFO]}), "forbidden"),
            (FakeResponse(404, {}), "not_found"),
            (FakeResponse(500, {}), "failed"),
            (FakeResponse(302, headers={"Location": "https://idmsa.apple.com/appleauth/auth/signin"}), "expired"),
            (FakeResponse(302, headers={"Location": "https://podcastsconnect.apple.com/elsewhere"}), "failed"),
            (FakeResponse(200, text=f"<html>sign in {ITCTX}</html>"), "failed"),
        )
        for response, error in cases:
            with self.subTest(status=response.status_code, error=error), \
                    FakeApple({"trends:LISTENERS": lambda params, response=response: response}).installed():
                code, result, out, err = invoke(apple_request())
                self.assertEqual((code, result["ok"], result["error"]), (0, False, error))
                self.assertNoSecrets(out, err)

    def test_optional_calls_that_fail_are_unavailable(self):
        routes = {"trends:FOLLOWERS": lambda params: FakeResponse(500, {}),
                  "episodes": lambda params: FakeResponse(403, {}),
                  "trends:PLAYS": lambda params: FakeResponse(400, {})}
        with FakeApple(routes).installed() as fake:
            code, result, out, err = invoke(apple_request())
        self.assertTrue(result["ok"])
        self.assertEqual(result["unavailable"], ["followers", "country"])
        self.assertEqual(result["show"], {"id": APPLE_SHOW})
        self.assertEqual(len(result["notes"]), 3)
        self.assertEqual(len(fake.calls), 4)  # no retries on optional calls

    def test_no_numbers_at_all_is_a_failure(self):
        with FakeApple({"trends:LISTENERS": lambda params: FakeResponse(200, {"measure": "LISTENERS"}),
                        "trends:FOLLOWERS": lambda params: FakeResponse(200, {})}).installed():
            code, result, out, err = invoke(apple_request())
        self.assertEqual((result["ok"], result["error"]), (False, "failed"))
        self.assertIn("no numbers", result["message"])


def soon(seconds: float) -> str:
    """An expires_at that many seconds from now, as Rails sends it."""
    return ps.iso_utc(ps.utc_now() + dt.timedelta(seconds=seconds))


def http_date(seconds_from_now: float) -> str:
    return email.utils.format_datetime(ps.utc_now() + dt.timedelta(seconds=seconds_from_now), usegmt=True)


def too_many(retry_after=None):
    """Spotify's or Apple's 429, with or without a Retry-After header."""
    return FakeResponse(429, {"error": "rate limited"}, headers={"Retry-After": retry_after} if retry_after else {})


# --------------------------------------------------------------------------------------------------------------------
# Rate limits: a light client never pushes past a 429


class RateLimitTest(SecretsCheck):
    def test_a_429_the_retries_cannot_clear_is_rate_limited_with_the_wait_asked_for(self):
        with FakeSpotify({"metadata": lambda params: too_many("5")}).installed() as fake, \
                mock.patch.object(time, "sleep") as slept:
            code, result, out, err = invoke(spotify_request())
        self.assertEqual((code, result["ok"], result["error"], result["retry_after"]), (0, False, "rate_limited", 5))
        self.assertIn("429", result["message"])
        self.assertEqual([endpoint for endpoint, _ in fake.calls], ["metadata"] * 3)  # the call and its 2 retries
        self.assertEqual([call.args[0] for call in slept.call_args_list], [5.0, 5.0])  # the wait asked for
        self.assertNoSecrets(out, err)

    def test_a_long_wait_is_not_waited_out_inside_the_run(self):
        with FakeSpotify({"metadata": lambda params: too_many("120")}).installed() as fake, \
                mock.patch.object(time, "sleep") as slept:
            code, result, out, err = invoke(spotify_request())
        self.assertEqual((result["error"], result["retry_after"]), ("rate_limited", 120))
        self.assertEqual(len(fake.calls), 1)
        slept.assert_not_called()

    def test_retry_after_as_a_date(self):
        with FakeSpotify({"metadata": lambda params: too_many(http_date(90))}).installed():
            code, result, out, err = invoke(spotify_request())
        self.assertEqual(result["error"], "rate_limited")
        self.assertAlmostEqual(result["retry_after"], 90, delta=3)

    def test_no_retry_after_is_null(self):
        with FakeSpotify({"metadata": lambda params: too_many()}).installed(), mock.patch.object(time, "sleep"):
            code, result, out, err = invoke(spotify_request())
        self.assertEqual(result["error"], "rate_limited")
        self.assertIsNone(result["retry_after"])
        self.assertIn("retry_after", result)

    def test_retries_stay_inside_the_time_budget(self):
        # 20 s left can't hold a 8 s wait plus a 15 s read: no retry, the run ends at once.
        with FakeSpotify({"metadata": lambda params: too_many("8")}).installed() as fake, \
                mock.patch.object(ps, "TOTAL_TIMEOUT", 20.0), mock.patch.object(time, "sleep") as slept:
            started = time.monotonic()
            code, result, out, err = invoke(spotify_request())
        self.assertEqual((result["error"], result["retry_after"]), ("rate_limited", 8))
        self.assertEqual(len(fake.calls), 1)
        slept.assert_not_called()
        self.assertLess(time.monotonic() - started, 5)

    def test_a_429_on_an_optional_call_ends_the_run_with_no_more_calls(self):
        with FakeSpotify({"detailedStreams": lambda params: too_many("600")}).installed() as fake:
            code, result, out, err = invoke(spotify_request())
        self.assertEqual((result["ok"], result["error"], result["retry_after"]), (False, "rate_limited", 600))
        self.assertEqual([endpoint for endpoint, _ in fake.calls], ["metadata", "detailedStreams"])
        self.assertNoSecrets(out, err)

    def test_a_429_on_sign_in_is_rate_limited_not_expired_and_not_retried(self):
        with FakeSpotify(auth=too_many("300")).installed() as fake, mock.patch.object(time, "sleep"):
            code, result, out, err = invoke(spotify_request())
        self.assertEqual((result["error"], result["retry_after"]), ("rate_limited", 300))
        self.assertEqual(fake.auth_calls, 1)
        self.assertEqual(fake.calls, [])
        self.assertNotIn("token", result)
        self.assertNoSecrets(out, err)

    def test_apple(self):
        with FakeApple({"trends:LISTENERS": lambda params: too_many("60")}).installed() as fake:
            code, result, out, err = invoke(apple_request())
        self.assertEqual((code, result["error"], result["retry_after"]), (0, "rate_limited", 60))
        self.assertEqual(len(fake.calls), 1)
        self.assertNoSecrets(out, err)

    def test_reading_retry_after(self):
        self.assertEqual(ps.retry_after_seconds("30"), 30)
        self.assertEqual(ps.retry_after_seconds(" 0 "), 0)
        self.assertEqual(ps.retry_after_seconds("99999999999"), ps.MAX_RETRY_AFTER)
        self.assertEqual(ps.retry_after_seconds(http_date(-60)), 0)  # a date already past
        for unreadable in (None, "", "soon", "-5", "1.5"):
            self.assertIsNone(ps.retry_after_seconds(unreadable), unreadable)


# --------------------------------------------------------------------------------------------------------------------
# The cached bearer token: one Spotify sign in an hour, not one a fetch


class BearerTokenTest(SecretsCheck):
    def test_a_cached_token_skips_the_sign_in(self):
        request = spotify_request(token={"value": CACHED, "expires_at": soon(1800)})
        with FakeSpotify(bearers=(CACHED,)).installed() as fake:
            code, result, out, err = invoke(request)
        self.assertTrue(result["ok"])
        self.assertEqual(fake.auth_calls, 0)
        self.assertEqual(set(fake.bearers_used), {CACHED})
        self.assertNotIn("token", result)  # nothing new to cache
        self.assertNoSecrets(out, err)

    def test_signing_in_returns_the_fresh_token_once(self):
        with FakeSpotify().installed() as fake:
            code, result, out, err = invoke(spotify_request())
        self.assertTrue(result["ok"])
        self.assertEqual(fake.auth_calls, 1)
        self.assertEqual(set(result["token"]), {"value", "expires_at"})
        self.assertEqual(result["token"]["value"], BEARER)
        expires = dt.datetime.strptime(result["token"]["expires_at"], "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=dt.timezone.utc)
        self.assertAlmostEqual((expires - ps.utc_now()).total_seconds(), 3600, delta=60)  # Spotify's expires_in
        self.assertNotIn(BEARER, json.dumps({key: value for key, value in result.items() if key != "token"}))
        self.assertNoSecrets(out, err)  # out has the token field's one occurrence taken out (invoke)

    def test_a_token_about_to_expire_is_not_used(self):
        request = spotify_request(token={"value": CACHED, "expires_at": soon(60)})
        with FakeSpotify(bearers=(CACHED, BEARER)).installed() as fake:
            code, result, out, err = invoke(request)
        self.assertEqual(fake.auth_calls, 1)
        self.assertNotIn(CACHED, fake.bearers_used)
        self.assertEqual(result["token"]["value"], BEARER)
        self.assertNoSecrets(out, err)

    def test_a_refused_token_means_one_fresh_sign_in(self):
        request = spotify_request(token={"value": CACHED, "expires_at": soon(1800)})
        with FakeSpotify().installed() as fake:  # Spotify no longer takes CACHED
            code, result, out, err = invoke(request)
        self.assertTrue(result["ok"])
        self.assertEqual(fake.auth_calls, 1)
        self.assertEqual(fake.bearers_used[0], CACHED)
        self.assertEqual(set(fake.bearers_used[1:]), {BEARER})
        self.assertEqual(result["token"]["value"], BEARER)
        self.assertNoSecrets(out, err)

    def test_a_token_that_does_not_look_right_is_ignored(self):
        for token in ({"value": CACHED, "expires_at": "tomorrow"}, {"value": CACHED + " x", "expires_at": soon(1800)},
                      {"value": 42, "expires_at": soon(1800)}, {"value": CACHED}, CACHED):
            with self.subTest(token=token), FakeSpotify().installed() as fake:
                code, result, out, err = invoke(spotify_request(token=token))
                self.assertEqual((result["ok"], fake.auth_calls), (True, 1))
                self.assertNoSecrets(out, err)

    def test_a_fresh_token_comes_back_with_a_failure_too(self):
        with FakeSpotify({"metadata": lambda params: FakeResponse(403, {})}).installed():
            code, result, out, err = invoke(spotify_request())
        self.assertEqual((result["error"], result["token"]["value"]), ("forbidden", BEARER))
        self.assertNoSecrets(out, err)

    def test_never_after_an_expired_session(self):
        routes = {"metadata": lambda params: FakeResponse(401, {})}
        with FakeSpotify(routes).installed():
            code, result, out, err = invoke(spotify_request())
        self.assertEqual(result["error"], "expired")
        self.assertNotIn("token", result)
        self.assertNoSecrets(out, err)

    def test_apple_ignores_a_token(self):
        with FakeApple().installed():
            code, result, out, err = invoke(apple_request(token={"value": CACHED, "expires_at": soon(1800)}))
        self.assertTrue(result["ok"])
        self.assertNotIn("token", result)
        self.assertNoSecrets(out, err)


class EntryPointTest(SecretsCheck):
    def test_invalid_input_is_never_echoed(self):
        code, result, out, err = invoke(b'{"platform": "spotify", "session": {"sp_dc": "' + SP_DC.encode() + b'"')
        self.assertEqual((code, result["error"]), (0, "failed"))
        self.assertNoSecrets(out, err)
        code, result, out, err = invoke(spotify_request(show_id="bad"))
        self.assertNoSecrets(out, err)

    def test_unknown_arguments(self):
        out = io.StringIO()
        with mock.patch.object(sys, "stdout", out):
            self.assertEqual(ps.main(["--verbose"]), 2)
        self.assertFalse(json.loads(out.getvalue())["ok"])

    def test_self_test_in_process(self):
        result, code = ps.self_test()
        self.assertEqual((result, code), ({"ok": True, "self_test": True}, 0))

    def run_command(self, command, stdin=b"", env=None):
        return subprocess.run(command, input=stdin, capture_output=True, timeout=60, env=env, cwd=ROOT)

    def test_script_self_test(self):
        done = self.run_command([sys.executable, "-I", str(SCRIPT), "--self-test"])
        self.assertEqual(done.returncode, 0, done.stderr.decode())
        self.assertEqual(json.loads(done.stdout), {"ok": True, "self_test": True})

    def test_bin_wrapper(self):
        env = {**os.environ, "PLATFORM_STATS_PYTHON": sys.executable}
        done = self.run_command([str(ROOT / "bin" / "platform-stats"), "--self-test"], env=env)
        self.assertEqual(done.returncode, 0, done.stderr.decode())
        self.assertEqual(json.loads(done.stdout), {"ok": True, "self_test": True})

        request = json.dumps(spotify_request(show_id="not-a-show")).encode()
        done = self.run_command([str(ROOT / "bin" / "platform-stats")], stdin=request, env=env)
        self.assertEqual(done.returncode, 0)
        self.assertEqual(json.loads(done.stdout)["error"], "failed")
        self.assertNoSecrets(done.stdout.decode(), done.stderr.decode())


if __name__ == "__main__":
    unittest.main()
