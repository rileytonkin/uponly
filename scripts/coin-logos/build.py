#!/usr/bin/env python3
"""Builds the coin logos and tickers Up Only ships: for each of the 10,000 largest coins CoinGecko lists, its ticker
and a small image of its logo.

  python3 -m pip install -r scripts/coin-logos/requirements.txt  # Pillow, pinned (Python 3.10+)
  python3 scripts/coin-logos/build.py list    # the LIMIT largest coins CoinGecko prices -> .context/coin-logos/coins.json
  python3 scripts/coin-logos/build.py fetch   # each coin's logo, cached in .context/coin-logos/images (reruns skip what's done)
  python3 scripts/coin-logos/build.py pack    # write UpOnly/Resources/CoinLogos.pack
  python3 scripts/coin-logos/build.py review  # contact sheet of the first 400, in a new temporary folder

The 250 largest coins keep their images in Assets.xcassets/CoinLogos; the pack holds every other coin's, and every
coin's ticker. The app reads logos and tickers only from these, so it never fetches one (that would tell a server
what you hold). Both are keyed by CoinGecko's ID for the coin, the ID each holding is saved under, and come from
CoinGecko's own listing for that ID: nothing is matched by name or ticker. An optional CoinGecko
demo key in COINGECKO_KEY lifts the listing's rate limit; nothing else needs one.

Pack format (little-endian), read by `CoinLogos` in the app:
  "UOLOGOS2"  magic, 8 bytes
  UInt32      count
  count x     (UInt32 id offset, UInt16 id length, UInt32 ticker offset, UInt8 ticker length, UInt32 image offset,
               UInt32 image length), sorted by id bytes; an image length of 0 is no image here
  ...         the ids' and tickers' bytes, then the images (WebP), offsets from the start of the file
"""
import concurrent.futures, io, json, os, re, struct, sys, tempfile, time, urllib.parse, urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
WORK = ROOT / ".context" / "coin-logos"
COINS = WORK / "coins.json"
CACHE = WORK / "images"
BUNDLED = ROOT / "UpOnly" / "Assets.xcassets" / "CoinLogos"
PACK = ROOT / "UpOnly" / "Resources" / "CoinLogos.pack"
SIZE = 56                               # as the bundled ones: 28 pt at 2x, the usual badge
QUALITY = 82
LIMIT = 10_000                          # coins, by market cap; the long tail past it is mostly dead tokens
AGENT = "UpOnly-logo-build/1"
ID = re.compile(r"[a-z0-9-]{1,150}")    # as MoneyInput.canonicalAssetID accepts; ids become file names
HOSTS = {"api.coingecko.com", "coin-images.coingecko.com", "assets.coingecko.com"}
MAGIC = b"UOLOGOS2"
ENTRY = "<IHIBII"
TICKER = re.compile(r"[\x21-\x7e]{1,20}")  # printable ASCII, as tickers are written


def get(url, tries=6):
    parts = urllib.parse.urlsplit(url)
    if parts.scheme != "https" or parts.hostname not in HOSTS:
        raise ValueError(f"refusing {url}")
    headers = {"User-Agent": AGENT}
    if parts.hostname == "api.coingecko.com" and os.environ.get("COINGECKO_KEY"):
        headers["x-cg-demo-api-key"] = os.environ["COINGECKO_KEY"]
    for attempt in range(tries):
        try:
            with urllib.request.urlopen(urllib.request.Request(url, headers=headers), timeout=30) as response:
                if urllib.parse.urlsplit(response.geturl()).hostname not in HOSTS:
                    raise ValueError(f"redirected off the allowed hosts: {url}")
                return response.read(4 * 1024 * 1024)
        except urllib.error.HTTPError as error:
            if error.code in (403, 404, 410):
                return None
            if error.code != 429 and error.code < 500:
                raise
            time.sleep(min(60, 5 * 2 ** attempt))
        except (urllib.error.URLError, TimeoutError):
            time.sleep(2 * 2 ** attempt)
    raise RuntimeError(f"gave up on {url}")


def list_coins():
    """The LIMIT largest coins with market data, with each one's ticker and logo URL (none for CoinGecko's placeholder)."""
    coins, page = [], 1
    while len(coins) < LIMIT:
        query = urllib.parse.urlencode({"vs_currency": "usd", "order": "market_cap_desc", "per_page": 250, "page": page})
        rows = json.loads(get("https://api.coingecko.com/api/v3/coins/markets?" + query))
        if not rows:
            break
        coins += [{"id": r["id"], "symbol": r.get("symbol") or "", "image": r.get("image") or ""} for r in rows]
        print(f"page {page}: {len(coins)} coins", file=sys.stderr)
        page += 1
        time.sleep(2.5 if os.environ.get("COINGECKO_KEY") else 13)
    seen, kept = set(), []
    for coin in coins[:LIMIT]:
        if ID.fullmatch(coin["id"]) and coin["id"] not in seen:
            if not coin["image"].startswith("https://") or "missing" in coin["image"]:
                coin["image"] = ""
            seen.add(coin["id"]); kept.append(coin)
    WORK.mkdir(parents=True, exist_ok=True)
    COINS.write_text(json.dumps(kept, indent=0))
    print(f"{len(kept)} coins, {sum(1 for c in kept if c['image'])} with a logo", file=sys.stderr)


def fetch():
    CACHE.mkdir(parents=True, exist_ok=True)
    todo = [c for c in json.loads(COINS.read_text()) if c["image"] and not (CACHE / c["id"]).exists() and not (CACHE / (c["id"] + ".none")).exists()]
    print(f"{len(todo)} to fetch", file=sys.stderr)

    def one(coin):
        data = get(coin["image"])
        if data is None:
            (CACHE / (coin["id"] + ".none")).touch()
        else:
            (CACHE / coin["id"]).write_bytes(data)

    with concurrent.futures.ThreadPoolExecutor(12) as pool:
        for done, _ in enumerate(pool.map(one, todo), 1):
            if done % 500 == 0:
                print(f"{done}/{len(todo)}", file=sys.stderr)


def encode(raw):
    """A logo as the app draws it: square, SIZE pixels, WebP with its transparency. None if it isn't an image."""
    from PIL import Image
    try:
        image = Image.open(io.BytesIO(raw))
        image.load()
    except Exception:
        return None
    if image.width < 8 or image.height < 8:
        return None
    image = image.convert("RGBA")
    side = max(image.size)
    square = Image.new("RGBA", (side, side), (0, 0, 0, 0))
    square.paste(image, ((side - image.width) // 2, (side - image.height) // 2))
    out = io.BytesIO()
    square.resize((SIZE, SIZE), Image.LANCZOS).save(out, "WEBP", quality=QUALITY, method=6)
    return out.getvalue()


def encode_cached(ident):
    return ident, encode((CACHE / ident).read_bytes())


def pack():
    bundled = {p.name.removesuffix(".imageset") for p in BUNDLED.glob("*.imageset")}
    coins = json.loads(COINS.read_text())
    tickers = {c["id"]: c["symbol"].upper() for c in coins if TICKER.fullmatch(c.get("symbol", "").upper())}
    drawn = [c["id"] for c in coins if c["id"] not in bundled and (CACHE / c["id"]).exists()]
    with concurrent.futures.ProcessPoolExecutor() as pool:
        images = {ident: data for ident, data in pool.map(encode_cached, drawn, chunksize=64) if data}
    ids = sorted(set(images) | set(tickers), key=lambda i: i.encode())
    header = len(MAGIC) + 4 + len(ids) * struct.calcsize(ENTRY)
    text = b"".join(i.encode() + tickers.get(i, "").encode() for i in ids)
    index, text_at, image_at = [], header, header + len(text)
    for ident in ids:
        name, ticker, image = ident.encode(), tickers.get(ident, "").encode(), images.get(ident, b"")
        index.append(struct.pack(ENTRY, text_at, len(name), text_at + len(name), len(ticker), image_at if image else 0, len(image)))
        text_at += len(name) + len(ticker); image_at += len(image)
    PACK.write_bytes(MAGIC + struct.pack("<I", len(ids)) + b"".join(index) + text + b"".join(images.get(i, b"") for i in ids))
    print(f"{len(ids)} coins, {len(images)} logos, {len(tickers)} tickers, {PACK.stat().st_size / 1e6:.1f} MB -> {PACK.relative_to(ROOT)}", file=sys.stderr)


def review():
    from PIL import Image
    data = PACK.read_bytes()
    count, size = struct.unpack_from("<I", data, 8)[0], struct.calcsize(ENTRY)
    entries = [struct.unpack_from(ENTRY, data, 12 + size * n) for n in range(count)]
    entries = [e for e in entries if e[5]][:400]
    shown = len(entries)
    sheet = Image.new("RGBA", (20 * (SIZE + 8), (shown // 20 + 1) * (SIZE + 8)), (30, 30, 30, 255))
    for n, (_, _, _, _, at, length) in enumerate(entries):
        logo = Image.open(io.BytesIO(data[at:at + length])).convert("RGBA")
        sheet.alpha_composite(logo, ((n % 20) * (SIZE + 8) + 4, (n // 20) * (SIZE + 8) + 4))
    path = Path(tempfile.mkdtemp()) / "coin-logos.png"
    sheet.save(path)
    print(path)


if __name__ == "__main__":
    steps = {"list": list_coins, "fetch": fetch, "pack": pack, "review": review}
    if len(sys.argv) != 2 or sys.argv[1] not in steps:
        sys.exit(__doc__)
    steps[sys.argv[1]]()
