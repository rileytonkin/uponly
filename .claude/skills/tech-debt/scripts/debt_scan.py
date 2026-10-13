#!/usr/bin/env python3
"""Mechanical technical-debt signals for ONE change set (a branch or PR).

debt-scan: ignore-file (this file defines the rules, so it matches them)

Part of the portable `tech-debt` skill. Standard library only, Python 3.8+,
so it runs unchanged on macOS system python, Linux sandboxes and CI.

It reads the diff between the merge base and the head (or the working tree),
and reports cheap, high-precision signals in eight categories: code, design,
test, docs, dependency, infra, security, knowledge. It never judges; the
skill's single reviewer does that with this output as its evidence.

Design rules (each one cost somebody a bad report somewhere):
- Absence must not read as success: every run prints what it MEASURED
  (files, lines). An empty diff exits 3, a git failure exits 2.
- Generated, vendored and lock files are skipped for code signals, using the
  repo's own .gitattributes (linguist-generated / linguist-vendored) first.
- Secrets are never echoed; their evidence is redacted.
- Interest = how often the touched file changed in the last 90 days.

Usage:
  debt_scan.py [--base REF] [--head REF | --committed] [--json PATH] [--register DIR]

Exit: 0 scanned (signals or not), 2 cannot scan, 3 empty change set.
Any non-zero exit means "no analysis", never "no debt".
"""

import argparse
import codecs
import fnmatch
import json
import os
import re
import stat
import subprocess
import sys
import tempfile
from collections import defaultdict

VERSION = "1.0.0"

CODE_EXT = {
    "swift", "kt", "kts", "java", "js", "jsx", "ts", "tsx", "mjs", "cjs", "py",
    "rb", "go", "rs", "sh", "bash", "zsh", "sql", "c", "h", "cc", "cpp", "hpp",
    "m", "mm", "cs", "php", "dart", "vue", "svelte", "lua", "scala", "ex", "exs",
    "html", "css", "scss",
}
STYLE_EXT = {"css", "scss"}
OPT_OUT = "debt-scan: ignore-file"  # in a file's first 30 lines; reported when added
DOC_EXT = {"md", "mdx", "rst", "adoc"}
LOCK_NAMES = {
    "package-lock.json", "npm-shrinkwrap.json", "yarn.lock", "pnpm-lock.yaml",
    "bun.lockb", "bun.lock", "Package.resolved", "Podfile.lock", "Gemfile.lock",
    "Cargo.lock", "go.sum", "poetry.lock", "uv.lock", "Pipfile.lock",
    "composer.lock", "gradle.lockfile", "deno.lock", "flake.lock",
}
GENERATED_GLOBS = [
    "*/node_modules/*", "node_modules/*", "*/vendor/*", "vendor/*", "*/dist/*",
    "dist/*", "*/build/*", "build/*", "*/Pods/*", "Pods/*", "*.min.js",
    "*.min.css", "*.pbxproj", "*.xcstrings", "*.strings", "*/values*/strings.xml",
    "*.snap", "*/__snapshots__/*", "*.generated.*", "*/__generated__/*",
    "*.g.dart", "*.pb.go", "*_pb2.py", "*.map",
]
CI_GLOBS = [
    ".github/workflows/*", ".gitlab-ci.yml", "Jenkinsfile", ".circleci/*",
    "bitrise.yml", "*Dockerfile*", "docker-compose*", "*.tf", "vercel.json",
    "fly.toml", "netlify.toml", "codemagic.yaml",
]
# Agent guidance (rules, skills, CLAUDE.md) is read as instruction for months:
# contradictions and stale lines there are debt, so a big change gets the judge.
GUIDANCE_PATTERNS = [
    re.compile(r"^(CLAUDE|AGENTS|GEMINI)\.md$"),
    re.compile(r"(^|/)\.(claude|agents|codex|cursor|grok)/"),
    re.compile(r"(^|/)SKILL\.md$"),
    re.compile(r"^\.github/copilot-instructions\.md$"),
]
TEST_PATTERNS = [
    re.compile(r"(^|/)(tests?|__tests__|spec|specs|androidTest|testDebug|e2e)/"),
    re.compile(r"(^|/)[^/]*Tests?/"),
    re.compile(r"(^|/)test_[^/]*\.py$"),
    re.compile(r"_test\.(py|go|sh|rb|dart)$"),
    re.compile(r"\.(test|spec)\.[A-Za-z0-9]+$"),
    re.compile(r"(Test|Tests|Spec)\.(swift|kt|java|m)$"),
]

# --- per-line rules: (kind, category, regex, extensions or None, note) -------
HASH_COMMENT_EXT = {"py", "rb", "sh", "bash", "zsh", "yml", "yaml", "toml", "r", "pl", "ex", "exs", "tf", "nix", "cmake", "mk", "dockerfile", "txt", "cfg", "ini", "conf"}
DASH_COMMENT_EXT = {"sql", "lua"}
_OPENERS = {
    "slash": re.compile(r"(//|/\*|^\s*\*)"),
    "hash": re.compile(r"(^|\s)#"),
    "dash": re.compile(r"(^|\s)--(\s|$)|/\*"),
    "markup": re.compile(r"<!--|/\*|^\s*\*|(^|\s)//"),
}


def comment_style(path):
    e = ext_of(path)
    base = os.path.basename(path)
    if e in HASH_COMMENT_EXT or base in ("Dockerfile", "Makefile", "Gemfile", "Podfile", "Jenkinsfile") or is_ci(path):
        return "hash"
    if e in DASH_COMMENT_EXT:
        return "dash"
    if e in ("html", "css", "scss", "vue", "svelte", "md"):
        return "markup"
    return "slash"


def strip_strings(text):
    """Blank out string literal contents, so `"https://x"` is not a comment and `"Saved!!"` is not code."""
    out, quote, i = [], None, 0
    while i < len(text):
        ch = text[i]
        if quote:
            if ch == "\\":
                out.append("  ")
                i += 2
                continue
            if ch == quote:
                quote = None
                out.append(ch)
            else:
                out.append(" ")
        else:
            if ch in "\"'`":
                quote = ch
            out.append(ch)
        i += 1
    return "".join(out)[: len(text)]


def in_comment(path, text, pos):
    return bool(_OPENERS[comment_style(path)].search(strip_strings(text[:pos])))
SATD_HARD = re.compile(r"\b(TODO|FIXME|HACK|XXX|KLUDGE)\b")
SATD_SOFT = re.compile(
    r"\b(workaround|for now|quick fix|hacky|band-?aid|temporary (fix|hack|workaround|code)"
    r"|remove (this|me|once|when|after)|copied from|not sure why|no idea why)\b",
    re.I,
)

LINE_RULES = [
    # code: suppressed checks
    ("suppression", "code", re.compile(r"eslint-disable|@ts-ignore|@ts-nocheck|@ts-expect-error"), {"js", "jsx", "ts", "tsx", "mjs", "cjs", "vue", "svelte", "html"}, "lint/type check suppressed"),
    ("suppression", "code", re.compile(r"\bas any\b"), {"ts", "tsx"}, "type escape hatch"),
    ("suppression", "code", re.compile(r"#\s*(noqa|type:\s*ignore|pylint:\s*disable|pragma:\s*no cover)"), {"py"}, "lint/type check suppressed"),
    ("suppression", "code", re.compile(r"swiftlint:disable|swift-format-ignore"), {"swift"}, "lint suppressed"),
    ("suppression", "code", re.compile(r"\btry!|\bas!\s"), {"swift"}, "force unwrap/cast can crash"),
    ("suppression", "code", re.compile(r"@Suppress(Lint)?\(|@SuppressWarnings\("), {"kt", "kts", "java"}, "warning suppressed"),
    ("suppression", "code", re.compile(r"[\w)\]]!!(?!=)"), {"kt", "kts"}, "non-null assertion can crash"),
    ("suppression", "code", re.compile(r"shellcheck disable"), {"sh", "bash", "zsh"}, "shellcheck suppressed"),
    ("suppression", "code", re.compile(r"//\s*nolint|#\[allow\("), {"go", "rs"}, "lint suppressed"),
    ("bypass", "code", re.compile(r"\|\|\s*true\b"), {"swift", "kt", "kts", "java", "js", "jsx", "ts", "tsx", "mjs", "cjs"}, "condition forced true (debug bypass?)"),
    # code: dead code
    ("dead-branch", "code", re.compile(r"^\s*(#\s*if\s+(0|false)\b|if\s*\(?\s*(false|0)\s*\)?\s*[{:]|if\s+False\s*:)"), None, "branch that can never run"),
    # test
    ("test-disabled", "test", re.compile(r"\b(it|test|describe)\.(skip|only)\(|\bx(it|describe)\(|@Disabled\b|@Ignore\b|XCTSkip|pytest\.mark\.skip|@unittest\.skip|t\.Skip\(|#\[ignore\]"), None, "test skipped or focused"),
    # design
    ("deprecation", "design", re.compile(r"@available\([^)]*deprecated|@Deprecated\b|@deprecated\b|DeprecationWarning"), None, "deprecation added: needs a removal plan"),
    ("feature-flag", "design", re.compile(r"isFeatureEnabled\(|getFeatureFlag\(|useFeatureFlag\(|featureFlag\(|feature_flag\(|[\"']kill-[a-z0-9-]+[\"']"), None, "flag added: needs a removal plan"),
    # infra
    ("ci-weakened", "infra", re.compile(r"continue-on-error:\s*true|^\s*if:\s*(false|\$\{\{\s*false\s*\}\})\s*$"), None, "CI step allowed to fail or disabled"),
    ("unpinned", "infra", re.compile(r"uses:\s*[\w.-]+/[\w./-]+@(main|master|HEAD|latest)\s*$|uses:\s*[\w.-]+/[\w.-]+\s*$"), None, "action pinned to a moving branch"),
    ("unpinned", "infra", re.compile(r"^\s*FROM\s+(?!scratch\b|\$)[^\s:@]+(:latest)?(\s+AS\s+\w+)?\s*$", re.I), None, "image pinned to latest"),
    ("hook-bypass", "infra", re.compile(r"--no-verify\b"), None, "git hooks bypassed"),
    # security
    ("tls-off", "security", re.compile(r"verify\s*=\s*False|rejectUnauthorized\s*:\s*false|NODE_TLS_REJECT_UNAUTHORIZED\s*=\s*['\"]?0|InsecureSkipVerify:\s*true|StrictHostKeyChecking=no|NSAllowsArbitraryLoads|usesCleartextTraffic=\"true\""), None, "transport security disabled"),
    ("tls-off", "security", re.compile(r"\bcurl\b[^|]*\s(-k|--insecure)\b"), None, "transport security disabled"),
    ("unsafe-exec", "security", re.compile(r"(?<![.\w$])eval\(|new Function\("), {"js", "jsx", "ts", "tsx", "mjs", "cjs", "html", "vue", "svelte"}, "dynamic code execution"),
    ("unsafe-exec", "security", re.compile(r"(?<![.\w])(eval|exec)\(|shell\s*=\s*True"), {"py"}, "dynamic code / shell execution"),
    ("xss-sink", "security", re.compile(r"dangerouslySetInnerHTML|\.innerHTML\s*[+]?=\s*[^;]*(\$\{|\+\s*\w)"), None, "HTML built from data"),
    ("perm", "security", re.compile(r"chmod\s+(-R\s+)?0?777\b|android:debuggable=\"true\""), None, "over-broad permission"),
]
SECRET_RULES = [
    re.compile(r"-----BEGIN (RSA |EC |OPENSSH |DSA |PGP )?PRIVATE KEY-----"),
    re.compile(r"\bAKIA[0-9A-Z]{16}\b"),
    re.compile(r"\b(sk|rk)_(live|test)_[0-9A-Za-z]{16,}"),
    re.compile(r"\bsk-(proj-)?[A-Za-z0-9_-]{32,}"),
    re.compile(r"\bsb_secret_[A-Za-z0-9_-]{16,}"),
    re.compile(r"\bsbp_[A-Za-z0-9]{40,}"),
    re.compile(r"\bre_[A-Za-z0-9]{8}_[A-Za-z0-9]{20,}"),
    re.compile(r"\bwhsec_[A-Za-z0-9+/=]{20,}"),
    re.compile(r"\bAIza[0-9A-Za-z_-]{35}"),
    re.compile(r"\beyJ[A-Za-z0-9_-]{10,}\.eyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}"),
    re.compile(r"\bghp_[0-9A-Za-z]{30,}|\bgithub_pat_[0-9A-Za-z_]{30,}"),
    re.compile(r"\bxox[abprs]-[0-9A-Za-z-]{10,}"),
    re.compile(r"\bsk-ant-[A-Za-z0-9_-]{20,}"),
]
VERSIONED_DECL = re.compile(
    r"\b(class|struct|enum|protocol|interface|func|fun|def|function|const|let|var|val|object|type|table|view)\s+"
    r"(?:if\s+not\s+exists\s+)?[`\"]?(?:public\.)?([A-Za-z_][A-Za-z0-9_]*)",
    re.I,
)
TYPE_KEYWORDS = {"class", "struct", "enum", "protocol", "interface", "object", "type", "table", "view"}
VERSIONED_ANY = re.compile(r"^(Legacy|Deprecated|Old)[A-Z_]|[a-z0-9](V[2-9]\d*|_v[2-9]\d*)$")
VERSIONED_TYPE = re.compile(r"[a-z0-9](Legacy|Old|Copy|Backup|Temp|Tmp)$")  # only on types: maxTemp is fine
VERSION_PART = re.compile(r"(V[2-9]\d*|_v[2-9]\d*|Legacy|Old|Copy|Backup|Temp|Tmp)$|^(Legacy|Deprecated|Old)")
ENV_RULES = [
    re.compile(r"process\.env\.([A-Z][A-Z0-9_]{2,})"),
    re.compile(r"process\.env\[['\"]([A-Z][A-Z0-9_]{2,})['\"]\]"),
    re.compile(r"Deno\.env\.get\(\s*['\"]([A-Z][A-Z0-9_]{2,})['\"]"),
    re.compile(r"os\.environ(?:\.get)?\s*[\[(]\s*['\"]([A-Z][A-Z0-9_]{2,})['\"]"),
    re.compile(r"os\.getenv\(\s*['\"]([A-Z][A-Z0-9_]{2,})['\"]"),
    re.compile(r"System\.getenv\(\s*\"([A-Z][A-Z0-9_]{2,})\""),
    re.compile(r"environment\[\s*\"([A-Z][A-Z0-9_]{2,})\"\s*\]"),
    re.compile(r"\bENV\[\s*['\"]([A-Z][A-Z0-9_]{2,})['\"]\s*\]"),
]
TEST_DECL = re.compile(r"^\s*(func test\w*\(|@Test\b|def test_\w+|(it|test)\(\s*['\"`]|fun `|async def test_\w+)")
TEST_SLEEP = re.compile(r"\b(sleep\(|Thread\.sleep\(|usleep\(|time\.sleep\(|Task\.sleep\()|setTimeout\(")
MD_LINK = re.compile(r"\]\(\s*<?([^)\s>]+)>?(?:\s+\"[^\"]*\")?\s*\)")
CODE_LIKE = re.compile(r"([;{}]\s*$|^\s*(let|var|val|const|func|fun|def|return|if|for|while|import|class|struct|await|self\.|this\.)\b|\w\(.*\)\s*;?\s*$)")
SQL_CREATE_TABLE = re.compile(r"\bcreate\s+table\s+(?:if\s+not\s+exists\s+)?(?:public\.)?\"?([A-Za-z_][A-Za-z0-9_]*)\"?", re.I)
SQL_SECDEF = re.compile(r"\bsecurity\s+definer\b", re.I)
SQL_FUNC_START = re.compile(r"\bcreate\s+(or\s+replace\s+)?(function|procedure)\b", re.I)
SQL_STMT_START = re.compile(r"^\s*(create|alter|grant|revoke|drop|comment\s+on|insert|update|delete|select\s+cron)\b", re.I)

DEP_LINE = {
    "requirements": re.compile(r"^\s*([A-Za-z0-9_.\-\[\]]+)\s*([=<>!~].*)?$"),
    "Package.swift": re.compile(r"\.package\(\s*(url|name|path):"),
    "gradle": re.compile(r"^\s*(implementation|api|kapt|ksp|testImplementation|androidTestImplementation|debugImplementation|compileOnly|runtimeOnly)\b"),
    "libs.versions.toml": re.compile(r"^\s*[A-Za-z0-9_.-]+\s*=\s*[{\"]"),
    "Podfile": re.compile(r"^\s*pod\s+['\"]"),
    "Gemfile": re.compile(r"^\s*gem\s+['\"]"),
    "go.mod": re.compile(r"^\s*(require\s+)?[a-z0-9.-]+\.[a-z]{2,}/\S+\s+v\d"),
    "Cargo.toml": re.compile(r"^\s*[A-Za-z0-9_-]+\s*=\s*[{\"]"),
    "pyproject.toml": re.compile(r"^\s*\"[A-Za-z0-9_.\-\[\]]+\s*([=<>!~][^\"]*)?\",?\s*$"),
}
LOCK_FOR = {
    "package.json": ["package-lock.json", "npm-shrinkwrap.json", "yarn.lock", "pnpm-lock.yaml", "bun.lockb", "bun.lock"],
    "Package.swift": ["Package.resolved"],
    "Podfile": ["Podfile.lock"],
    "Gemfile": ["Gemfile.lock"],
    "Cargo.toml": ["Cargo.lock"],
    "go.mod": ["go.sum"],
    "pyproject.toml": ["uv.lock", "poetry.lock"],
    "deno.json": ["deno.lock"],
}


class ScanError(Exception):
    pass


# Personal settings must not change what the scan reads: paths keep a/ and b/,
# and diffs are never relative to a subdirectory.
GIT_CONFIG = ["-c", "core.quotepath=false", "-c", "diff.noprefix=false", "-c", "diff.mnemonicPrefix=false",
              "-c", "diff.relative=false"]


def git(args, check=True, cwd=None, input_text=None):
    """Run git; decode output ourselves so a lone carriage return never splits a line."""
    proc = subprocess.run(
        ["git"] + GIT_CONFIG + args, cwd=cwd,
        input=None if input_text is None else input_text.encode("utf-8"),
        stdout=subprocess.PIPE, stderr=subprocess.PIPE,
    )
    if check and proc.returncode != 0:
        raise ScanError("git %s failed: %s" % (" ".join(args[:3]), proc.stderr.decode("utf-8", "replace").strip()[:300]))
    return proc.stdout.decode("utf-8", "replace")


def ext_of(path):
    base = os.path.basename(path)
    return base.rsplit(".", 1)[1].lower() if "." in base else ""


def is_test(path):
    return any(p.search(path) for p in TEST_PATTERNS)


def is_ci(path):
    return any(fnmatch.fnmatch(path, g) for g in CI_GLOBS)


def is_guidance(path):
    return ext_of(path) in ("md", "mdc", "mdx") and any(p.search(path) for p in GUIDANCE_PATTERNS)


def is_doc(path):
    return ext_of(path) in DOC_EXT


def redact(text):
    for rule in SECRET_RULES:
        text = rule.sub("<redacted>", text)
    return text


def clip(text, n=120):
    text = redact(text.strip())
    return text if len(text) <= n else text[: n - 1] + "…"


class FileChange:
    def __init__(self, path):
        self.path = path
        self.old_path = None
        self.status = "M"  # A added, D deleted, M modified, R renamed
        self.binary = False
        self.header_old = None
        self.added = []    # (new_lineno, text)
        self.removed = []  # (old_lineno, text)


def unquote(p):
    """Undo git's C-style path quoting (octal UTF-8 bytes, \\" and friends)."""
    if len(p) >= 2 and p[0] == '"' and p[-1] == '"':
        try:
            return codecs.escape_decode(p[1:-1].encode("utf-8"))[0].decode("utf-8", "replace")
        except (UnicodeError, ValueError):
            return p[1:-1]
    return p


def header_paths(rest):
    """Paths from a `diff --git a/X b/Y` header, which binary and mode-only changes rely on."""
    if rest.startswith('"'):
        m = re.match(r'^("(?:[^"\\]|\\.)*")\s+("(?:[^"\\]|\\.)*"|\S.*)$', rest)
        if m:
            a, b = unquote(m.group(1)), unquote(m.group(2))
            return a[2:] if a.startswith("a/") else a, b[2:] if b.startswith("b/") else b
        return None, None
    if rest.endswith('"'):
        i = rest.rfind(' "')
        a, b = rest[:i], unquote(rest[i + 1:])
        return a[2:] if a.startswith("a/") else a, b[2:] if b.startswith("b/") else b
    n = (len(rest) - 5) // 2  # "a/" + P + " b/" + P when the path did not change
    if rest.startswith("a/") and rest[2 + n:5 + n] == " b/" and rest[2:2 + n] == rest[5 + n:]:
        return rest[2:2 + n], rest[5 + n:]
    return None, None


def parse_diff(text):
    files = []
    cur = None
    old_left = new_left = 0
    old_no = new_no = 0
    in_hunk = False
    hunk_re = re.compile(r"^@@ -(\d+)(?:,(\d+))? \+(\d+)(?:,(\d+))? @@")
    for line in text.split("\n"):
        if in_hunk and (old_left > 0 or new_left > 0):
            if line.startswith("+"):
                cur.added.append((new_no, line[1:]))
                new_no += 1
                new_left -= 1
                continue
            if line.startswith("-"):
                cur.removed.append((old_no, line[1:]))
                old_no += 1
                old_left -= 1
                continue
            if line.startswith(" "):
                old_no += 1
                new_no += 1
                old_left -= 1
                new_left -= 1
                continue
            if line.startswith("\\"):
                continue
            in_hunk = False
        if line.startswith("\\"):
            continue
        if line.startswith("diff --git "):
            a, b = header_paths(line[len("diff --git "):])
            cur = FileChange(b or "")
            cur.old_path = None
            cur.header_old = a
            files.append(cur)
            in_hunk = False
            continue
        if cur is None:
            continue
        if line.startswith("new file mode"):
            cur.status = "A"
        elif line.startswith("deleted file mode"):
            cur.status = "D"
        elif line.startswith("rename from "):
            cur.old_path = unquote(line[len("rename from "):])
            cur.status = "R"
        elif line.startswith("rename to "):
            cur.path = unquote(line[len("rename to "):])
        elif line.startswith("Binary files ") or line.startswith("GIT binary patch"):
            cur.binary = True
        elif line.startswith("--- "):
            p = unquote(line[4:].rstrip("\t"))
            if p != "/dev/null":
                p = p[2:] if p.startswith("a/") else p
                cur.old_path = cur.old_path or p
        elif line.startswith("+++ "):
            p = unquote(line[4:].rstrip("\t"))
            if p != "/dev/null":
                cur.path = p[2:] if p.startswith("b/") else p
        else:
            m = hunk_re.match(line)
            if m:
                old_no = int(m.group(1))
                old_left = int(m.group(2)) if m.group(2) is not None else 1
                new_no = int(m.group(3))
                new_left = int(m.group(4)) if m.group(4) is not None else 1
                in_hunk = True
    for f in files:
        f.old_path = f.old_path or f.header_old
        if not f.path:
            f.path = f.old_path or ""
        if f.status == "D":
            f.path = f.old_path or f.path
    return [f for f in files if f.path]


class Repo:
    def __init__(self, root, base, committed, head="HEAD"):
        self.root = root
        self.base = base
        self.committed = committed
        self.head = head
        self._cache = {}

    def read_head(self, path):
        key = ("head", path)
        if key not in self._cache:
            if self.committed:
                proc = subprocess.run(["git", "cat-file", "blob", self.head + ":" + path], cwd=self.root,
                                      stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
                data = proc.stdout if proc.returncode == 0 else None
            else:
                full = os.path.join(self.root, path)
                try:
                    st = os.lstat(full)
                    if stat.S_ISLNK(st.st_mode):
                        data = os.readlink(full).encode("utf-8", "replace")  # what git stores for a link
                    elif not stat.S_ISREG(st.st_mode) or st.st_size > 2000000:
                        data = None
                    else:
                        with open(full, "rb") as fh:
                            data = fh.read()
                except OSError:
                    data = None
            if data is not None and b"\0" in data[:8000]:
                data = None
            self._cache[key] = data.decode("utf-8", "replace") if data is not None else None
        return self._cache[key]

    def exists_head(self, path):
        if self.committed:
            proc = subprocess.run(["git", "cat-file", "-e", self.head + ":" + path], cwd=self.root,
                                  stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            return proc.returncode == 0
        return os.path.exists(os.path.join(self.root, path))

    def read_base(self, path):
        proc = subprocess.run(["git", "cat-file", "blob", "%s:%s" % (self.base, path)], cwd=self.root,
                              stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
        if proc.returncode != 0 or b"\0" in proc.stdout[:8000]:
            return None
        return proc.stdout.decode("utf-8", "replace")

    def grep(self, opts, pathspecs=(), side="head"):
        """git grep over the head tree (committed), the working tree, or the base."""
        rev = self.base if side == "base" else (self.head if self.committed else None)
        extra = ["--untracked"] if rev is None else []  # working tree: include new, unignored files
        cmd = ["grep", "-I"] + extra + list(opts) + ([rev] if rev else []) + ["--"] + list(pathspecs)
        out = git(cmd, check=False, cwd=self.root)
        if rev:
            prefix = rev + ":"
            out = "\n".join(l[len(prefix):] if l.startswith(prefix) else l for l in out.split("\n"))
        return out


def detect_base(root, explicit, head="HEAD"):
    if explicit:
        ref = explicit
    else:
        ref = None
        sym = git(["symbolic-ref", "-q", "--short", "refs/remotes/origin/HEAD"], check=False, cwd=root).strip()
        candidates = ([sym] if sym else []) + ["origin/main", "origin/master", "main", "master"]
        for cand in candidates:
            if git(["rev-parse", "-q", "--verify", cand + "^{commit}"], check=False, cwd=root).strip():
                ref = cand
                break
        if not ref:
            raise ScanError("cannot find a base branch (tried origin/HEAD, origin/main, origin/master, main, master); pass --base")
    if not git(["rev-parse", "-q", "--verify", ref + "^{commit}"], check=False, cwd=root).strip():
        raise ScanError("base ref %r does not exist" % ref)
    mb = git(["merge-base", ref, head], check=False, cwd=root).strip()
    if not mb:
        raise ScanError("no merge base between %s and %s (shallow clone or unrelated history?)" % (ref, head))
    return ref, mb


def generated_paths(root, paths):
    if not paths:
        return set()
    out = git(["check-attr", "-z", "--stdin", "linguist-generated", "linguist-vendored"],
              check=False, cwd=root, input_text="\0".join(paths) + "\0")
    parts = out.split("\0")
    gen = set()
    for i in range(0, len(parts) - 2, 3):
        path, _attr, value = parts[i], parts[i + 1], parts[i + 2]
        if value in ("set", "true"):
            gen.add(path)
    for p in paths:
        base = os.path.basename(p)
        if base in LOCK_NAMES or any(fnmatch.fnmatch(p, g) for g in GENERATED_GLOBS):
            gen.add(p)
    return gen


def churn_counts(root, paths, head="HEAD", days=90):
    """Commits per path in the last `days` days, or (None, reason) when unknowable."""
    if git(["rev-parse", "--is-shallow-repository"], check=False, cwd=root).strip() == "true":
        return None, "shallow clone"
    try:
        out = git(["log", "--since=%d.days" % days, "--format=tformat:@@", "--name-only", head, "--"], cwd=root)
    except ScanError as exc:
        return None, "git log failed: %s" % exc
    wanted = set(paths)
    counts = defaultdict(int)
    for line in out.split("\n"):
        if line in wanted:
            counts[line] += 1
    return {p: counts.get(p, 0) for p in paths}, ""


def interest_of(n):
    if n is None:
        return "unknown"
    return "high" if n >= 10 else "medium" if n >= 3 else "low"


def meaningful(text):
    s = " ".join(text.split())
    if len(s) < 12:
        return None
    if re.match(r"^(//|#|/\*|\*|<!--|--|import\b|from\s+\S+\s+import\b|@import\b|package\b|using\b)", s):
        return None
    if not re.search(r"[A-Za-z0-9]", s):
        return None
    return s


class Signals:
    """Collects signals; every check below adds to one of these."""

    def __init__(self, churn):
        self.churn = churn
        self.items = []
        self.versions_truncated = False

    def add(self, kind, category, path, line, evidence, direction="added", note="", interest=None):
        if interest is None:
            interest = interest_of(None if self.churn is None else self.churn.get(path))
        self.items.append({
            "category": category, "kind": kind, "direction": direction, "path": path,
            "line": line, "evidence": clip(evidence), "note": redact(note), "interest": interest,
        })


def collect_files(repo, committed, head, merge_base):
    diff_args = ["diff", "--no-color", "--no-ext-diff", "--no-textconv", "--src-prefix=a/", "--dst-prefix=b/",
                 "--unified=0", "--find-renames", merge_base]
    if committed:
        diff_args.append(head)
    diff_args.append("--")
    files = parse_diff(git(diff_args, cwd=repo.root))
    if not committed:
        untracked = [p for p in git(["ls-files", "--others", "--exclude-standard", "-z"], cwd=repo.root).split("\0") if p]
        for p in untracked:
            fc = FileChange(p)
            fc.status = "A"
            content = repo.read_head(p)
            if content is None:
                fc.binary = True
            else:
                fc.added = list(enumerate(content.split("\n"), start=1))
                if fc.added and fc.added[-1][1] == "":
                    fc.added.pop()
            files.append(fc)
    return files


def is_opted_out(repo, sig, f):
    head_text = repo.read_head(f.path) if f.status != "D" else None
    if head_text is None or OPT_OUT not in "\n".join(head_text.split("\n")[:30]):
        return False
    opted = [l for l, t in f.added if OPT_OUT in t and l <= 30]  # the marker itself, not a fixture quoting it
    if opted:
        sig.add("scan-opt-out", "code", f.path, opted[0], OPT_OUT,
                note="file opted out of line rules; the judge should confirm why")
    elif f.added or f.removed:  # never silent: say which lines the line rules did not read
        first = f.added[0][0] if f.added else 1  # removed lines have old-file numbers; point at the marker instead
        sig.add("scan-opt-out", "code", f.path, first, OPT_OUT, direction="info",
                note="opted-out file: %d added, %d removed lines were not line-checked; the judge reads them"
                % (len(f.added), len(f.removed)))
    return True


CONFIG_KINDS = {"tls-off", "perm"}
STRING_BLIND_KINDS = {"suppression", "bypass", "dead-branch", "unsafe-exec"}  # match code, not string contents


def check_secrets(sig, f):
    """Every text file, generated or opted out included: a credential is never someone else's problem."""
    for lineno, text in f.added:
        if any(rx.search(text) for rx in SECRET_RULES):
            sig.add("secret", "security", f.path, lineno, text, note="credential-shaped string; never commit secrets")


def check_config(sig, f):
    """Transport and permission rules for config files: plists, manifests, env files."""
    for lineno, text in f.added:
        for kind, cat, rx, exts, note in LINE_RULES:
            if kind in CONFIG_KINDS and exts is None and rx.search(text):
                sig.add(kind, cat, f.path, lineno, text, note=note)


def check_lines(sig, f):
    """Per-line rules over added lines; debt markers paid down over removed ones."""
    e = ext_of(f.path)
    for lineno, text in f.added:
        code = strip_strings(text)
        for kind, cat, rx, exts, note in LINE_RULES:
            if exts is not None and e not in exts:
                continue
            if kind == "test-disabled" and not is_test(f.path):
                continue
            if kind in ("ci-weakened", "unpinned") and not is_ci(f.path):
                continue
            if rx.search(code if kind in STRING_BLIND_KINDS else text):
                sig.add(kind, cat, f.path, lineno, text, note=note)
        m = SATD_HARD.search(text)
        if not (m and in_comment(f.path, text, m.start())):
            m = SATD_SOFT.search(text)
        if m and in_comment(f.path, text, m.start()):
            sig.add("satd", "code", f.path, lineno, text, note="self-admitted debt")
        if is_test(f.path) and TEST_SLEEP.search(text):
            sig.add("test-sleep", "test", f.path, lineno, text, note="time-based wait makes tests flaky")
        for dm in VERSIONED_DECL.finditer(code):
            keyword, name = dm.group(1).lower(), dm.group(2)
            if VERSIONED_ANY.search(name) or (keyword in TYPE_KEYWORDS and VERSIONED_TYPE.search(name)):
                sig.add("parallel-version", "design", f.path, lineno, text, note="versioned name: %s" % name)
    for lineno, text in f.removed:
        m = SATD_HARD.search(text)
        if m and in_comment(f.path, text, m.start()):
            sig.add("satd", "code", f.path, lineno, text, direction="removed", note="debt marker removed")


def check_commented_code(sig, f):
    """Three or more consecutive added comment lines that read as code."""
    lead = {"slash": r"^//", "hash": r"^#", "dash": r"^--", "markup": r"^//"}[comment_style(f.path)]
    run, prev = [], None
    for lineno, text in f.added + [(None, "")]:
        s = text.strip()
        is_comment_code = (lineno is not None and re.match(lead + r"\s*\S", s)
                           and not re.match(r"^#(!|include|import|if|endif|else|define|pragma|region|endregion)\b", s)
                           and not re.match(lead + r"\s*(MARK|NOTE|SAFETY|swiftlint|eslint|noqa|type:)", s)
                           and CODE_LIKE.search(re.sub(lead + r"\s*", "", s)))
        if is_comment_code and (prev is None or lineno == prev + 1):
            run.append((lineno, text))
        else:
            if len(run) >= 3:
                sig.add("commented-out-code", "code", f.path, run[0][0], run[0][1], note="%d commented-out lines" % len(run))
            run = [(lineno, text)] if is_comment_code else []
        prev = lineno if is_comment_code else None


def sql_code(text):
    """A SQL line without its `--` comment; a `'--'` inside a string is kept."""
    i = strip_strings(text).find("--")
    return text if i < 0 else text[:i]


def check_sql(sig, repo, f):
    """Tables without row-level security; SECURITY DEFINER without a pinned search_path."""
    raw = repo.read_head(f.path) or "\n".join(t for _, t in f.added)
    head_text = "\n".join(sql_code(l) for l in raw.split("\n"))  # an RLS line commented out with -- does not count
    for lineno, text in f.added:
        tm = SQL_CREATE_TABLE.search(sql_code(text))
        if tm and not re.search(r"\b(temp|temporary)\s+table\b", text, re.I):
            tbl = tm.group(1)
            rls = re.compile(r"alter\s+table\s+(?:if\s+exists\s+)?(?:only\s+)?(?:public\.)?\"?%s\"?\s+enable\s+row\s+level\s+security" % re.escape(tbl), re.I)
            if not rls.search(head_text):
                sig.add("table-without-rls", "security", f.path, lineno, text, note="no ENABLE ROW LEVEL SECURITY for %s in this file" % tbl)
    lines = [sql_code(t) for _, t in f.added]  # a comment that names SECURITY DEFINER is not one
    for i, (lineno, text) in enumerate(f.added):
        if not SQL_SECDEF.search(lines[i]):
            continue
        start = i
        while start > 0 and not SQL_FUNC_START.search(lines[start]):
            start -= 1
        end = i + 1
        while end < len(lines) and not SQL_STMT_START.search(lines[end]):
            end += 1
        if not re.search(r"search_path", "\n".join(lines[start:end]), re.I):
            sig.add("secdef-no-search-path", "security", f.path, lineno, text, note="SECURITY DEFINER without a pinned search_path")


SQL_GRANT_PUBLIC = re.compile(r"\bgrant\b[\s\S]*?\bto\s+(?:[\w\".]+\s*,\s*)*\"?(anon|public)\"?(?![\w.])", re.I)


def check_sql_grants(sig, f):
    """A grant to anon or public, read as a whole statement (lists and line breaks included)."""
    start, buf = None, []
    for lineno, text in f.added:
        if start is None:
            start = lineno
        buf.append(re.sub(r"--.*$", "", text))
        if ";" in text:
            if SQL_GRANT_PUBLIC.search(" ".join(buf)):
                sig.add("sql-grant", "security", f.path, start, " ".join(t.strip() for t in buf),
                        note="privilege granted to anon/public")
            start, buf = None, []


def check_size(sig, repo, f):
    """A big file that keeps growing is where design debt piles up."""
    if f.status == "D" or ext_of(f.path) not in CODE_EXT or is_test(f.path):
        return
    content = repo.read_head(f.path)
    if content is None:
        return
    n = content.count("\n") + 1
    growth = len(f.added) - len(f.removed)
    if n >= 800 and growth >= 40:
        new_file = f.status == "A"
        sig.add("large-new-file" if new_file else "large-file-growing", "design", f.path, None,
                "%d lines after this change (+%d net)" % (n, growth),
                note="large new file; could it be split?" if new_file
                else "large file grew; consider splitting before it grows again")


def annotate_parallel_versions(sig, repo, max_lookups=25):
    """Keep a versioned name only when its unversioned original still exists: two versions of one thing.

    `ipV6` or `fetchV2` with no `fetch` anywhere is a name, not a second version."""
    kept, looked = [], {}
    for s in sig.items:
        if s["kind"] != "parallel-version":
            kept.append(s)
            continue
        name = s["note"].split(": ", 1)[1]
        stem = VERSION_PART.sub("", name)
        if not stem or stem == name or len(stem) < 4:
            continue
        if stem not in looked:
            if len(looked) >= max_lookups:
                sig.versions_truncated = True
                s["note"] += "; unconfirmed (lookup limit reached)"
                kept.append(s)  # kept unconfirmed rather than dropped
                continue
            looked[stem] = [h for h in repo.grep(["-l", "-w", "-F", "-e", stem]).split("\n") if h]
        own_ext = ext_of(s["path"])
        others = sorted((h for h in looked[stem] if h != s["path"]),
                        key=lambda h: (ext_of(h) != own_ext, is_test(h), h))
        if others:
            s["note"] += "; original %s still referenced in %d file(s), e.g. %s" % (stem, len(others), others[0])
            kept.append(s)
    sig.items[:] = kept


def check_tests(sig, measured, code_files, test_files):
    churn = measured["code_added"] + measured["code_removed"]
    if churn >= 30 and not test_files:
        sig.add("no-test-change", "test", None, None,
                "%d code lines changed in %d files, no test file changed" % (churn, len(code_files)),
                note="confirm the changed behaviour is covered", interest="n/a")
    added = sum(1 for f in test_files for _, t in f.added if TEST_DECL.search(t))
    removed = sum(1 for f in test_files for _, t in f.removed if TEST_DECL.search(t))
    if removed > added:
        sig.add("tests-removed", "test", None, None, "%d test cases removed, %d added" % (removed, added),
                note="net loss of test cases", interest="n/a")


def check_duplication(sig, repo, code_files, generated, measured, max_windows=2000, max_files=400):
    """Added blocks of 6+ meaningful lines that exist verbatim elsewhere (one git grep)."""
    windows = []
    for f in code_files:
        if ext_of(f.path) in ("sql", "css", "scss", "html") or is_ci(f.path):
            continue
        runs, seq, prev = [], [], None
        for lineno, text in f.added:
            if prev is not None and lineno != prev + 1:
                runs.append(seq)
                seq = []
            prev = lineno
            norm = meaningful(text)
            if norm:
                seq.append((lineno, norm, text.strip()))
        runs.append(seq)
        for seq in runs:
            for start in range(0, len(seq) - 5):
                windows.append((f, seq[start: start + 6]))
    measured["dup_windows"] = min(len(windows), max_windows)
    measured["dup_truncated"] = len(windows) > max_windows
    if not windows:
        return
    windows = windows[:max_windows]
    # git grep -F matches raw text, so the anchor is the raw line, not its whitespace-collapsed form.
    # Both forms: a verbatim copy matches the raw line, a re-spaced copy the collapsed one.
    anchors = sorted({a for _, w in windows
                      for a in (max((raw for _, _, raw in w), key=len), max((n for _, n, _ in w), key=len))})
    fd, pat_file = tempfile.mkstemp(prefix="debt_scan_", suffix=".txt")
    os.close(fd)
    try:
        with open(pat_file, "w") as fh:
            fh.write("\n".join(anchors) + "\n")
        out = repo.grep(["-c", "-F", "-f", pat_file])
    finally:
        try:
            os.unlink(pat_file)
        except OSError:
            pass
    hit_counts = []
    for line in out.split("\n"):
        p, _, n = line.rpartition(":")
        if not p or not n.isdigit():
            continue
        if p in generated or is_doc(p) or ext_of(p) not in CODE_EXT or is_test(p):
            continue
        if any(fnmatch.fnmatch(p, g) for g in GENERATED_GLOBS):
            continue
        hit_counts.append((int(n), p))
    grams = {}
    if len(hit_counts) > max_files:
        measured["dup_truncated"] = True
    for _, p in sorted(hit_counts, reverse=True)[:max_files]:
        content = repo.read_head(p)
        if content is None:
            continue
        seq = [(i, meaningful(t)) for i, t in enumerate(content.split("\n"), start=1)]
        seq = [(i, n) for i, n in seq if n]
        for k in range(0, len(seq) - 5):
            grams.setdefault(tuple(n for _, n in seq[k:k + 6]), []).append((p, seq[k][0]))
    found = {}
    for f, win in windows:
        own_lines = {i for i, _, _ in win}
        for p, first in grams.get(tuple(n for _, n, _ in win), []):
            if p == f.path and first in own_lines:
                continue
            found.setdefault((f.path, p), (win[0][0], first, win[0][1]))
            break
    for (fp, other), (line, other_line, text) in found.items():
        sig.add("duplicate-block", "code", fp, line, text,
                note="6+ lines also at %s:%d; reuse instead of copying" % (other, other_line))


def dep_key(text):
    """The dependency a manifest line names, without its version."""
    t = text.strip()
    m = re.search(r"[\"']([\w.-]+:[\w.-]+):[^\"']+[\"']", t)  # gradle "group:artifact:version"
    if m:
        return m.group(1)
    m = re.match(r"^(?:pod|gem)\s+['\"]([^'\"]+)", t) or re.match(r"^\.package\(\s*\w+:\s*\"([^\"]+)", t)
    if m:
        return m.group(1)
    m = re.match(r"^(?:require\s+)?([a-z0-9.-]+\.[a-z]{2,}/\S+)\s+v", t)  # go.mod
    if m:
        return m.group(1)
    m = re.match(r"^\"?([A-Za-z0-9_.\-\[\]]+)", t)
    return m.group(1).lower() if m else t


def check_package_json(sig, repo, f):
    try:
        new = json.loads(repo.read_head(f.path) or "{}")
        old = json.loads(repo.read_base(f.path) or "{}") if f.status != "A" else {}
    except ValueError:
        new, old = {}, {}
    for section in ("dependencies", "devDependencies", "peerDependencies", "optionalDependencies"):
        nd, od = new.get(section) or {}, old.get(section) or {}
        for pkg, ver in sorted(nd.items()):
            ver = str(ver)
            if pkg not in od:
                sig.add("dependency-added", "dependency", f.path, None, "%s %s (%s)" % (pkg, ver, section),
                        note="new dependency: is it needed, maintained, already covered?")
                if re.match(r"^(\*|latest|>=?[^<]*$|x)$", ver.strip()) or (re.match(r"^(github:|git\+|https?://)", ver) and "#" not in ver):
                    sig.add("dependency-unpinned", "dependency", f.path, None, "%s %s" % (pkg, ver), note="no upper bound or commit pin")
            elif str(od[pkg]) != ver:
                sig.add("dependency-changed", "dependency", f.path, None, "%s %s -> %s" % (pkg, od[pkg], ver),
                        direction="info", note="version changed")
        for pkg in sorted(set(od) - set(nd)):
            sig.add("dependency-removed", "dependency", f.path, None, "%s (%s)" % (pkg, section),
                    direction="removed", note="dependency removed")


def check_manifest_lines(sig, f, rule):
    def is_dep(text):
        t = text.strip()
        return bool(t) and not t.startswith(("#", "//")) and bool(rule.search(text))
    old_keys = {dep_key(t) for _, t in f.removed if is_dep(t)}
    for lineno, text in f.added:
        if not is_dep(text):
            continue
        if dep_key(text) in old_keys:
            sig.add("dependency-changed", "dependency", f.path, lineno, text, direction="info", note="version or options changed")
        else:
            sig.add("dependency-added", "dependency", f.path, lineno, text, note="new dependency: is it needed, maintained, already covered?")


def check_dependencies(sig, repo, files):
    changed = {f.path for f in files}
    for f in files:
        if f.status == "D":
            continue
        name = os.path.basename(f.path)
        if name == "package.json":
            check_package_json(sig, repo, f)
        else:
            rule = (DEP_LINE["requirements"] if re.match(r"requirements.*\.txt$", name)
                    else DEP_LINE["gradle"] if name.endswith((".gradle", ".gradle.kts"))
                    else DEP_LINE.get(name))
            if rule:
                check_manifest_lines(sig, f, rule)
        if name in LOCK_FOR and any(s["path"] == f.path and s["category"] == "dependency" for s in sig.items):
            d = os.path.dirname(f.path)
            existing = [l for l in (os.path.join(d, x) if d else x for x in LOCK_FOR[name]) if repo.exists_head(l)]
            if existing and not any(l in changed for l in existing):
                sig.add("lockfile-stale", "dependency", f.path, None, "%s changed but %s did not" % (f.path, existing[0]),
                        note="lockfile not updated with the manifest")


def check_docs(sig, repo, doc_files, removed_paths, code_files):
    """Broken relative links, docs naming removed files, and new settings nobody wrote down."""
    for f in doc_files:
        for lineno, text in f.added:
            for m in MD_LINK.finditer(text):
                target = m.group(1)
                if re.match(r"^([a-z][a-z0-9+.-]*:|#|//|\{\{|\$)", target, re.I):
                    continue
                target = target.split("#", 1)[0].split("?", 1)[0]
                if not target:
                    continue
                resolved = os.path.normpath(target.lstrip("/") if target.startswith("/")
                                            else os.path.join(os.path.dirname(f.path), target))
                if not resolved.startswith("..") and not repo.exists_head(resolved):
                    sig.add("broken-link", "docs", f.path, lineno, text, note="link target %s does not exist" % resolved)
    for old in removed_paths:
        if "/" not in old or is_doc(old):
            continue
        for h in [x for x in repo.grep(["-l", "-F", "-e", old], ["*.md", "*.mdx"]).split("\n") if x][:3]:
            sig.add("stale-reference", "docs", h, None, "still mentions %s" % old,
                    note="the file was removed or renamed in this change", interest="n/a")
    new_vars = {}
    for f in code_files:
        for lineno, text in f.added:
            for rx in ENV_RULES:
                for m in rx.finditer(text):
                    new_vars.setdefault(m.group(1), (f, lineno, text))
    for var, (f, lineno, text) in sorted(new_vars.items()):
        if repo.grep(["-l", "-w", "-F", "-e", var], side="base").strip():
            continue  # not new: existed before this change
        documented = repo.grep(["-l", "-w", "-F", "-e", var], ["*.md", "*.mdx", "*.example", "*.sample", ".env*", "*.env.*"])
        if not documented.strip():
            sig.add("undocumented-config", "docs", f.path, lineno, text,
                    note="new setting %s is not mentioned in any doc or example file" % var)


def register_files(content):
    """The `files:` list of a register entry (inline [a, b] or a YAML list), read from its front matter.

    Without front matter the whole file is read, but a block list stops at the first
    line that is not a `- item`, so body bullets after a blank line never count."""
    text = (content or "").lstrip("\ufeff").replace("\r\n", "\n")
    front = re.match(r"^---[ \t]*\n(.*?)^---[ \t]*$", text, re.S | re.M)
    section = front.group(1) if front else text
    fm = re.search(r"^files:[ \t]*\[(.*?)\]", section, re.M)
    if fm:
        return [x.strip().strip("'\"") for x in fm.group(1).split(",") if x.strip()]
    block = re.search(r"^files:[ \t]*\n((?:[ \t]*-[ \t]+\S.*\n?)+)", section, re.M)
    if block:
        return [re.sub(r"^\s*-\s*", "", x).strip().strip("'\"") for x in block.group(1).splitlines() if x.strip()]
    return []


def read_register(sig, repo, files, register_dir, removed_paths=()):
    """Recorded debt this change touches, pays down (deletes, moves out, narrows) or adds."""
    register = {"dir": register_dir, "touched": [], "paid": [], "added": []}
    reg_root = register_dir.strip("/")

    def is_entry(path):
        return bool(path) and path.startswith(reg_root + "/") and path.endswith(".md") \
            and os.path.basename(path).lower() != "readme.md"

    for f in files:
        old = f.old_path or f.path
        if f.status == "D" and is_entry(f.path):
            register["paid"].append(f.path)
        elif f.status == "A" and is_entry(f.path):
            register["added"].append(f.path)
        elif is_entry(old) and not is_entry(f.path):
            register["paid"].append(old)  # moved out of the register: a payment claim that needs a witness
        elif is_entry(old) and f.status in ("M", "R"):
            # Renamed or edited in place: any file it stops naming is debt claimed as paid.
            dropped = sorted(set(register_files(repo.read_base(old))) - set(register_files(repo.read_head(f.path))))
            if dropped:
                register["paid"].append("%s (no longer names %s)" % (f.path, ", ".join(dropped)))
    paths = [f.path for f in files]
    for rf in [x for x in repo.grep(["-l", "-e", "^files:"], [reg_root + "/*.md"]).split("\n") if x]:
        if rf in register["paid"] or rf in register["added"]:
            continue
        entries = register_files(repo.read_head(rf))
        for p in paths:
            if any(p == e or p.startswith(e.rstrip("/") + "/") or fnmatch.fnmatch(p, e) for e in entries if e):
                register["touched"].append({"entry": rf, "path": p})
                break
        gone = [e for e in entries if e and e in removed_paths and not repo.exists_head(e)]
        if gone:
            sig.add("register-stale", "docs", rf, None, "files: %s" % ", ".join(gone[:3]),
                    note="this change removed or renamed files this entry names; update its files: list", interest="n/a")
    return register


NEVER_COLLAPSE = {"dependency-added", "dependency-changed", "dependency-removed", "duplicate-block",
                  "parallel-version", "undocumented-config", "stale-reference"}


def collapse(signals):
    """One signal per (kind, path, direction): repeats become a count, not a wall."""
    out, index = [], {}
    for s in signals:
        s.setdefault("count", 1)
        s.setdefault("lines", [] if s["line"] is None else [s["line"]])
        key = (s["category"], s["kind"], s["direction"], s["path"])
        if s["path"] is None or s["kind"] in NEVER_COLLAPSE:
            out.append(s)
        elif key in index:
            index[key]["count"] += 1
            if s["line"] is not None:
                index[key]["lines"].append(s["line"])
        else:
            index[key] = s
            out.append(s)
    for s in out:
        if s["count"] > 1:
            s["note"] += " (%d times in this file; first shown)" % s["count"]
    return out


def scan(root, base_ref, merge_base, committed, register_dir, head="HEAD"):
    repo = Repo(root, merge_base, committed, head)
    files = collect_files(repo, committed, head, merge_base)
    if not files:
        return None
    generated = generated_paths(root, [f.path for f in files])
    churn, churn_unknown = churn_counts(root, [f.path for f in files], head)
    sig = Signals(churn)
    measured = {"files": len(files), "generated_skipped": 0, "added": 0, "removed": 0,
                "code_added": 0, "code_removed": 0, "test_files": 0, "binary": 0,
                "guidance_changed": 0, "dup_windows": 0, "dup_truncated": False}
    code_files, test_files, doc_files, removed_paths = [], [], [], []

    for f in files:
        measured["added"] += len(f.added)
        measured["removed"] += len(f.removed)
        if f.status in ("D", "R") and f.old_path:
            removed_paths.append(f.old_path)  # binaries too: docs may still name a deleted image
        if f.binary:
            measured["binary"] += 1
            continue
        check_secrets(sig, f)
        if f.path in generated:
            measured["generated_skipped"] += 1
            continue
        if is_guidance(f.path):
            measured["guidance_changed"] += len(f.added) + len(f.removed)
        if is_doc(f.path):
            doc_files.append(f)
            continue
        is_code = ext_of(f.path) in CODE_EXT or is_ci(f.path)
        if is_test(f.path):
            test_files.append(f)
            measured["test_files"] += 1
        elif is_code:
            code_files.append(f)
            if ext_of(f.path) not in STYLE_EXT:  # stylesheets do not summon a judge by size
                measured["code_added"] += len(f.added)
                measured["code_removed"] += len(f.removed)
        else:
            check_config(sig, f)
            continue
        if not is_opted_out(repo, sig, f):
            check_lines(sig, f)
            check_commented_code(sig, f)
        if ext_of(f.path) == "sql":
            check_sql(sig, repo, f)
            check_sql_grants(sig, f)
        check_size(sig, repo, f)

    annotate_parallel_versions(sig, repo)
    measured["versions_truncated"] = sig.versions_truncated
    check_tests(sig, measured, code_files, test_files)
    check_duplication(sig, repo, code_files, generated, measured)
    check_dependencies(sig, repo, files)
    check_docs(sig, repo, doc_files, removed_paths, code_files)
    register = read_register(sig, repo, files, register_dir, set(removed_paths))
    signals = collapse(sig.items)

    counts = defaultdict(lambda: {"added": 0, "removed": 0, "info": 0})
    for s in signals:
        counts[s["category"]][s["direction"]] += s["count"]
    code_churn = measured["code_added"] + measured["code_removed"]
    added = [s for s in signals if s["direction"] == "added"]
    guidance = measured["guidance_changed"]
    unread = [s for s in signals if s["kind"] == "scan-opt-out"]
    if register["paid"]:
        recommend, reason = True, "register entry deleted; confirm the debt is really paid"
    elif unread and not added:
        recommend, reason = True, "lines in opted-out files were not line-checked; the judge reads them"
    elif added:
        recommend, reason = True, "%d signals, %d code lines changed" % (len(added), code_churn)
    elif guidance >= 20:
        recommend, reason = True, "%d lines of agent guidance changed; check for contradictions and stale rules" % guidance
    elif not code_files and not test_files:
        recommend, reason = False, "no code changed; the scan covers docs and config debt"
    elif code_churn < 40:
        recommend, reason = False, "small code change (%d lines) with no signals" % code_churn
    else:
        recommend, reason = True, "%d code lines changed, no signals" % code_churn
    hot = []
    if churn is not None:
        hot = sorted(((n, p) for p, n in churn.items() if n >= 10 and p not in generated), reverse=True)[:5]
    return {
        "version": VERSION, "base_ref": base_ref, "merge_base": merge_base,
        "head": git(["rev-parse", head], cwd=root).strip(),
        "mode": "committed" if committed else "working-tree",
        "measured": measured, "signals": signals, "counts": dict(counts),
        "register": register, "churn_90d": churn, "churn_unknown": churn_unknown,
        "hot_files": [{"path": p, "commits_90d": n} for n, p in hot],
        "recommend_judge": recommend, "reason": reason,
    }


def write_diff(root, merge_base, head, path):
    """The exact change the scan measured, for the judge to read (never committed)."""
    args = (["diff", "--no-color", "--no-ext-diff", "--no-textconv", "--src-prefix=a/", "--dst-prefix=b/",
             "--find-renames", merge_base] + ([head] if head else []) + ["--"])
    text = git(args, cwd=root)
    if head is None:
        for p in [x for x in git(["ls-files", "--others", "--exclude-standard", "-z"], cwd=root).split("\0") if x]:
            text += git(["diff", "--no-color", "--no-ext-diff", "--no-textconv", "--no-index", "--", "/dev/null", p],
                        check=False, cwd=root)
    with open(path, "w") as fh:
        fh.write(text)


def render(result):
    m = result["measured"]
    lines = []
    lines.append("tech-debt scan %s: %s (%s) -> %s [%s]" % (
        result["version"], result["merge_base"][:9], result["base_ref"], result["head"][:9], result["mode"]))
    lines.append("measured: %d files, +%d/-%d lines (code +%d/-%d), %d test files, %d generated/lock skipped, %d binary" % (
        m["files"], m["added"], m["removed"], m["code_added"], m["code_removed"], m["test_files"],
        m["generated_skipped"], m["binary"]))
    if m["guidance_changed"] or m["dup_truncated"] or m.get("versions_truncated"):
        lines.append("also: %d lines of agent guidance changed; duplicate check %s (%d blocks)%s" % (
            m["guidance_changed"], "TRUNCATED, larger change than it covers" if m["dup_truncated"] else "complete",
            m["dup_windows"], "; versioned-name check TRUNCATED, some unconfirmed" if m.get("versions_truncated") else ""))
    added = [s for s in result["signals"] if s["direction"] == "added"]
    paid = [s for s in result["signals"] if s["direction"] == "removed"]
    info = [s for s in result["signals"] if s["direction"] == "info"]
    lines.append("signals: %d added, %d paid down, %d to note" % (len(added), len(paid), len(info)))
    order = ["security", "design", "code", "test", "dependency", "docs", "infra", "knowledge"]
    for s in sorted(result["signals"], key=lambda s: (order.index(s["category"]) if s["category"] in order else 99, s["direction"] != "added")):
        where = s["path"] or "(whole change)"
        if s["line"]:
            where += ":%d" % s["line"]
        sign = {"added": "+", "removed": "-", "info": "~"}[s["direction"]]
        lines.append("  %s %-10s %-22s %s  %s%s" % (sign, s["category"], s["kind"], where,
                                                   s["note"], (" | " + s["evidence"]) if s["evidence"] and s["line"] else ""))
    reg = result["register"]
    for t in reg["touched"]:
        lines.append("register: %s covers %s (pay down now, or confirm it still holds)" % (t["entry"], t["path"]))
    for p in reg["paid"]:
        lines.append("register: %s %s" % (p, "(claimed paid)" if " (no longer names " in p else "deleted or moved out (claimed paid)"))
    for p in reg["added"]:
        lines.append("register: %s added" % p)
    if result["churn_90d"] is None:
        lines.append("interest: unknown (%s)" % result["churn_unknown"])
    elif result["hot_files"]:
        lines.append("interest: hot files " + ", ".join("%s (%d commits/90d)" % (h["path"], h["commits_90d"]) for h in result["hot_files"]))
    lines.append("judge: %s (%s)" % ("recommended" if result["recommend_judge"] else "not needed", result["reason"]))
    if result.get("json_path"):
        lines.append("json: %s" % result["json_path"])
    if result.get("diff_path"):
        lines.append("diff: %s" % result["diff_path"])
    return "\n".join(lines)


def main(argv=None):
    ap = argparse.ArgumentParser(description="Mechanical technical-debt signals for one change set.")
    ap.add_argument("--base", help="base branch or ref (default: origin/HEAD, then origin/main, origin/master)")
    ap.add_argument("--committed", action="store_true", help="scan merge-base..HEAD only, ignoring uncommitted and untracked files")
    ap.add_argument("--head", help="scan this commit or branch instead of HEAD, without checking it out (implies --committed)")
    ap.add_argument("--json", dest="json_path", help="where to write the full JSON result (default: <git dir>/tech-debt/scan.json, never committed)")
    ap.add_argument("--register", default="docs/tech-debt", help="debt register directory (default docs/tech-debt)")
    ap.add_argument("--repo", default=".", help="repository path (default: current directory)")
    args = ap.parse_args(argv)
    try:
        root = git(["rev-parse", "--show-toplevel"], cwd=args.repo).strip()
        head = args.head or "HEAD"
        if args.head:
            args.committed = True
            if not git(["rev-parse", "-q", "--verify", head + "^{commit}"], check=False, cwd=root).strip():
                raise ScanError("head ref %r does not exist" % head)
        base_ref, mb = detect_base(root, args.base, head)
        result = scan(root, base_ref, mb, args.committed, args.register, head)
        if result is None:
            print("tech-debt scan: EMPTY: no changes between %s and %s; nothing was measured" % (
                args.base or "the base branch", (args.head or "HEAD") if args.committed else "the working tree"), file=sys.stderr)
            return 3
        json_path = args.json_path or os.path.join(
            git(["rev-parse", "--absolute-git-dir"], cwd=root).strip(), "tech-debt", "scan.json")
        os.makedirs(os.path.dirname(os.path.abspath(json_path)), exist_ok=True)
        tmp = json_path + ".tmp"
        with open(tmp, "w") as fh:
            json.dump(result, fh, indent=1, sort_keys=True)
        os.replace(tmp, json_path)
        result["json_path"] = json_path
        diff_path = os.path.splitext(json_path)[0] + ".diff"
        write_diff(root, mb, head if args.committed else None, diff_path)
        result["diff_path"] = diff_path
    except ScanError as exc:
        print("tech-debt scan: CANNOT SCAN: %s" % exc, file=sys.stderr)
        return 2
    except Exception as exc:  # any surprise is "could not scan", never a silent pass
        print("tech-debt scan: CANNOT SCAN: unexpected %s: %s" % (type(exc).__name__, exc), file=sys.stderr)
        return 2
    print(render(result))
    return 0


if __name__ == "__main__":
    sys.exit(main())
