"""Midrolo's platform stats helper: verified Spotify and Apple Podcasts numbers for "Invite Midrolo".

Run it through bin/platform-stats (which picks /opt/stats-venv/bin/python in the Docker image). Rails calls it from
Stats::PlatformFetch with Open3, the request on stdin and a 60 second timeout. Midrolo signs in only as its own
service accounts, which podcasters add to their show's team (Spotify for Creators: Analytics access; Apple Podcasts
Connect: the Analyst role). The sessions come from the database through the Rails caller; the helper reads no
environment variables and no files.

Fetching uses openpodcast's MIT licensed connectors, pinned in requirements-stats.txt: spotifyconnector 0.8.3 and
appleconnector 0.4.1 (https://github.com/openpodcast). Their sign in code, endpoint paths and parameters are used as
is. Their HTTP loop (`_request`) is replaced in a subclass: as published it has no request timeout, retries any
error (a 403, 404 or 500 included) six times with waits of up to a minute, and on errors logs the request headers
(Apple's carry the session cookies). The replacement makes one GET with a 5 s connect and 15 s read timeout and maps
the answer to an error code. Required calls retry a 429 or 502 to 504 at most twice inside the time budget, and only
when the platform asks for a wait of 10 s or less (or names none); optional calls get one attempt. Spotify's sign in
keeps the connector's code, with its requests held to the same timeouts and a shorter retry policy (3 tries within
20 s, waits of 1 and 2 s, no retry on a 4xx answer, a 429 included).

Being a light client (Midrolo's own service accounts must never look abusive): the helper identifies itself as the
requests library always does and never imitates a browser. A 429 the helper can't wait out inside the run ends the
whole run as "rate_limited" with the platform's Retry-After, so Rails pauses every fetch for that platform
(Stats::Throttle) instead of asking again. Spotify's bearer token (valid an hour) can be passed back in, so a run
signs in only when the last token is about to expire.

Request, one JSON object on stdin (at most 64 KB):

    {"platform": "spotify" | "apple",
     "session": {...},              spotify: sp_dc; sp_key optional (may be "" or left out); optionally base_url,
                                    client_id. apple: myacinfo, itctx
     "show_id": "...",              Spotify show id (22 letters and digits) or Apple podcast id (digits)
     "start": "YYYY-MM-DD", "end": "YYYY-MM-DD",    inclusive window, at most 366 days
     "token": {"value": "...", "expires_at": "YYYY-MM-DDTHH:MM:SSZ"}}
                                    optional, Spotify only: the bearer token an earlier run returned. Used while it
                                    has more than TOKEN_MIN_LIFE left; one that doesn't look right is ignored (the
                                    helper signs in). A token the platform refuses (401) means one fresh sign in.

Spotify windows: Spotify hasn't computed today's numbers, and its detailedStreams and listeners calls answer 500 for a
window that ends today. So the window keeps its length but ends at most yesterday (UTC): a request for Oct 1 to Oct
30, run on Oct 30, reads Sep 30 to Oct 29. A window call that still answers 5xx is tried once more ending the day
before yesterday. period.windows says which dates each call covered. Apple windows are read as requested.

Success, one JSON object on stdout, exit code 0:

    {"ok": true, "platform": "spotify" | "apple", "connector": "spotifyconnector==0.8.3",
     "show": {"id", "name", "rss_url", "release_date"},   each but id only when the platform gives it
     "period": {"start", "end", "days",                    the window the window metrics cover
                "requested": {"start", "end"},
                "windows": {"streams" | "listeners" | "audience": {"start", "end", "days"}},   spotify only
                "all_time": {"start", "end"}},             spotify only: show.release_date (or null) to today (UTC)
     "metrics": {...}, "breakdowns": {...},
     "unavailable": ["metric or breakdown keys the platform didn't give this time"],
     "notes": ["plain words on anything left out"],
     "token": {"value": "...", "expires_at": "YYYY-MM-DDTHH:MM:SSZ"}}
                                                           spotify only, and only when this run signed in: the
                                                           fresh bearer token for Rails to cache (encrypted) and pass
                                                           back next time. Also on a failure, except "expired"

Metric keys (whole numbers; a key is left out when the platform doesn't give it, never guessed):

    spotify  streams             window: sum of the daily "streams" from shows/{id}/detailedStreams
             starts              window: sum of the daily "starts" from the same call
             listeners           window: sum of the daily "count" from shows/{id}/listeners. A daily count is that
                                 day's listeners, so someone who listens on 3 days counts 3 times: this is listener
                                 days, more than the window's unique listeners
             audience_listeners  window: "count" from shows/{id}/aggregate, the listeners behind the age, gender and
                                 country shares (Spotify merges the window into one aggregate)
             streams_all_time    "streams" from shows/{id}/metadata
             starts_all_time     "starts" from shows/{id}/metadata
             listeners_all_time  "listeners" from shows/{id}/metadata
             followers           "followers" from shows/{id}/metadata (the current total); if missing, the latest
                                 daily total from shows/{id}/followers, skipping a trailing 0 (a day not processed)
    apple    plays               showPlayCount.latestValue.playscount from showTrendsV2 (metric LISTENERS, dimension
                                 BY_EPISODES): Apple's total for the window; else the sum of the daily
                                 showPlayCountTrends playscount
             listeners           showPlayCount.latestValue.uniquelistenerscount (unique listeners in the window)
             engaged_listeners   showPlayCount.latestValue.uniqueengagedlistenerscount
             followers           latest row of followerAllTimeTrends from showTrendsV2 (metric FOLLOWERS):
                                 followers minus unfollowers; else allTimeFollowers.all.current

Breakdown keys (shares from 0 to 1, rounded to 4 places, summing to about 1):

    spotify  age       buckets 0-17, 18-22, 23-27, 28-34, 35-44, 45-59, 60+ (Spotify's 60-150) and unknown
             gender    female, male, non_binary, not_specified
             country   ISO 3166 alpha-2 codes, largest 25, the rest summed as "other"
    apple    country       ISO alpha-2 shares, only when Apple's showTrendsV2 answer for metric PLAYS, dimension
                           BY_COUNTRY carries showTopCountries as {numeric code: {"latestValue": n}} (the shape
                           Apple uses in episodeDetails); otherwise left out with a note naming the answer's keys
             country_rank  a list, not shares: Apple's top countries in order (up to 10), as ISO alpha-2 codes,
                           from the showTopCountries list in the LISTENERS answer (else from the BY_COUNTRY answer)

Failure, exit code 0 when handled:

    {"ok": false, "error": "expired" | "forbidden" | "not_found" | "rate_limited" | "failed",
     "message": "plain words, no secrets",
     "retry_after": 120}            rate_limited only: the seconds the platform asked for (Retry-After, seconds or
                                    an HTTP date), or null when it didn't say

    expired       the service session no longer works: Spotify asked to sign in again (CredentialsExpired), its sign
                  in answered 4xx (not 429), or a platform answered 401 (after one fresh Spotify sign in) or
                  redirected to sign in
    forbidden     403 on a required call: the service account has no access to this show
    not_found     404 on a required call: no such show for this account
    rate_limited  429 on any call or on Spotify's sign in, after the retries above: the platform wants fewer requests
    failed        anything else: timeouts, 5xx on a required call, an answer that isn't JSON, no numbers, a bad request

Only the first call is required (Spotify metadata, Apple's LISTENERS trends). Any other call that fails (other than
an expired session or a rate limit) or runs out of time leaves its keys out, lists them in "unavailable" and says
why in "notes".

Exit codes: 0 handled (ok true or false), 1 crash (a sanitized JSON failure is still printed), 2 bad arguments,
3 the Python libraries are missing (development).

Secrets: session values are never printed or logged. Stdin is never echoed. Loguru is set to ERROR on stderr through
a sink that writes only the message, scrubbed of every session value and the Spotify bearer token. Exceptions are
reported by class name only, so a traceback or an exception message can't carry a cookie. Everything written to
stdout and stderr goes through the same scrubber; the one exception is the result's "token" field, added after.

Time: everything, sign in included, must finish within TOTAL_TIMEOUT (50 s; the Rails caller allows 60 s). A
SIGALRM timer enforces it, each request has its own timeout, and optional calls are skipped when time runs short.

`--self-test` imports both libraries, checks the pinned versions and the connector methods this file relies on, and
runs the normalization on the built in sample payloads below, offline. It prints {"ok": true, "self_test": true}.
"""

from __future__ import annotations

import datetime as dt
import email.utils
import json
import math
import re
import signal
import sys
import threading
import time
from contextlib import contextmanager
from urllib.parse import urlparse

TOTAL_TIMEOUT = 50.0  # seconds, the whole run
CONNECT_TIMEOUT = 5.0  # seconds, per request
READ_TIMEOUT = 15.0  # seconds, per request
SIGN_IN_BUDGET = 20.0  # seconds, all of Spotify's sign in tries together
TRANSIENT_STATUSES = (429, 502, 503, 504)
TRANSIENT_RETRIES = 2  # required calls only
IN_RUN_WAIT_LIMIT = 10.0  # seconds: a retry inside the run only when the platform asks for this little wait or less
MAX_RETRY_AFTER = 7 * 24 * 3600  # seconds: a longer Retry-After is reported as this
TOKEN_MIN_LIFE = 120.0  # seconds a cached bearer token must have left to be used (Rails passes it with 5 minutes)
OPTIONAL_CALL_MIN_SECONDS = 6.0  # optional calls are skipped with less time than this left
MAX_STDIN_BYTES = 64 * 1024
MAX_WINDOW_DAYS = 366
TOP_COUNTRIES = 25

PINNED = {"spotifyconnector": "0.8.3", "appleconnector": "0.4.1"}

# Not secrets: the public web client's values, from spotifyconnector's .env.example. The session may override them.
SPOTIFY_BASE_URL = "https://generic.wg.spotify.com/podcasters/v0"
SPOTIFY_CLIENT_ID = "05a1371ee5194c27860b3ff3ff3979d2"

REQUIRED_SESSION_KEYS = {"spotify": ("sp_dc",), "apple": ("myacinfo", "itctx")}
OPTIONAL_SESSION_KEYS = {"spotify": ("sp_key",), "apple": ()}
SHOW_ID_FORMATS = {"spotify": re.compile(r"\A[A-Za-z0-9]{22}\Z"), "apple": re.compile(r"\A[0-9]{1,15}\Z")}
PLATFORM_NAMES = {"spotify": "Spotify", "apple": "Apple Podcasts"}
SIGN_IN_HOSTS = ("accounts.spotify.com", "idmsa.apple.com", "appleid.apple.com")

SPOTIFY_AGE_BUCKETS = {
    "0-17": "0-17",
    "18-22": "18-22",
    "23-27": "23-27",
    "28-34": "28-34",
    "35-44": "35-44",
    "45-59": "45-59",
    "60-150": "60+",
    "unknown": "unknown",
}
SPOTIFY_GENDERS = {"FEMALE": "female", "MALE": "male", "NON_BINARY": "non_binary", "NOT_SPECIFIED": "not_specified"}
SAFE_KEY = re.compile(r"\A[A-Za-z0-9_+\-]{1,40}\Z")

# ISO 3166-1 numeric code to alpha-2. Apple reports countries by numeric code (276 is Germany), Spotify by alpha-2.
ISO_NUMERIC = dict(
    (int(pair.split(":")[0]), pair.split(":")[1])
    for pair in """
    4:AF 8:AL 10:AQ 12:DZ 16:AS 20:AD 24:AO 28:AG 31:AZ 32:AR 36:AU 40:AT 44:BS 48:BH 50:BD 51:AM 52:BB 56:BE 60:BM
    64:BT 68:BO 70:BA 72:BW 74:BV 76:BR 84:BZ 86:IO 90:SB 92:VG 96:BN 100:BG 104:MM 108:BI 112:BY 116:KH 120:CM
    124:CA 132:CV 136:KY 140:CF 144:LK 148:TD 152:CL 156:CN 158:TW 162:CX 166:CC 170:CO 174:KM 175:YT 178:CG 180:CD
    184:CK 188:CR 191:HR 192:CU 196:CY 203:CZ 204:BJ 208:DK 212:DM 214:DO 218:EC 222:SV 226:GQ 231:ET 232:ER 233:EE
    234:FO 238:FK 239:GS 242:FJ 246:FI 248:AX 250:FR 254:GF 258:PF 260:TF 262:DJ 266:GA 268:GE 270:GM 275:PS 276:DE
    288:GH 292:GI 296:KI 300:GR 304:GL 308:GD 312:GP 316:GU 320:GT 324:GN 328:GY 332:HT 334:HM 336:VA 340:HN 344:HK
    348:HU 352:IS 356:IN 360:ID 364:IR 368:IQ 372:IE 376:IL 380:IT 384:CI 388:JM 392:JP 398:KZ 400:JO 404:KE 408:KP
    410:KR 414:KW 417:KG 418:LA 422:LB 426:LS 428:LV 430:LR 434:LY 438:LI 440:LT 442:LU 446:MO 450:MG 454:MW 458:MY
    462:MV 466:ML 470:MT 474:MQ 478:MR 480:MU 484:MX 492:MC 496:MN 498:MD 499:ME 500:MS 504:MA 508:MZ 512:OM 516:NA
    520:NR 524:NP 528:NL 531:CW 533:AW 534:SX 535:BQ 540:NC 548:VU 554:NZ 558:NI 562:NE 566:NG 570:NU 574:NF 578:NO
    580:MP 581:UM 583:FM 584:MH 585:PW 586:PK 591:PA 598:PG 600:PY 604:PE 608:PH 612:PN 616:PL 620:PT 624:GW 626:TL
    630:PR 634:QA 638:RE 642:RO 643:RU 646:RW 652:BL 654:SH 659:KN 660:AI 662:LC 663:MF 666:PM 670:VC 674:SM 678:ST
    682:SA 686:SN 688:RS 690:SC 694:SL 702:SG 703:SK 704:VN 705:SI 706:SO 710:ZA 716:ZW 724:ES 728:SS 729:SD 732:EH
    740:SR 744:SJ 748:SZ 752:SE 756:CH 760:SY 762:TJ 764:TH 768:TG 772:TK 776:TO 780:TT 784:AE 788:TN 792:TR 795:TM
    796:TC 798:TV 800:UG 804:UA 807:MK 818:EG 826:GB 831:GG 832:JE 833:IM 834:TZ 840:US 850:VI 854:BF 858:UY 860:UZ
    862:VE 876:WF 882:WS 887:YE 894:ZM
    """.split()
)


# --------------------------------------------------------------------------------------------------------------------
# Errors, the clock and the secret scrubber


class PlatformError(Exception):
    """A handled failure, printed as {"ok": false, "error": code, "message": message}."""

    def __init__(self, code: str, message: str, status: int | None = None, retry_after: int | None = None):
        super().__init__(message)
        self.code = code
        self.message = message
        self.status = status
        self.retry_after = retry_after

    def to_result(self) -> dict:
        result = failure(self.code, self.message)
        if self.code == "rate_limited":
            result["retry_after"] = self.retry_after
        return result


class LibrariesMissing(Exception):
    """The connectors (or their dependencies) aren't importable: a setup problem, not a platform error."""


class OutOfTime(BaseException):
    """Raised by the SIGALRM timer or the clock. A BaseException, so no library's `except Exception` swallows it."""


class Clock:
    def __init__(self, seconds: float):
        self.ends_at = time.monotonic() + seconds

    def remaining(self) -> float:
        return max(0.0, self.ends_at - time.monotonic())

    def check(self, need: float = 1.0) -> None:
        if self.remaining() < need:
            raise OutOfTime()

    def timeout(self) -> tuple[float, float]:
        left = self.remaining() - 1.0  # a second to spare for printing the result
        return (max(0.5, min(CONNECT_TIMEOUT, left)), max(0.5, min(READ_TIMEOUT, left)))


class Secrets:
    """Every session value (and the Spotify bearer token once known), removed from anything the helper writes."""

    MIN_LENGTH = 8

    def __init__(self) -> None:
        self._values: set[str] = set()

    def add(self, value) -> None:
        if not isinstance(value, str) or len(value) < self.MIN_LENGTH:
            return
        self._values.add(value)
        self._values.add(json.dumps(value)[1:-1])  # as it would appear inside JSON
        self._values.add(json.dumps(value, ensure_ascii=False)[1:-1])

    def scrub(self, text: str) -> str:
        for value in sorted(self._values, key=len, reverse=True):
            if value and value in text:
                text = text.replace(value, "[redacted]")
        return text


def failure(code: str, message: str) -> dict:
    return {"ok": False, "error": code, "message": message}


def utc_today() -> dt.date:
    return dt.datetime.now(dt.timezone.utc).date()


def utc_now() -> dt.datetime:
    return dt.datetime.now(dt.timezone.utc)


def iso_utc(moment: dt.datetime) -> str:
    return moment.astimezone(dt.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


class Bearer:
    """Spotify's bearer token for this run: the one Rails cached from an earlier run (used while it has more than
    TOKEN_MIN_LIFE left), and whether this run had to sign in for a fresh one (then it goes back to Rails)."""

    def __init__(self, cached: tuple | None = None):
        self.value, self.expires_at = cached if cached else (None, None)
        self.fresh = False

    def usable(self) -> bool:
        return self.value is not None and (self.expires_at - utc_now()).total_seconds() > TOKEN_MIN_LIFE

    def renewed(self, value, expires_at: dt.datetime) -> None:
        self.value, self.expires_at, self.fresh = value, expires_at, True

    def result(self) -> dict | None:
        """The fresh token for Rails, or None when this run used the cached one (or never signed in)."""
        if not self.fresh or not isinstance(self.value, str):
            return None
        return {"value": self.value, "expires_at": iso_utc(self.expires_at)}


@contextmanager
def time_limit(seconds: float):
    """SIGALRM after `seconds`, raising OutOfTime wherever the code is (a blocking socket read included)."""
    if threading.current_thread() is not threading.main_thread() or not hasattr(signal, "SIGALRM"):
        yield
        return

    def on_alarm(signum, frame):
        raise OutOfTime()

    previous = signal.signal(signal.SIGALRM, on_alarm)
    signal.setitimer(signal.ITIMER_REAL, seconds)
    try:
        yield
    finally:
        signal.setitimer(signal.ITIMER_REAL, 0)
        signal.signal(signal.SIGALRM, previous)


# --------------------------------------------------------------------------------------------------------------------
# The request


def parse_request(raw: bytes, secrets: Secrets) -> dict:
    """The validated request. Never puts any part of the input in an error message."""
    if len(raw) > MAX_STDIN_BYTES:
        raise PlatformError("failed", "Invalid request: more than 64 KB on stdin.")
    try:
        request = json.loads(raw.decode("utf-8"))
    except (UnicodeDecodeError, ValueError):
        raise PlatformError("failed", "Invalid request: stdin must be one JSON object.") from None
    if not isinstance(request, dict):
        raise PlatformError("failed", "Invalid request: stdin must be one JSON object.")

    session = request.get("session")
    if isinstance(session, dict):
        for value in session.values():  # scrub every session value, even ones we don't use, from here on
            secrets.add(value)
    token = request.get("token")
    if isinstance(token, dict):
        secrets.add(token.get("value"))

    platform = request.get("platform")
    if platform not in REQUIRED_SESSION_KEYS:
        raise PlatformError("failed", 'Invalid request: platform must be "spotify" or "apple".')
    if not isinstance(session, dict):
        raise PlatformError("failed", "Invalid request: session must be an object.")
    cookies = {}
    for key in REQUIRED_SESSION_KEYS[platform] + OPTIONAL_SESSION_KEYS[platform]:
        value = session.get(key)
        if key in OPTIONAL_SESSION_KEYS[platform] and (value is None or value == ""):
            cookies[key] = ""
            continue
        if not isinstance(value, str) or not value.strip():
            raise PlatformError("failed", f"Invalid request: the {platform} session needs {key}.")
        if len(value) < Secrets.MIN_LENGTH or len(value) > 8192 or re.search(r"[\x00-\x1f\x7f]", value):
            raise PlatformError("failed", f"Invalid request: the {platform} session's {key} doesn't look right.")
        cookies[key] = value

    show_id = request.get("show_id")
    if not isinstance(show_id, str) or not SHOW_ID_FORMATS[platform].match(show_id):
        kind = "22 letters and digits" if platform == "spotify" else "digits"
        raise PlatformError("failed", f"Invalid request: a {platform} show_id is {kind}.")

    start, end = parse_date(request.get("start"), "start"), parse_date(request.get("end"), "end")
    if end < start:
        raise PlatformError("failed", "Invalid request: end is before start.")
    if (end - start).days + 1 > MAX_WINDOW_DAYS:
        raise PlatformError("failed", f"Invalid request: the window is longer than {MAX_WINDOW_DAYS} days.")

    parsed = {"platform": platform, "show_id": show_id, "start": start, "end": end, "session": cookies, "token": None}
    if platform == "spotify":
        parsed["base_url"] = spotify_base_url(session.get("base_url"))
        parsed["client_id"] = spotify_client_id(session.get("client_id"))
        parsed["token"] = parse_token(token)
    return parsed


def parse_token(token) -> tuple | None:
    """A cached bearer token: (value, expires_at in UTC), or None when there is none or it doesn't look right. A bad
    one isn't an error: the helper just signs in, as it would without one."""
    if not isinstance(token, dict):
        return None
    value, expires = token.get("value"), token.get("expires_at")
    if not isinstance(value, str) or not Secrets.MIN_LENGTH <= len(value) <= 4096 or re.search(r"[\s\x00-\x1f\x7f]", value):
        return None
    if not isinstance(expires, str) or not re.match(r"\A\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z\Z", expires):
        return None
    try:
        return value, dt.datetime.fromisoformat(expires[:-1]).replace(tzinfo=dt.timezone.utc)
    except ValueError:
        return None


def parse_date(value, name: str) -> dt.date:
    if not isinstance(value, str) or not re.match(r"\A\d{4}-\d{2}-\d{2}\Z", value):
        raise PlatformError("failed", f"Invalid request: {name} must be a YYYY-MM-DD date.")
    try:
        return dt.date.fromisoformat(value)
    except ValueError:
        raise PlatformError("failed", f"Invalid request: {name} is not a real date.") from None


def spotify_base_url(value) -> str:
    if value is None:
        return SPOTIFY_BASE_URL
    parsed = urlparse(value) if isinstance(value, str) else None
    host = (parsed.hostname or "") if parsed else ""
    if not parsed or parsed.scheme != "https" or not (host == "spotify.com" or host.endswith(".spotify.com")):
        raise PlatformError("failed", "Invalid request: base_url must be an https spotify.com address.")
    return value.rstrip("/")


def spotify_client_id(value) -> str:
    if value is None:
        return SPOTIFY_CLIENT_ID
    if not isinstance(value, str) or not re.match(r"\A[0-9a-f]{32}\Z", value):
        raise PlatformError("failed", "Invalid request: client_id must be 32 hex characters.")
    return value


def spotify_windows(start: dt.date, end: dt.date, today: dt.date):
    """(main, fallback): the window moved back to end by yesterday, and the same length ending the day before."""
    yesterday, day_before = today - dt.timedelta(days=1), today - dt.timedelta(days=2)
    shift = max(dt.timedelta(0), end - yesterday)
    main = (start - shift, end - shift)
    if main[1] <= day_before:
        return main, None
    back = main[1] - day_before
    return main, (main[0] - back, day_before)


# --------------------------------------------------------------------------------------------------------------------
# Libraries, logging and the connectors


def import_libraries() -> dict:
    """The connector modules, or LibrariesMissing with a plain how to fix it."""
    try:
        import appleconnector
        import requests
        import spotifyconnector
        import spotifyconnector.connector
        import tenacity
        from loguru import logger
    except ImportError as error:
        name = getattr(error, "name", None) or "a library"
        raise LibrariesMissing(
            f"The stats helper's Python libraries are missing ({name}). Production has them in /opt/stats-venv "
            "(see the Dockerfile). For development: python3 -m venv ~/.venvs/midrolo-stats, then "
            "~/.venvs/midrolo-stats/bin/pip install -r requirements-stats.txt, then run "
            "PLATFORM_STATS_PYTHON=~/.venvs/midrolo-stats/bin/python bin/platform-stats."
        ) from None
    return {"requests": requests, "tenacity": tenacity, "logger": logger,
            "spotifyconnector": spotifyconnector, "appleconnector": appleconnector}


def configure_logging(logger, secrets: Secrets) -> None:
    """Loguru at ERROR on stderr, message only (never the exception or its locals), scrubbed of every secret."""

    def sink(message) -> None:
        record = message.record
        text = secrets.scrub(f"platform-stats {record['level'].name}: {record['message']}")
        sys.stderr.write(text[:500] + "\n")

    logger.remove()
    logger.add(sink, level="ERROR", backtrace=False, diagnose=False, catch=True)


def library_version(name: str) -> str | None:
    try:
        from importlib.metadata import version

        return version(name)
    except Exception:  # noqa: BLE001 (any metadata problem just means "unknown")
        return None


class Http:
    """One GET at a time with timeouts, a little retrying for required calls, and plain error codes."""

    def __init__(self, libs: dict, platform: str, clock: Clock, secrets: Secrets):
        self.requests = libs["requests"]
        self.session = self.requests.Session()
        self.session.trust_env = False  # no proxies or .netrc credentials from the environment
        self.name = PLATFORM_NAMES[platform]
        self.clock = clock
        self.secrets = secrets
        self.retries_allowed = TRANSIENT_RETRIES

    @contextmanager
    def single_attempt(self):
        previous, self.retries_allowed = self.retries_allowed, 0
        try:
            yield
        finally:
            self.retries_allowed = previous

    def get_json(self, url: str, *, params=None, headers=None, cookies=None, reauthenticate=None):
        label = urlparse(url).path.rstrip("/").rsplit("/", 1)[-1] or "a request"
        retries = 0
        reauthenticated = False
        while True:
            self.clock.check()
            try:
                response = self.session.get(url, params=params, headers=headers() if headers else None,
                                            cookies=cookies, timeout=self.clock.timeout(), allow_redirects=False)
            except (self.requests.exceptions.ConnectionError, self.requests.exceptions.Timeout) as error:
                kind = "timed out" if isinstance(error, self.requests.exceptions.Timeout) else "could not connect"
                if retries < self.retries_allowed and self.clock.remaining() > READ_TIMEOUT + 5:
                    retries += 1
                    continue
                raise PlatformError("failed", f"{self.name} {kind} on {label}.") from None
            except self.requests.exceptions.RequestException as error:
                raise PlatformError("failed", f"{self.name} request for {label} failed ({type(error).__name__}).") from None

            status = response.status_code
            asked = retry_after_seconds(response.headers.get("Retry-After"))
            if status in TRANSIENT_STATUSES and retries < self.retries_allowed:
                # Only a short wait is waited out here, and only inside the time budget. A longer one is the
                # platform asking Midrolo to stay away: that ends the run, and Rails keeps away (Stats::Throttle).
                wait = float(asked) if asked is not None else 2.0 * (retries + 1)
                if wait <= IN_RUN_WAIT_LIMIT and self.clock.remaining() > wait + READ_TIMEOUT + 2:
                    retries += 1
                    time.sleep(wait)
                    continue
            if status == 429:
                raise rate_limited(self.name, label, asked)
            if status == 401 and reauthenticate is not None and not reauthenticated:
                reauthenticated = True
                reauthenticate()
                continue
            if 300 <= status < 400:
                raise redirect_error(self.name, label, status, response.headers.get("Location", ""))
            if status == 401:
                raise PlatformError("expired", f"{self.name} answered 401 on {label}: the service session has expired.",
                                    status)
            if status == 403:
                raise PlatformError("forbidden", f"{self.name} answered 403 on {label}: the Midrolo account has no "
                                                 "access to this show.", status)
            if status == 404:
                raise PlatformError("not_found", f"{self.name} answered 404 on {label}: no such show for the Midrolo "
                                                 "account.", status)
            if status >= 400:
                raise PlatformError("failed", f"{self.name} answered {status} on {label}.", status)
            try:
                return response.json()
            except ValueError:
                raise PlatformError("failed", f"{self.name} answered {label} with something that is not JSON.") from None


def retry_after_seconds(value) -> int | None:
    """The wait a platform asked for in a Retry-After header (seconds, or an HTTP date), in whole seconds from now and
    at most MAX_RETRY_AFTER; None when it didn't say or said something unreadable."""
    if value is None:
        return None
    text = str(value).strip()
    if re.match(r"\A\d{1,12}\Z", text):
        seconds = int(text)
    else:
        try:
            when = email.utils.parsedate_to_datetime(text)
        except (TypeError, ValueError, IndexError, OverflowError):
            return None
        if when is None:
            return None
        if when.tzinfo is None:
            when = when.replace(tzinfo=dt.timezone.utc)
        seconds = math.ceil((when - utc_now()).total_seconds())
    return max(0, min(MAX_RETRY_AFTER, seconds))


def rate_limited(name: str, label: str, asked: int | None) -> PlatformError:
    wait = f" It asked for a wait of {asked} seconds." if asked is not None else ""
    return PlatformError("rate_limited", f"{name} answered 429 on {label}: too many requests.{wait}", 429, asked)


def redirect_error(name: str, label: str, status: int, location: str) -> PlatformError:
    target = urlparse(location)
    host = (target.hostname or "").lower()
    if host in SIGN_IN_HOSTS or re.search(r"login|signin|sign-in|auth", target.path or "", re.I):
        return PlatformError("expired", f"{name} sent {label} to its sign in page: the service session has expired.",
                             status)
    return PlatformError("failed", f"{name} answered {label} with a redirect ({status}).", status)


class BoundedRequests:
    """Stands in for `requests` inside spotifyconnector.connector, so its sign in (which passes timeout=60 to
    requests.get and requests.post) uses the helper's timeouts. Everything else passes through."""

    def __init__(self, requests, clock: Clock):
        self._requests = requests
        self._clock = clock

    def get(self, *args, **kwargs):
        self._clock.check()
        kwargs["timeout"] = self._clock.timeout()
        return self._requests.get(*args, **kwargs)

    def post(self, *args, **kwargs):
        self._clock.check()
        kwargs["timeout"] = self._clock.timeout()
        return self._requests.post(*args, **kwargs)

    def __getattr__(self, name):
        return getattr(self._requests, name)


def build_spotify(libs: dict, request: dict, http: Http, bearer: Bearer | None = None):
    """openpodcast's SpotifyConnector with Midrolo's HTTP loop, a sign in that fits the time budget, and the cached
    bearer token (bearer): it signs in only when that token is missing or about to expire, or Spotify refuses it."""
    requests = libs["requests"]
    tenacity = libs["tenacity"]
    connector_module = libs["spotifyconnector"].connector
    CredentialsExpired, SpotifyConnector = connector_module.CredentialsExpired, connector_module.SpotifyConnector
    connector_module.requests = BoundedRequests(requests, http.clock)
    bearer = bearer or Bearer(request.get("token"))

    def transient(error) -> bool:
        if isinstance(error, (requests.exceptions.ConnectionError, requests.exceptions.Timeout)):
            return True
        if isinstance(error, requests.exceptions.HTTPError):
            # Not a 429: signing in again a second later is exactly what a rate limit asks us not to do.
            status = getattr(getattr(error, "response", None), "status_code", None)
            return status is not None and status >= 500
        return False

    class MidroloSpotifyConnector(SpotifyConnector):
        _authenticate = tenacity.retry(
            retry=tenacity.retry_if_exception(transient),
            wait=tenacity.wait_exponential(multiplier=1, max=4),
            stop=tenacity.stop_after_attempt(3) | tenacity.stop_after_delay(SIGN_IN_BUDGET),
            reraise=True,
        )(SpotifyConnector._authenticate.__wrapped__)

        def _signed_in(self, step) -> None:
            try:
                step()
            except CredentialsExpired:
                raise PlatformError("expired", "Spotify asked the Midrolo account to sign in again: paste a fresh "
                                               "sp_dc.") from None
            except requests.exceptions.HTTPError as error:
                response = getattr(error, "response", None)
                status = getattr(response, "status_code", None)
                if status == 429:
                    headers = getattr(response, "headers", None) or {}
                    raise rate_limited("Spotify", "its sign in", retry_after_seconds(headers.get("Retry-After"))) from None
                if status is not None and 400 <= status < 500:
                    raise PlatformError("expired", f"Spotify's sign in answered {status}: the service session has "
                                                   "expired.", status) from None
                raise PlatformError("failed", f"Spotify's sign in answered {status}. Try again later.", status) from None
            except (requests.exceptions.ConnectionError, requests.exceptions.Timeout):
                raise PlatformError("failed", "Could not reach Spotify's sign in.") from None
            except PlatformError:
                raise
            except Exception as error:  # noqa: BLE001 (class name only, the message could quote the sign in page)
                raise PlatformError("failed", f"Spotify's sign in failed ({type(error).__name__}): the session may "
                                              "have expired, or Spotify changed its sign in page.") from None
            http.secrets.add(self._bearer)
            # The connector keeps the expiry as local wall time; Rails gets it in UTC.
            expires = self._bearer_expires
            left = expires - dt.datetime.now() if isinstance(expires, dt.datetime) else dt.timedelta(0)
            bearer.renewed(self._bearer, utc_now() + left)

        # Not the connector's own check, which renews a token only once it is 5 minutes past its expiry.
        def _ensure_auth(self) -> None:
            if not bearer.usable():
                self._signed_in(self._authenticate)

        def _request(self, url, *, params=None):
            self._ensure_auth()
            return http.get_json(url, params=params, headers=lambda: {"Authorization": f"Bearer {self._bearer}"},
                                 reauthenticate=lambda: self._signed_in(self._authenticate))

    session = request["session"]
    connector = MidroloSpotifyConnector(request["base_url"], request["client_id"], request["show_id"],
                                        session["sp_dc"], session["sp_key"])
    if bearer.usable():
        http.secrets.add(bearer.value)
        connector._bearer = bearer.value
    return connector


def build_apple(libs: dict, request: dict, http: Http):
    """openpodcast's AppleConnector with Midrolo's HTTP loop (its own logs the request headers, cookies included)."""
    AppleConnector = libs["appleconnector"].AppleConnector

    class MidroloAppleConnector(AppleConnector):
        def _request(self, endpoint, *, params=None):
            return http.get_json(self._build_url(endpoint), params={**self.default_params, **(params or {})},
                                 headers=lambda: {"Accept": "application/json, text/plain, */*"},
                                 cookies={"myacinfo": self.myacinfo, "itctx": self.itctx})

    session = request["session"]
    return MidroloAppleConnector(request["show_id"], session["myacinfo"], session["itctx"])


# --------------------------------------------------------------------------------------------------------------------
# Fetching


class Fetch:
    """Notes and unavailable keys for one fetch, and the optional call wrapper."""

    def __init__(self, http: Http):
        self.http = http
        self.clock = http.clock
        self.notes: list[str] = []
        self.unavailable: list[str] = []

    def optional(self, what: str, keys: list, call, window=None, fallback=None):
        """call(*window) with one attempt. A 5xx is tried once more with the fallback window. Returns (answer,
        window used), or (None, None) with a note and the keys marked unavailable. An expired session or a rate
        limit still ends the fetch (no more calls once the platform asks for fewer)."""
        attempts = [window] + ([fallback] if fallback else [])
        for index, dates in enumerate(attempts):
            if self.clock.remaining() < OPTIONAL_CALL_MIN_SECONDS:
                self.skip(keys, f"Skipped {what}: not enough time left.")
                return None, None
            try:
                with self.http.single_attempt():
                    return (call(*dates) if dates else call()), dates
            except PlatformError as error:
                if error.code in ("expired", "rate_limited"):
                    raise
                retry = error.status is not None and error.status >= 500 and index + 1 < len(attempts)
                if not retry:
                    self.skip(keys, f"Left out {what}: {error.message}")
                    return None, None
        return None, None

    def skip(self, keys: list, note: str) -> None:
        self.notes.append(note)
        self.unavailable += [key for key in keys if key not in self.unavailable]


def fetch(libs: dict, request: dict, clock: Clock, secrets: Secrets, bearer: Bearer | None = None) -> dict:
    http = Http(libs, request["platform"], clock, secrets)
    if request["platform"] == "spotify":
        return fetch_spotify(libs, request, http, bearer or Bearer(request.get("token")))
    return fetch_apple(libs, request, http)


def fetch_spotify(libs: dict, request: dict, http: Http, bearer: Bearer) -> dict:
    connector = build_spotify(libs, request, http, bearer)
    run = Fetch(http)
    today = utc_today()
    window, fallback = spotify_windows(request["start"], request["end"], today)

    metadata = connector.metadata()  # GET shows/{id}/metadata: name and the all time totals; required
    streams, streams_window = run.optional("streams and starts", ["streams", "starts"], connector.streams,
                                           window, fallback)  # GET shows/{id}/detailedStreams
    listeners, listeners_window = run.optional("listeners", ["listeners"], connector.listeners,
                                               window, fallback)  # GET shows/{id}/listeners
    aggregate, aggregate_window = run.optional("the audience breakdowns", ["audience_listeners", "age", "gender",
                                                                           "country"],
                                               connector.aggregate, window, fallback)  # GET shows/{id}/aggregate
    followers = None
    if not isinstance(metadata, dict) or count(metadata.get("followers")) is None:
        followers, _ = run.optional("followers", ["followers"], connector.followers, window, fallback)

    answers = {"metadata": metadata, "streams": streams, "listeners": listeners, "aggregate": aggregate,
               "followers": followers}
    windows = {"streams": streams_window, "listeners": listeners_window, "audience": aggregate_window}
    result = normalize_spotify(request["show_id"], request["start"], request["end"], window, today, answers,
                               windows, run.notes)
    result["unavailable"] = run.unavailable
    return finish(result, "spotify")


def fetch_apple(libs: dict, request: dict, http: Http) -> dict:
    Dimension, Metric = libs["appleconnector"].Dimension, libs["appleconnector"].Metric
    connector = build_apple(libs, request, http)
    run = Fetch(http)
    start, end = request["start"], request["end"]

    listeners = connector.trends(start, end, metric=Metric.LISTENERS, dimension=Dimension.BY_EPISODES)  # required
    followers, _ = run.optional("followers", ["followers"],
                                lambda: connector.trends(start, end, metric=Metric.FOLLOWERS))
    episodes, _ = run.optional("the show name", [], lambda: connector.episodes())
    countries, _ = run.optional("plays by country", ["country"],
                                lambda: connector.trends(start, end, metric=Metric.PLAYS,
                                                         dimension=Dimension.BY_COUNTRY))
    result = normalize_apple(request["show_id"], start, end, listeners, followers, episodes, countries, run.notes)
    for key in ("plays", "listeners", "engaged_listeners"):
        if key not in result["metrics"] and key not in run.unavailable:
            run.unavailable.append(key)
    result["unavailable"] = run.unavailable
    return finish(result, "apple")


def finish(result: dict, platform: str) -> dict:
    if not result["metrics"]:
        raise PlatformError("failed", f"{PLATFORM_NAMES[platform]} answered, but with no numbers for this show. "
                                      + " ".join(result["notes"]))
    package = f"{platform}connector"
    result["connector"] = f"{package}=={library_version(package) or PINNED[package]}"
    return result


# --------------------------------------------------------------------------------------------------------------------
# Normalization (pure functions, no network)


def count(value) -> int | None:
    """A non negative whole number from an API value (Apple sends floats like 130.0), else None."""
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        return None
    if isinstance(value, float) and not math.isfinite(value):
        return None
    return int(round(value)) if value >= 0 else None


def iso_date(value) -> dt.date | None:
    if isinstance(value, str) and re.match(r"\A\d{4}-\d{2}-\d{2}", value):
        try:
            return dt.date.fromisoformat(value[:10])
        except ValueError:
            return None
    return None


def bucket_date(value) -> dt.date | None:
    """Apple's timebucket, a yyyymmdd number sent as a float (20221031.0)."""
    number = count(value)
    if number is None:
        return None
    try:
        return dt.date(number // 10000, number // 100 % 100, number % 100)
    except ValueError:
        return None


def shares(counts: dict, order=None, top: int | None = None) -> dict | None:
    """{key: share of the total}, rounded to 4 places; None when there's nothing to share out."""
    clean = {key: value for key, value in counts.items() if value is not None and value >= 0}
    total = sum(clean.values())
    if total <= 0:
        return None
    if top is not None:
        ranked = sorted(((key, value) for key, value in clean.items() if value > 0), key=lambda kv: (-kv[1], kv[0]))
        kept = dict(ranked[:top])
        rest = sum(value for _, value in ranked[top:])
        if rest > 0:
            kept["other"] = rest
        clean = kept
    keys = list(clean)
    if order is not None:
        keys = [key for key in order if key in clean] + sorted(key for key in clean if key not in order)
    return {key: round(clean[key] / total, 4) for key in keys}


def gender_total(entry) -> int | None:
    counts = entry.get("counts") if isinstance(entry, dict) else None
    if not isinstance(counts, dict):
        return None
    values = [count(value) for value in counts.values()]
    values = [value for value in values if value is not None]
    return sum(values) if values else None


def safe_http_url(value) -> str | None:
    if isinstance(value, str) and len(value) <= 2048 and re.match(r"\Ahttps?://[^\s]+\Z", value):
        return value
    return None


def safe_name(value) -> str | None:
    if isinstance(value, str):
        text = re.sub(r"[\x00-\x1f\x7f]+", " ", value).strip()
        return text[:300] or None
    return None


def daily_sum(rows, key: str, dates) -> int | None:
    """The sum of `key` over the daily rows inside the window; 0 for an empty list (nothing that window)."""
    if not isinstance(rows, list) or dates is None:
        return None
    values = [count(row.get(key)) for row in rows
              if isinstance(row, dict) and in_window(iso_date(row.get("date")), *dates)]
    values = [value for value in values if value is not None]
    if not values and rows:
        return None  # rows, but none usable: a shape change, not a zero
    return sum(values)


def window_dict(dates) -> dict:
    start, end = dates
    return {"start": start.isoformat(), "end": end.isoformat(), "days": (end - start).days + 1}


def normalize_spotify(show_id, requested_start, requested_end, window, today, answers, windows, notes) -> dict:
    """answers: metadata, streams, listeners, aggregate, followers (None when not fetched). windows: the dates each
    window call covered (streams, listeners, audience), None when it wasn't fetched."""
    metrics, breakdowns = {}, {}
    metadata = answers.get("metadata") if isinstance(answers.get("metadata"), dict) else {}

    show = {"id": show_id}
    if safe_name(metadata.get("name")):
        show["name"] = safe_name(metadata.get("name"))
    if safe_http_url(metadata.get("feedUrl")):
        show["rss_url"] = safe_http_url(metadata.get("feedUrl"))
    release = iso_date(metadata.get("releaseDate"))
    if release:
        show["release_date"] = release.isoformat()

    detailed = answers.get("streams")
    if isinstance(detailed, dict):
        for key in ("streams", "starts"):
            total = daily_sum(detailed.get("detailedStreams"), key, windows.get("streams"))
            if total is None:
                notes.append(f"Left out {key}: Spotify's daily streams came in a shape this helper doesn't read.")
            else:
                metrics[key] = total
    listeners = answers.get("listeners")
    if isinstance(listeners, dict):
        total = daily_sum(listeners.get("counts"), "count", windows.get("listeners"))
        if total is None:
            notes.append("Left out listeners: Spotify's daily listeners came in a shape this helper doesn't read.")
        else:
            metrics["listeners"] = total

    for key in ("streams", "starts", "listeners"):
        if count(metadata.get(key)) is not None:
            metrics[f"{key}_all_time"] = count(metadata.get(key))
    if count(metadata.get("followers")) is not None:
        metrics["followers"] = count(metadata.get("followers"))
    elif latest_follower_count(answers.get("followers"), *window) is not None:
        metrics["followers"] = latest_follower_count(answers.get("followers"), *window)

    aggregate = answers.get("aggregate")
    if isinstance(aggregate, dict):
        if count(aggregate.get("count")) is not None:
            metrics["audience_listeners"] = count(aggregate.get("count"))
        breakdowns.update(spotify_breakdowns(aggregate))
        if not breakdowns:
            notes.append("Left out the audience breakdowns: Spotify had no age, gender or country data for this window.")

    period = {
        **window_dict(window),
        "requested": {"start": requested_start.isoformat(), "end": requested_end.isoformat()},
        "windows": {name: window_dict(dates) for name, dates in windows.items() if dates},
        "all_time": {"start": show.get("release_date"), "end": today.isoformat()},
    }
    return result_for("spotify", show, period, metrics, breakdowns, notes)


def spotify_breakdowns(aggregate: dict) -> dict:
    breakdowns = {}
    ages = aggregate.get("ageFacetedCounts")
    if isinstance(ages, dict):
        age_counts = {}
        for bucket, entry in ages.items():
            key = SPOTIFY_AGE_BUCKETS.get(bucket, bucket if SAFE_KEY.match(str(bucket)) else None)
            if key is not None and gender_total(entry) is not None:
                age_counts[key] = age_counts.get(key, 0) + gender_total(entry)
        age = shares(age_counts, order=list(SPOTIFY_AGE_BUCKETS.values()))
        if age:
            breakdowns["age"] = age
    gendered = aggregate.get("genderedCounts")
    gendered = gendered.get("counts") if isinstance(gendered, dict) else None
    if isinstance(gendered, dict):
        gender_counts = {}
        for raw, value in gendered.items():
            key = SPOTIFY_GENDERS.get(raw, raw.lower() if SAFE_KEY.match(str(raw)) else None)
            if key is not None and count(value) is not None:
                gender_counts[key] = count(value)
        gender = shares(gender_counts, order=list(SPOTIFY_GENDERS.values()))
        if gender:
            breakdowns["gender"] = gender
    countries = aggregate.get("countryFacetedCounts")
    if isinstance(countries, dict):
        country_counts = {}
        for entry in countries.values():
            code = entry.get("countryCode") if isinstance(entry, dict) else None
            if isinstance(code, str) and re.match(r"\A[A-Za-z]{2}\Z", code) and gender_total(entry) is not None:
                country_counts[code.upper()] = country_counts.get(code.upper(), 0) + gender_total(entry)
        country = shares(country_counts, top=TOP_COUNTRIES)
        if country:
            breakdowns["country"] = country
    return breakdowns


def latest_follower_count(followers, start, end) -> int | None:
    rows = followers.get("counts") if isinstance(followers, dict) else None
    if not isinstance(rows, list):
        return None
    dated = sorted(
        ((iso_date(row.get("date")), count(row.get("count"))) for row in rows if isinstance(row, dict)),
        key=lambda pair: pair[0] or dt.date.min,
    )
    dated = [(day, value) for day, value in dated if day is not None and value is not None and in_window(day, start, end)]
    if not dated:
        return None
    nonzero = [value for _, value in dated if value > 0]
    # Spotify reports 0 for days it hasn't processed yet, so a trailing 0 after real counts isn't the total.
    return nonzero[-1] if nonzero else 0


def normalize_apple(show_id, start, end, listeners, followers, episodes, countries, notes) -> dict:
    metrics, breakdowns = {}, {}
    show = {"id": show_id}
    name = apple_show_name(episodes)
    if name:
        show["name"] = name

    listeners = listeners if isinstance(listeners, dict) else {}
    totals = listeners.get("showPlayCount")
    totals = totals.get("latestValue") if isinstance(totals, dict) else None
    if isinstance(totals, dict):
        bucket = bucket_date(totals.get("timebucket"))
        if bucket is not None and bucket != start:
            notes.append("Left out listeners and engaged listeners: Apple's totals cover a window starting on "
                         "another day.")
            totals = None
    if isinstance(totals, dict):
        for key, field in (("plays", "playscount"), ("listeners", "uniquelistenerscount"),
                           ("engaged_listeners", "uniqueengagedlistenerscount")):
            if count(totals.get(field)) is not None:
                metrics[key] = count(totals.get(field))
    if "plays" not in metrics:
        daily = listeners.get("showPlayCountTrends")
        values = [count(row.get("playscount")) for row in daily
                  if isinstance(row, dict) and in_window(bucket_date(row.get("timebucket")), start, end)] \
            if isinstance(daily, list) else []
        values = [value for value in values if value is not None]
        if values:
            metrics["plays"] = sum(values)
        else:
            notes.append("Left out plays: Apple sent no play counts for this window.")

    followers_total = apple_followers(followers, end)
    if followers_total is not None:
        metrics["followers"] = followers_total

    country_shares, country_rank = apple_countries(countries)
    if country_shares:
        breakdowns["country"] = country_shares
    elif isinstance(countries, dict):
        keys = [key for key in countries if isinstance(key, str) and SAFE_KEY.match(key)][:15]
        notes.append("Left out plays by country: Apple's answer has a shape this helper doesn't read yet (keys: "
                     + (", ".join(keys) or "none") + ").")
    _, listener_rank = apple_countries(listeners)
    if listener_rank or country_rank:
        breakdowns["country_rank"] = listener_rank or country_rank

    period = {**window_dict((start, end)), "requested": {"start": start.isoformat(), "end": end.isoformat()}}
    return result_for("apple", show, period, metrics, breakdowns, notes)


def apple_show_name(episodes) -> str | None:
    content = episodes.get("content") if isinstance(episodes, dict) else None
    results = content.get("results") if isinstance(content, dict) else None
    if isinstance(results, dict):
        for episode in results.values():
            if isinstance(episode, dict) and safe_name(episode.get("collectionName")):
                return safe_name(episode.get("collectionName"))
    return None


def apple_followers(followers, end) -> int | None:
    if not isinstance(followers, dict):
        return None
    rows = followers.get("followerAllTimeTrends")
    if isinstance(rows, list):
        dated = []
        for row in rows:
            if isinstance(row, list) and len(row) >= 3:
                day, total, lost = bucket_date(row[0]), count(row[1]), count(row[2])
                if day is not None and day <= end and total is not None and lost is not None:
                    dated.append((day, max(0, total - lost)))
        if dated:
            return max(dated)[1]
    overall = followers.get("allTimeFollowers")
    overall = overall.get("all") if isinstance(overall, dict) else None
    return count(overall.get("current")) if isinstance(overall, dict) else None


def apple_countries(answer) -> tuple[dict | None, list | None]:
    """Shares from showTopCountries {numeric: {"latestValue": n}}, or the ranked codes from a showTopCountries list."""
    top = answer.get("showTopCountries") if isinstance(answer, dict) else None
    if isinstance(top, dict):
        counts = {}
        for numeric, entry in top.items():
            code = ISO_NUMERIC.get(count_code(numeric))
            value = count(entry.get("latestValue")) if isinstance(entry, dict) else None
            if code and value is not None:
                counts[code] = counts.get(code, 0) + value
        ranked = [code for code, _ in sorted(counts.items(), key=lambda kv: (-kv[1], kv[0]))][:10]
        return shares(counts, top=TOP_COUNTRIES), ranked or None
    if isinstance(top, list):
        ranked = []
        for numeric in top:
            code = ISO_NUMERIC.get(count_code(numeric))
            if code and code not in ranked:
                ranked.append(code)
        return None, ranked[:10] or None
    return None, None


def count_code(value) -> int | None:
    if isinstance(value, str) and value.isdigit():
        return int(value)
    return count(value)


def in_window(day, start, end) -> bool:
    return day is not None and start <= day <= end


def result_for(platform, show, period, metrics, breakdowns, notes) -> dict:
    return {
        "ok": True,
        "platform": platform,
        "show": show,
        "period": period,
        "metrics": metrics,
        "breakdowns": breakdowns,
        "unavailable": [],
        "notes": notes,
    }


# --------------------------------------------------------------------------------------------------------------------
# Built in samples for --self-test. Hand written, shaped like the connectors' real answers (key names from Midrolo's
# live check and the connectors' source); the numbers are made up.

SAMPLE_TODAY = dt.date(2026, 10, 1)
SAMPLE_WINDOW = (dt.date(2026, 9, 1), dt.date(2026, 9, 30))

SAMPLE_SPOTIFY = {
    "metadata": {
        "artworkUrl": "https://i.scdn.co/image/sample", "categories": [], "consumptionOrder": "EPISODIC",
        "coverImage": "https://i.scdn.co/image/sample", "description": "A sample show.", "explict": False,
        "followers": 140, "hasPassthroughEnabled": False, "id": "4rOoJ6Egrf8K2IrywzwOMk", "language": "en",
        "listeners": 300, "name": "Sample Show", "network": {"id": "x", "name": "Sample", "doingBusinessAs": "Sample"},
        "published": True, "publisher": "Sample Publisher", "releaseDate": "2025-01-15",
        "shouldAllowVideoReplace": False, "sparkLine": [], "starts": 900, "streams": 700,
    },
    "streams": {"detailedStreams": [
        {"date": "2026-09-01", "starts": 40, "streams": 30},
        {"date": "2026-09-02", "starts": 25, "streams": 20},
        {"date": "2026-09-30", "starts": 0, "streams": 0},
    ]},
    "listeners": {"counts": [
        {"date": "2026-09-01", "count": 12}, {"date": "2026-09-02", "count": 9}, {"date": "2026-09-30", "count": 0},
    ]},
    "aggregate": {
        "count": 50, "start": "2026-09-01", "end": "2026-09-30",
        "ageFacetedCounts": {
            "18-22": {"counts": {"FEMALE": 5, "MALE": 5, "NON_BINARY": 0, "NOT_SPECIFIED": 0}},
            "28-34": {"counts": {"FEMALE": 10, "MALE": 15, "NON_BINARY": 0, "NOT_SPECIFIED": 0}},
            "60-150": {"counts": {"FEMALE": 5, "MALE": 0, "NON_BINARY": 0, "NOT_SPECIFIED": 0}},
            "unknown": {"counts": {"FEMALE": 0, "MALE": 0, "NON_BINARY": 0, "NOT_SPECIFIED": 10}},
        },
        "countryFacetedCounts": {
            "United States": {"counts": {"FEMALE": 10, "MALE": 20, "NON_BINARY": 0, "NOT_SPECIFIED": 5},
                              "countryCode": "US"},
            "Germany": {"counts": {"FEMALE": 10, "MALE": 0, "NON_BINARY": 0, "NOT_SPECIFIED": 5}, "countryCode": "DE"},
        },
        "genderedCounts": {"counts": {"FEMALE": 20, "MALE": 20, "NON_BINARY": 0, "NOT_SPECIFIED": 10}},
    },
    "followers": None,
}

SAMPLE_SPOTIFY_EXPECTED = {
    "show": {"id": "4rOoJ6Egrf8K2IrywzwOMk", "name": "Sample Show", "release_date": "2025-01-15"},
    "metrics": {"streams": 50, "starts": 65, "listeners": 21, "streams_all_time": 700, "starts_all_time": 900,
                "listeners_all_time": 300, "followers": 140, "audience_listeners": 50},
    "breakdowns": {
        "age": {"18-22": 0.2, "28-34": 0.5, "60+": 0.1, "unknown": 0.2},
        "gender": {"female": 0.4, "male": 0.4, "non_binary": 0.0, "not_specified": 0.2},
        "country": {"US": 0.7, "DE": 0.3},
    },
    "period": {
        "start": "2026-09-01", "end": "2026-09-30", "days": 30,
        "requested": {"start": "2026-09-01", "end": "2026-09-30"},
        "windows": {name: {"start": "2026-09-01", "end": "2026-09-30", "days": 30}
                    for name in ("streams", "listeners", "audience")},
        "all_time": {"start": "2025-01-15", "end": "2026-10-01"},
    },
}

SAMPLE_APPLE = {
    "listeners": {
        "measure": "LISTENERS", "dimension": "BY_EPISODES",
        "content": [["1000000000001", "Episode one", "2026-09-03T05:00:00Z", -1.0, None]],
        "showPlayCount": {
            "latestValue": {"followstate": "*", "playscount": 400.0, "podcastid": "1500000001",
                            "timebucket": 20260901.0, "totaltimelistened": 90000.0,
                            "uniqueengagedlistenerscount": 70.0, "uniquelistenerscount": 120.0},
            "previousValue": {"followstate": "*", "playscount": 350.0, "podcastid": "1500000001",
                              "timebucket": 20260802.0, "totaltimelistened": 80000.0,
                              "uniqueengagedlistenerscount": 60.0, "uniquelistenerscount": 110.0},
        },
        "showPlayCountTrends": [
            {"followstate": "*", "playscount": 150.0, "podcastid": "1500000001", "timebucket": 20260901.0,
             "totaltimelistened": 30000.0, "uniqueengagedlistenerscount": 20.0, "uniquelistenerscount": 50.0},
            {"followstate": "*", "playscount": 250.0, "podcastid": "1500000001", "timebucket": 20260902.0,
             "totaltimelistened": 60000.0, "uniqueengagedlistenerscount": 55.0, "uniquelistenerscount": 90.0},
        ],
        "showTopCountries": ["840", "276", "40"],
        "showTopCities": ["5128581"],
    },
    "followers": {
        "measure": "FOLLOWERS",
        "allTimeFollowers": {"base": {"previous": 80.0, "current": 85.0}, "all": {"previous": 85.0, "current": 92.0}},
        "followerAllTimeTrends": [[20260901.0, 95.0, 10.0], [20260930.0, 104.0, 12.0]],
        "followerGrowthTrends": [[20260915.0, 1.0, 0.0]],
    },
    "episodes": {"content": {"results": {"1000000000001": {
        "id": "1000000000001", "name": "Episode one", "collectionName": "Sample Show", "kind": "podcastEpisode",
        "releaseDate": "2026-09-03",
    }}}},
    "countries": {"measure": "PLAYS", "dimension": "BY_COUNTRY",
                  "showTopCountries": {"840": {"latestValue": 300.0}, "276": {"latestValue": 100.0}}},
}

SAMPLE_APPLE_EXPECTED = {
    "show": {"id": "1500000001", "name": "Sample Show"},
    "metrics": {"plays": 400, "listeners": 120, "engaged_listeners": 70, "followers": 92},
    "breakdowns": {"country": {"US": 0.75, "DE": 0.25}, "country_rank": ["US", "DE", "AT"]},
}


def sample_spotify_result() -> dict:
    windows = {name: SAMPLE_WINDOW for name in ("streams", "listeners", "audience")}
    return normalize_spotify("4rOoJ6Egrf8K2IrywzwOMk", *SAMPLE_WINDOW, SAMPLE_WINDOW, SAMPLE_TODAY, SAMPLE_SPOTIFY,
                             windows, [])


def sample_apple_result() -> dict:
    return normalize_apple("1500000001", *SAMPLE_WINDOW, SAMPLE_APPLE["listeners"], SAMPLE_APPLE["followers"],
                           SAMPLE_APPLE["episodes"], SAMPLE_APPLE["countries"], [])


def self_test() -> tuple[dict, int]:
    """Imports, pinned versions, the connector API this file uses, and the normalization on the samples."""
    libs = import_libraries()
    configure_logging(libs["logger"], Secrets())
    problems = []
    for package, version in PINNED.items():
        if library_version(package) != version:
            problems.append(f"{package} is {library_version(package)}, expected {version}")

    AppleConnector = libs["appleconnector"].AppleConnector
    Dimension, Metric = libs["appleconnector"].Dimension, libs["appleconnector"].Metric
    SpotifyConnector = libs["spotifyconnector"].connector.SpotifyConnector
    if not hasattr(libs["spotifyconnector"].connector, "CredentialsExpired"):
        problems.append("spotifyconnector.connector.CredentialsExpired is missing")
    for name in ("metadata", "streams", "listeners", "followers", "aggregate", "_ensure_auth", "_request"):
        if not callable(getattr(SpotifyConnector, name, None)):
            problems.append(f"SpotifyConnector.{name} is missing")
    if not callable(getattr(getattr(SpotifyConnector, "_authenticate", None), "__wrapped__", None)):
        problems.append("SpotifyConnector._authenticate is no longer wrapped by tenacity")
    for name in ("trends", "episodes", "_request", "_build_url"):
        if not callable(getattr(AppleConnector, name, None)):
            problems.append(f"AppleConnector.{name} is missing")
    for enum, names in ((Metric, ("LISTENERS", "FOLLOWERS", "PLAYS")), (Dimension, ("BY_EPISODES", "BY_COUNTRY"))):
        problems += [f"{enum.__name__}.{name} is missing" for name in names if not hasattr(enum, name)]

    secrets, clock = Secrets(), Clock(5)
    spotify_request = {"show_id": "4rOoJ6Egrf8K2IrywzwOMk", "base_url": SPOTIFY_BASE_URL,
                       "client_id": SPOTIFY_CLIENT_ID, "session": {"sp_dc": "x" * 8, "sp_key": ""}}
    apple_request = {"show_id": "1500000001", "session": {"myacinfo": "x" * 8, "itctx": "y" * 8}}
    build_spotify(libs, spotify_request, Http(libs, "spotify", clock, secrets))
    build_apple(libs, apple_request, Http(libs, "apple", clock, secrets))

    for platform, got, expected in (("spotify", sample_spotify_result(), SAMPLE_SPOTIFY_EXPECTED),
                                    ("apple", sample_apple_result(), SAMPLE_APPLE_EXPECTED)):
        for key, value in expected.items():
            if got.get(key) != value:
                problems.append(f"{platform} {key} normalized to {json.dumps(got.get(key))}")
    main_window, fallback = spotify_windows(dt.date(2026, 10, 1), dt.date(2026, 10, 30), dt.date(2026, 10, 30))
    if (main_window, fallback) != ((dt.date(2026, 9, 30), dt.date(2026, 10, 29)),
                                   (dt.date(2026, 9, 29), dt.date(2026, 10, 28))):
        problems.append("the Spotify window isn't moved back to end by yesterday")

    if problems:
        return {"ok": False, "self_test": True, "error": "failed", "message": "; ".join(problems)}, 1
    return {"ok": True, "self_test": True}, 0


# --------------------------------------------------------------------------------------------------------------------
# Entry point


def read_stdin() -> bytes:
    stream = getattr(sys.stdin, "buffer", sys.stdin)
    data = stream.read(MAX_STDIN_BYTES + 1)
    return data.encode("utf-8") if isinstance(data, str) else data


def run(raw: bytes, secrets: Secrets) -> tuple[dict, int]:
    """The result and exit code for one request. Every path returns sanitized JSON; nothing here prints. When the run
    signed in, the fresh bearer token rides along (result["token"]) on every result but "expired", so the next run
    can skip the sign in even after this one failed."""
    clock = Clock(TOTAL_TIMEOUT)
    bearer = Bearer()
    try:
        with time_limit(TOTAL_TIMEOUT):
            libs = import_libraries()
            configure_logging(libs["logger"], secrets)
            request = parse_request(raw, secrets)
            bearer = Bearer(request.get("token"))
            result, code = fetch(libs, request, clock, secrets, bearer), 0
    except PlatformError as error:
        result, code = error.to_result(), 0
    except OutOfTime:
        result, code = failure("failed", f"Timed out: the helper stops after {int(TOTAL_TIMEOUT)} seconds."), 0
    except LibrariesMissing as error:
        result, code = failure("failed", str(error)), 3
    except Exception as error:  # noqa: BLE001 (class name only: a message or traceback could carry a cookie)
        result, code = failure("failed", f"Unexpected error in the stats helper ({type(error).__name__})."), 1
    token = bearer.result()
    if token and result.get("error") != "expired":
        result["token"] = token
    return result, code


def main(argv=None) -> int:
    argv = sys.argv[1:] if argv is None else argv
    real_stdout = sys.stdout
    secrets = Secrets()
    if argv in (["-h"], ["--help"]):
        real_stdout.write(__doc__.strip() + "\n")
        return 0
    if argv and argv != ["--self-test"]:
        real_stdout.write(json.dumps(failure("failed", "Unknown arguments: use --self-test or no arguments.")) + "\n")
        return 2

    sys.stdout = sys.stderr  # stray prints from a library can't corrupt the one JSON line on stdout
    try:
        if argv == ["--self-test"]:
            try:
                result, code = self_test()
            except LibrariesMissing as error:
                result, code = {"ok": False, "self_test": True, "error": "failed", "message": str(error)}, 3
            except Exception as error:  # noqa: BLE001
                result, code = {"ok": False, "self_test": True, "error": "failed",
                                "message": f"Self test crashed ({type(error).__name__})."}, 1
        else:
            result, code = run(read_stdin(), secrets)
    finally:
        sys.stdout = real_stdout
    # Everything is scrubbed of every secret, then the fresh bearer token (if any) is put back in its own field: the
    # one place a secret is written, for Rails to cache encrypted.
    token = result.pop("token", None)
    line = secrets.scrub(json.dumps(result, ensure_ascii=True, separators=(",", ":")))
    if token:
        line = json.dumps({**json.loads(line), "token": token}, ensure_ascii=True, separators=(",", ":"))
    real_stdout.write(line + "\n")
    real_stdout.flush()
    return code


if __name__ == "__main__":
    if sys.version_info < (3, 10):
        sys.stdout.write(json.dumps(failure("failed", "The stats helper needs Python 3.10 or newer.")) + "\n")
        sys.exit(3)
    sys.exit(main())
