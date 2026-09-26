#!/usr/bin/env python3
"""Builds Up Only's bank catalog: names, aliases, countries and a logo for each bank.

  python3 -m pip install -r scripts/bank-catalog/requirements.txt  # Pillow, pinned to an exact version (Python 3.10+)
  python3 scripts/bank-catalog/build.py merge  # regional lists in .context/banks/*.json -> banks.json (optional;
                                               # banks.json is the curated list the app ships)
  python3 scripts/bank-catalog/build.py logos  # fetch each bank's App Store icon (favicon as a fallback), cached
  python3 scripts/bank-catalog/build.py assets # write BankLogos/*.imageset and the BankCatalog data asset
  python3 scripts/bank-catalog/build.py review # contact sheets of every logo, in a new temporary folder

Logos are the bank's own iOS app icon, whole, from Apple's public search API: a square tile with the mark inset,
the same look for every bank. A bank without a matching app falls back to its website icon, redrawn as a tile with
even padding. `logo-overrides.json` fixes any the matching gets wrong ({"id": "none"} or {"id": "<App Store id>"}).
Nothing here needs an API key, and the app itself never fetches logos.

Every id must match ID (it becomes a file name), and only https URLs on HOSTS are fetched, redirects included.
"""
import io, json, re, sys, tempfile, time, unicodedata, urllib.parse, urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
HERE = Path(__file__).resolve().parent
SOURCE = HERE / "banks.json"            # the curated list, committed
EXTRAS = HERE / "extras.json"           # hand-added entries (small fintechs the lists miss)
CACHE = ROOT / ".context" / "bank-logo-cache"
MANIFEST = HERE / "logo-sources.json"   # where each logo came from, so reruns skip what's done
ASSETS = ROOT / "UpOnly" / "Assets.xcassets"
LOGOS = ASSETS / "BankLogos"
CATALOG = ASSETS / "BankCatalog.dataset"
SIZE = 88                               # 44 pt at 2x, the largest badge
LIMIT = 1000
AGENT = "Mozilla/5.0 (Macintosh; Intel Mac OS X 14_0) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15"
ID = re.compile(r"[a-z0-9-]+")
# Apple's search API, its artwork CDN (which answers from is1 to is5) and Google's favicon service.
HOSTS = {"itunes.apple.com", "t3.gstatic.com",
         "is1-ssl.mzstatic.com", "is2-ssl.mzstatic.com", "is3-ssl.mzstatic.com", "is4-ssl.mzstatic.com", "is5-ssl.mzstatic.com"}
BUSINESS = re.compile(r"\b(business|empresas?|negocios|pj|corporate|commercial|merchant|biz|pro|sme|bizz|comercios|firmen|entreprises?|work)\b", re.I)


def slug(text):
    text = unicodedata.normalize("NFKD", text).encode("ascii", "ignore").decode()
    return re.sub(r"[^a-z0-9]+", "-", text.lower()).strip("-")


def words(text):
    text = unicodedata.normalize("NFKD", text).encode("ascii", "ignore").decode().lower()
    return [w for w in re.split(r"[^a-z0-9]+", text) if w]


def checked_id(ident):
    if not isinstance(ident, str) or not ID.fullmatch(ident):
        sys.exit(f"Refusing bank id {ident!r}: ids must match ^{ID.pattern}$")
    return ident


def load_banks():
    """banks.json, refusing any id that isn't a plain slug, since ids become file names."""
    banks = json.loads(SOURCE.read_text())
    for bank in banks:
        checked_id(bank.get("id"))
    return banks


def allowed(url):
    parts = urllib.parse.urlsplit(url)
    if parts.scheme != "https" or parts.hostname not in HOSTS:
        raise ValueError(f"refusing to fetch {url!r}: only https on {sorted(HOSTS)}")
    return url


class AllowedRedirects(urllib.request.HTTPRedirectHandler):
    """Follows a redirect only to another allowed https URL."""
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return super().redirect_request(req, fp, code, msg, headers, allowed(newurl))


OPENER = urllib.request.build_opener(AllowedRedirects)


def get(url, timeout=20):
    request = urllib.request.Request(allowed(url), headers={"User-Agent": AGENT})
    with OPENER.open(request, timeout=timeout) as response:
        return response.read()


# MARK: merge

def merge():
    entries = []
    for path in sorted((ROOT / ".context" / "banks").glob("*.json")):
        for item in json.loads(path.read_text()):
            item["region"] = path.stem
            entries.append(item)
    if EXTRAS.exists():
        entries += json.loads(EXTRAS.read_text())
    entries.sort(key=lambda e: -(e.get("customersMillions") or 0))
    seen_domains, seen_names, out = set(), set(), []
    for e in entries:
        domain = (e.get("domain") or "").lower().removeprefix("www.").strip("/")
        name = " ".join(words(e["name"]))
        # Same-named banks in different countries (GoTyme in South Africa and the Philippines) are both kept.
        place = (name, tuple(sorted(e.get("countries") or [])))
        if not name or (domain and domain in seen_domains) or place in seen_names:
            continue
        seen_domains.add(domain); seen_names.add(place)
        ident = slug(e["name"])
        while any(o["id"] == ident for o in out):
            ident += "-" + (e.get("countries") or ["x"])[0].lower()
        aliases = []
        for alias in e.get("aliases") or []:
            if alias and alias.lower() != e["name"].lower() and alias not in aliases:
                aliases.append(alias)
        out.append({"id": ident, "name": e["name"].strip(), "aliases": aliases[:8], "keep": bool(e.get("keep")),
                    "countries": [c.upper() for c in (e.get("countries") or [])], "domain": domain,
                    "kind": e.get("kind") or "bank", "customersMillions": e.get("customersMillions") or 0,
                    "estimated": bool(e.get("estimated")), "source": e.get("source")})
    # The biggest LIMIT, plus hand-added extras wherever they rank.
    ranked = [o for o in out if not o["keep"]][:LIMIT - sum(1 for o in out if o["keep"])]
    out = [o for o in out if o["keep"] or o in ranked]
    for o in out:
        del o["keep"]
        checked_id(o["id"])
    SOURCE.write_text(json.dumps(out, ensure_ascii=False, indent=1) + "\n")
    print(f"{len(out)} banks -> {SOURCE.relative_to(ROOT)}")


# MARK: logos

def store_country(bank):
    """The App Store to search: the US or UK one when the bank is there (its main app), else its first country's."""
    countries = [c for c in bank["countries"] if re.fullmatch(r"[A-Z]{2}", c)]
    for preferred in ("US", "GB"):
        if preferred in countries:
            return preferred.lower()
    return countries[0].lower() if countries else "us"


OVERRIDES = HERE / "logo-overrides.json"


def app_icon(bank):
    """The bank's iOS app icon: the best-scoring match from the App Store in its home country, then the US."""
    override = (json.loads(OVERRIDES.read_text()) if OVERRIDES.exists() else {}).get(bank["id"])
    if override == "none":
        return None
    if override:
        if not re.fullmatch(r"[0-9]+", str(override)):
            sys.exit(f"Refusing override {override!r} for {bank['id']}: use \"none\" or a numeric App Store id")
        # Some apps aren't in the US store (Binance); look in the UK's and the bank's own too.
        lookup = lambda country: "https://itunes.apple.com/lookup?" + urllib.parse.urlencode({"id": override, "country": country})
        app = next(found for country in ("us", "gb", store_country(bank))
                   for found in json.loads(get(lookup(country)))["results"][:1])
        return {"kind": "appstore", "trackId": app["trackId"], "trackName": app["trackName"], "seller": app.get("sellerName"),
                "score": 99, "url": re.sub(r"/\d+x\d+bb\.(jpg|png)$", "/1024x1024wa.png", app["artworkUrl512"])}
    names = [bank["name"]] + bank["aliases"][:2]
    name_words = [set(words(n)) for n in names if words(n)]
    best, best_score = None, 0
    for country in dict.fromkeys([store_country(bank), "us"]):
        query = urllib.parse.urlencode({"term": bank["name"], "entity": "software", "country": country, "limit": 8})
        try:
            results = json.loads(get("https://itunes.apple.com/search?" + query)).get("results", [])
        except Exception as error:
            print("  search failed", bank["id"], country, error)
            time.sleep(10)
            continue
        finally:
            time.sleep(3.2)   # Apple's search allows about 20 requests a minute
        for rank, app in enumerate(results):
            score = 0
            seller_url = (app.get("sellerUrl") or "").lower()
            host = urllib.parse.urlparse(seller_url).hostname or ""
            if bank["domain"] and (host == bank["domain"] or host.endswith("." + bank["domain"])):
                score += 5
            elif bank["domain"] and bank["domain"].split(".")[0] in host:
                score += 3
            seller = set(words(app.get("sellerName", "")))
            track = set(words(app.get("trackName", "")))
            if any(n and n <= seller for n in name_words):
                score += 3
            if any(n and n <= track for n in name_words):
                score += 2
            if app.get("primaryGenreName") == "Finance":
                score += 1
            if BUSINESS.search(app.get("trackName", "")):
                score -= 3
            score += 1 if rank == 0 else 0
            if score > best_score:
                best, best_score = app, score
        if best_score >= 5:
            break
    if best is None or best_score < 5:
        return None
    # The whole icon, uncropped, drawn on a page ("wa"): its tile sits at a fixed place, cut out in `assets`.
    url = re.sub(r"/\d+x\d+bb\.(jpg|png)$", "/1024x1024wa.png", best["artworkUrl512"])
    return {"kind": "appstore", "trackId": best["trackId"], "trackName": best["trackName"], "seller": best.get("sellerName"),
            "score": best_score, "url": url}


def favicon(bank):
    if not bank["domain"]:
        return None
    url = ("https://t3.gstatic.com/faviconV2?client=SOCIAL&type=FAVICON&fallback_opts=TYPE,SIZE,URL&url=https://"
           + bank["domain"] + "&size=256")
    return {"kind": "favicon", "url": url}


def logos():
    from PIL import Image
    CACHE.mkdir(parents=True, exist_ok=True)
    banks = load_banks()
    manifest = json.loads(MANIFEST.read_text()) if MANIFEST.exists() else {}
    for index, bank in enumerate(banks):
        if bank["id"] in manifest and (CACHE / (bank["id"] + ".png")).exists():
            continue
        found = None
        for source in (app_icon, favicon):
            info = source(bank)
            if not info:
                continue
            try:
                data = get(info["url"])
                image = Image.open(io.BytesIO(data))
                # A website icon under 96 px would be a blur at badge size; better the generic bank badge.
                if info["kind"] == "favicon" and min(image.size) < 96:
                    continue
                (CACHE / (bank["id"] + ".png")).write_bytes(data)
                found = info
                break
            except Exception as error:
                print("  download failed", bank["id"], info["kind"], error)
        manifest[bank["id"]] = found or {"kind": "none"}
        print(f"{index + 1}/{len(banks)} {bank['name']}: {(found or {}).get('kind', 'none')} {(found or {}).get('trackName', '')}")
        if index % 10 == 0:
            MANIFEST.write_text(json.dumps(manifest, ensure_ascii=False, indent=1) + "\n")
    MANIFEST.write_text(json.dumps(manifest, ensure_ascii=False, indent=1) + "\n")


# MARK: assets

def median(pixels):
    return tuple(sorted(p[i] for p in pixels)[len(pixels) // 2] for i in range(3)) + (255,)


def pad(mark, background):
    """The mark centred on a square of `background`, filling 64% of it: the padding every logo gets."""
    from PIL import Image
    canvas = Image.new("RGBA", (512, 512), background)
    inner = int(512 * 0.64)
    scale = min(inner / mark.width, inner / mark.height)
    mark = mark.resize((max(1, round(mark.width * scale)), max(1, round(mark.height * scale))), Image.LANCZOS)
    canvas.alpha_composite(mark, ((512 - mark.width) // 2, (512 - mark.height) // 2))
    return canvas


def tile(image):
    """A square tile with the mark inset, as an app icon is, so every bank reads the same in its rounded badge.
    - An app icon drawn with its own rounded corners (transparent outside) is cropped to its shape and its corners
      filled with its own edge colour.
    - A mark on transparency is centred on white (a dark tile for a light mark) with even padding.
    - A mark on a solid background that runs to the edges (Monzo's, Chase's website icons) is redrawn centred on
      that background with the same padding.
    - Anything else (full-bleed artwork, stripes) is kept as drawn."""
    from PIL import Image, ImageChops
    image = image.convert("RGBA")
    w, h = image.size
    side = min(w, h)
    image = image.crop(((w - side) // 2, (h - side) // 2, (w + side) // 2, (h + side) // 2))
    alpha = image.getchannel("A")
    if alpha.getextrema()[0] < 200:
        box = alpha.point(lambda v: 255 if v > 40 else 0).getbbox()
        if not box:
            return image
        shape = image.crop(box)
        opaque = sum(1 for v in shape.getchannel("A").getdata() if v > 200) / (shape.width * shape.height)
        if opaque > 0.85 and 0.8 < shape.width / shape.height < 1.25:
            # An icon with its own rounded corners: fill them with the colour just inside its edges.
            sw, sh = shape.size
            edge = median([shape.getpixel(p) for p in [(sw // 2, 2), (2, sh // 2), (sw - 3, sh // 2), (sw // 2, sh - 3)]])
            filled = Image.new("RGBA", shape.size, edge)
            filled.alpha_composite(shape)
            return filled.resize((512, 512), Image.LANCZOS)
        pixels = [p for p in shape.getdata() if p[3] > 128]
        light = pixels and sum(0.299 * p[0] + 0.587 * p[1] + 0.114 * p[2] for p in pixels) / len(pixels) > 200
        return pad(shape, (28, 28, 30, 255) if light else (255, 255, 255, 255))
    border = [image.getpixel((x, y)) for x in range(side) for y in (0, side - 1)] + [image.getpixel((x, y)) for y in range(side) for x in (0, side - 1)]
    background = median(border)
    close = sum(1 for p in border if abs(p[0] - background[0]) + abs(p[1] - background[1]) + abs(p[2] - background[2]) < 40)
    if close < 0.4 * len(border):
        return image
    difference = ImageChops.difference(image.convert("RGB"), Image.new("RGB", image.size, background[:3])).convert("L")
    box = difference.point(lambda v: 255 if v > 40 else 0).getbbox()
    if not box:
        return image
    margin = min(box[0], box[1], side - box[2], side - box[3]) / side
    if margin >= 0.12:
        return image
    return pad(image.crop(box), background)


def assets():
    from PIL import Image
    banks = load_banks()
    manifest = json.loads(MANIFEST.read_text()) if MANIFEST.exists() else {}
    LOGOS.mkdir(parents=True, exist_ok=True)
    for old in LOGOS.glob("*.imageset"):
        for f in old.iterdir():
            f.unlink()
        old.rmdir()
    (LOGOS / "Contents.json").write_text(json.dumps({"info": {"author": "xcode", "version": 1}, "properties": {"provides-namespace": True}}, indent=2) + "\n")
    catalog = []
    for bank in banks:
        logo = False
        image = processed(bank, manifest)
        if image is not None:
            folder = LOGOS / (bank["id"] + ".imageset")
            folder.mkdir()
            image.quantize(colors=128, method=Image.Quantize.MEDIANCUT, dither=Image.Dither.NONE).save(folder / (bank["id"] + ".png"), optimize=True)
            (folder / "Contents.json").write_text(json.dumps({"images": [{"filename": bank["id"] + ".png", "idiom": "universal"}],
                                                              "info": {"author": "xcode", "version": 1}}, indent=2) + "\n")
            logo = True
        catalog.append({"id": bank["id"], "name": bank["name"], "aliases": bank["aliases"], "countries": bank["countries"],
                        "kind": bank["kind"], "logo": logo})
    CATALOG.mkdir(parents=True, exist_ok=True)
    (CATALOG / "banks.json").write_text(json.dumps(catalog, ensure_ascii=False, separators=(",", ":")))
    (CATALOG / "Contents.json").write_text(json.dumps({"data": [{"filename": "banks.json", "idiom": "universal", "universal-type-identifier": "public.json"}],
                                                       "info": {"author": "xcode", "version": 1}}, indent=2) + "\n")
    print(f"{len(catalog)} banks, {sum(1 for c in catalog if c['logo'])} with logos")


def processed(bank, manifest):
    """A bank's logo as it will ship, or None."""
    from PIL import Image
    cached = CACHE / (bank["id"] + ".png")
    kind = manifest.get(bank["id"], {}).get("kind")
    if kind not in ("appstore", "favicon") or not cached.exists():
        return None
    source = Image.open(cached)
    source = source.convert("RGB").crop((334, 334, 690, 690)) if kind == "appstore" else tile(source)
    return source.convert("RGB").resize((SIZE, SIZE), Image.LANCZOS)


def review():
    """Contact sheets of every logo as it will look in its rounded badge, with names, for checking by eye."""
    from PIL import Image, ImageDraw
    banks = load_banks()
    manifest = json.loads(MANIFEST.read_text()) if MANIFEST.exists() else {}
    done = [b for b in banks if b["id"] in manifest]
    columns, rows, cell = 10, 6, 124
    mask = Image.new("L", (SIZE, SIZE), 0); ImageDraw.Draw(mask).rounded_rectangle((0, 0, SIZE - 1, SIZE - 1), radius=int(SIZE * 0.28), fill=255)
    out = Path(tempfile.mkdtemp(prefix="bank-review-"))
    for page in range(0, len(done), columns * rows):
        sheet = Image.new("RGB", (columns * cell, rows * cell), (36, 36, 38))
        draw = ImageDraw.Draw(sheet)
        for i, bank in enumerate(done[page:page + columns * rows]):
            x, y = (i % columns) * cell, (i // columns) * cell
            image = processed(bank, manifest)
            if image: sheet.paste(image, (x + (cell - SIZE) // 2, y + 6), mask)
            else: draw.rectangle((x + 18, y + 6, x + 18 + SIZE, y + 6 + SIZE), outline=(90, 90, 90))
            draw.text((x + 4, y + SIZE + 10), f"{page + i} {bank['name']}"[:22], fill=(220, 220, 220))
        sheet.save(out / f"sheet-{page // (columns * rows):02d}.png")
    print(f"{len(done)} logos in {out}")


if __name__ == "__main__":
    {"merge": merge, "logos": logos, "assets": assets, "review": review}[sys.argv[1]]()
