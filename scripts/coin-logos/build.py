#!/usr/bin/env python3
"""Builds the coin logos Up Only ships: one small image for each of the 10,000 largest coins CoinGecko lists.

  python3 -m pip install -r scripts/coin-logos/requirements.txt  # Pillow, pinned (Python 3.10+)
  python3 scripts/coin-logos/build.py list    # the LIMIT largest coins CoinGecko prices -> .context/coin-logos/coins.json
  python3 scripts/coin-logos/build.py fetch   # each coin's logo, cached in .context/coin-logos/images (reruns skip what's done)
  python3 scripts/coin-logos/build.py pack    # write UpOnly/Resources/CoinLogos.pack
  python3 scripts/coin-logos/build.py review  # contact sheet of the first 400, in a new temporary folder

The 250 largest coins keep their images in Assets.xcassets/CoinLogos; the pack holds every other coin's. The app
reads logos only from these, so it never fetches one (that would tell a server what you hold). An optional CoinGecko
demo key in COINGECKO_KEY lifts the listing's rate limit; nothing else needs one.

Pack format (little-endian), read by `CoinLogoPack` in the app:
  "UOLOGOS1"  magic, 8 bytes
  UInt32      count
  count x     (UInt32 id offset, UInt16 id length, UInt32 image offset, UInt32 image length), sorted by id bytes
  ...         the ids' bytes, then the images (WebP), offsets from the start of the file
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
MAGIC = b"UOLOGOS1"


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
    """Every coin with market data, largest first, with its logo's URL (none for CoinGecko's placeholder)."""
    coins, page = [], 1
    while len(coins) < LIMIT:
        query = urllib.parse.urlencode({"vs_currency": "usd", "order": "market_cap_desc", "per_page": 250, "page": page})
        rows = json.loads(get("https://api.coingecko.com/api/v3/coins/markets?" + query))
        if not rows:
            break
        coins += [{"id": r["id"], "image": r.get("image") or ""} for r in rows]
        print(f"page {page}: {len(coins)} coins", file=sys.stderr)
        page += 1
        time.sleep(2.5 if os.environ.get("COINGECKO_KEY") else 13)
    seen, kept = set(), []
    for coin in coins[:LIMIT]:
        if ID.fullmatch(coin["id"]) and coin["id"] not in seen and coin["image"].startswith("https://") and "missing" not in coin["image"]:
            seen.add(coin["id"]); kept.append(coin)
    WORK.mkdir(parents=True, exist_ok=True)
    COINS.write_text(json.dumps(kept, indent=0))
    print(f"{len(kept)} coins with a logo, of {len(coins)}", file=sys.stderr)


def fetch():
    CACHE.mkdir(parents=True, exist_ok=True)
    todo = [c for c in json.loads(COINS.read_text()) if not (CACHE / c["id"]).exists() and not (CACHE / (c["id"] + ".none")).exists()]
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
    coins = [c["id"] for c in json.loads(COINS.read_text()) if c["id"] not in bundled and (CACHE / c["id"]).exists()]

    with concurrent.futures.ProcessPoolExecutor() as pool:
        images = {ident: data for ident, data in pool.map(encode_cached, coins, chunksize=64) if data}
    ids = sorted(images, key=lambda i: i.encode())
    header = len(MAGIC) + 4 + len(ids) * 14
    names = b"".join(i.encode() for i in ids)
    index, name_at, image_at = [], header, header + len(names)
    for ident in ids:
        index.append(struct.pack("<IHII", name_at, len(ident.encode()), image_at, len(images[ident])))
        name_at += len(ident.encode()); image_at += len(images[ident])
    PACK.write_bytes(MAGIC + struct.pack("<I", len(ids)) + b"".join(index) + names + b"".join(images[i] for i in ids))
    print(f"{len(ids)} logos, {PACK.stat().st_size / 1e6:.1f} MB -> {PACK.relative_to(ROOT)}", file=sys.stderr)


def review():
    from PIL import Image
    data = PACK.read_bytes()
    count = struct.unpack_from("<I", data, 8)[0]
    shown = min(count, 400)
    sheet = Image.new("RGBA", (20 * (SIZE + 8), (shown // 20 + 1) * (SIZE + 8)), (30, 30, 30, 255))
    for n in range(shown):
        _, _, at, length = struct.unpack_from("<IHII", data, 12 + 14 * n)
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
