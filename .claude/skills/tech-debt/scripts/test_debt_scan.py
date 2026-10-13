#!/usr/bin/env python3
"""Tests for debt_scan.py. Standard library only; builds throwaway git repos.

debt-scan: ignore-file (fixtures below contain the very patterns the scanner hunts)

Every negative case keeps the trigger token present (a TODO in a string, a
`!!` in JavaScript, an `@v4` action pin), because a negative test that avoids
the trigger proves nothing. Run: python3 test_debt_scan.py
"""

import json
import os
import shutil
import subprocess
import sys
import tempfile
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
sys.dont_write_bytecode = True  # importing the scanner must not leave __pycache__ in repos that do not ignore it
SCAN = os.path.join(HERE, "debt_scan.py")

FUNC = """function computeTotals(items, taxRate) {
  const subtotal = items.reduce((sum, item) => sum + item.price * item.qty, 0);
  const discount = items.filter((item) => item.onSale).length * 2.5;
  const taxed = (subtotal - discount) * (1 + taxRate);
  const rounded = Math.round(taxed * 100) / 100;
  console.info('computed totals for', items.length, 'items');
  return { subtotal: subtotal, discount: discount, total: rounded };
}
"""


class Repo:
    def __init__(self, test):
        self.dir = tempfile.mkdtemp(prefix="debt_scan_test_")
        test.addCleanup(shutil.rmtree, self.dir, True)
        home = os.path.join(self.dir, ".home")
        os.makedirs(home)
        self.env = dict(os.environ, HOME=home, GIT_CONFIG_NOSYSTEM="1",
                        GIT_AUTHOR_NAME="t", GIT_AUTHOR_EMAIL="t@example.com",
                        GIT_COMMITTER_NAME="t", GIT_COMMITTER_EMAIL="t@example.com")
        self.env.pop("GIT_DIR", None)
        self.root = os.path.join(self.dir, "repo")
        os.makedirs(self.root)
        self.git("init", "-q")
        self.git("checkout", "-q", "-b", "main")

    def git(self, *args):
        return subprocess.run(["git"] + list(args), cwd=self.root, env=self.env, check=True,
                              stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                              universal_newlines=True).stdout

    def write(self, path, text):
        full = os.path.join(self.root, path)
        os.makedirs(os.path.dirname(full) or self.root, exist_ok=True)
        with open(full, "w") as fh:
            fh.write(text)

    def remove(self, path):
        os.remove(os.path.join(self.root, path))

    def commit(self, msg="c"):
        self.git("add", "-A")
        self.git("commit", "-q", "--allow-empty", "-m", msg)

    def branch(self):
        self.git("checkout", "-q", "-b", "feature")

    def scan(self, *extra, expect=0):
        out_json = os.path.join(self.dir, "out.json")
        if os.path.exists(out_json):
            os.remove(out_json)
        proc = subprocess.run([sys.executable, SCAN, "--json", out_json] + list(extra), cwd=self.root,
                              env=self.env, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                              universal_newlines=True)
        if proc.returncode != expect:
            raise AssertionError("exit %d (wanted %d)\nstdout:\n%s\nstderr:\n%s" % (
                proc.returncode, expect, proc.stdout, proc.stderr))
        self.stdout, self.stderr = proc.stdout, proc.stderr
        if expect != 0:
            return None
        with open(out_json) as fh:
            return json.load(fh)


def kinds(result, kind=None, path=None):
    """Signals, expanded back to one entry per line (the scanner collapses repeats per file)."""
    out = []
    for s in result["signals"]:
        if (kind is None or s["kind"] == kind) and (path is None or s["path"] == path):
            for ln in (s["lines"] or [s["line"]]):
                out.append(dict(s, line=ln))
    return out


def base_repo(test, files=None):
    r = Repo(test)
    r.write("README.md", "# fixture\n")
    for p, t in (files or {}).items():
        r.write(p, t)
    r.commit("base")
    r.branch()
    return r


class SelfAdmittedDebt(unittest.TestCase):
    def test_markers_in_comments_count_and_others_do_not(self):
        r = base_repo(self, {"src/old.ts": "// TODO: remove legacy path\nexport const a = 1;\n"})
        r.write("src/app.ts", "\n".join([
            "// TODO: handle the offline case",
            "const todoList = [];          // a variable named todo, not debt",
            "const label = \"TODO\";        // a string, not a comment marker",
            "# not a comment in ts but harmless",
            "/* FIXME: retries are not bounded */",
            "// workaround for now until the API is fixed",
            "// Write to a temporary file first.",
            "const tip = \"use the workaround for now\";  // user-facing copy, not debt",
        ]) + "\n")
        r.write("docs/guide.md", "TODO: write this section\n")
        r.write("src/old.ts", "export const a = 1;\n")  # removes the old TODO
        res = r.scan()
        added = [s for s in kinds(res, "satd") if s["direction"] == "added"]
        lines = sorted(s["line"] for s in added)
        self.assertEqual(lines, [1, 5, 6], added)
        removed = [s for s in kinds(res, "satd") if s["direction"] == "removed"]
        self.assertEqual(len(removed), 1)
        self.assertFalse(kinds(res, "satd", "docs/guide.md"))


class Suppressions(unittest.TestCase):
    def test_language_scoped_rules(self):
        r = base_repo(self)
        r.write("a.ts", "// @ts-ignore\nconst x = y as any;\nif (isPro || true) {}\n")
        r.write("b.js", "const ok = !!value;\n")
        r.write("C.kt", "val name = user!!.name\nval same = a != b\n")
        r.write("D.swift", "let data = try! load()\nlet v = x as! Int\n")
        r.write("e.sh", "rm -f x || true\n")
        r.write("f.py", "import os  # noqa\n")
        res = r.scan()
        got = {(s["path"], s["line"]) for s in kinds(res) if s["kind"] in ("suppression", "bypass")}
        self.assertTrue({("a.ts", 1), ("a.ts", 2), ("a.ts", 3), ("C.kt", 1), ("D.swift", 1), ("D.swift", 2), ("f.py", 1)} <= got, got)
        self.assertNotIn(("b.js", 1), got)
        self.assertNotIn(("C.kt", 2), got)
        self.assertNotIn(("e.sh", 1), got)


class Duplication(unittest.TestCase):
    def test_copied_block_is_found_with_its_original(self):
        r = base_repo(self, {"src/billing.js": "// billing\n" + FUNC})
        r.write("src/checkout.js", "// checkout\n" + FUNC.replace("computeTotals", "computeCheckoutTotals"))
        res = r.scan()
        dups = kinds(res, "duplicate-block", "src/checkout.js")
        self.assertEqual(len(dups), 1, res["signals"])
        self.assertIn("src/billing.js", dups[0]["note"])

    def test_copy_between_two_new_uncommitted_files(self):
        r = base_repo(self)
        r.write("src/one.js", FUNC)
        r.write("src/two.js", "// second\n" + FUNC)
        dups = kinds(r.scan(), "duplicate-block")
        self.assertTrue(dups, "a block copied between two new files must be found before commit")

    def test_new_unique_code_and_test_copies_are_not_duplicates(self):
        r = base_repo(self, {"src/billing.js": FUNC})
        r.write("src/unique.js", FUNC.replace("subtotal", "net").replace("discount", "rebate").replace("taxed", "gross")
                .replace("rounded", "final").replace("items", "lines").replace("console.info", "logger.debug"))
        r.write("tests/billing.test.js", FUNC)
        res = r.scan()
        self.assertFalse(kinds(res, "duplicate-block"), res["signals"])

    def test_license_headers_are_ignored(self):
        header = "".join("// Copyright line %d of the long licence header text here\n" % i for i in range(10))
        r = base_repo(self, {"src/a.js": header + "export const a = 1;\n"})
        r.write("src/b.js", header + "export const b = 2;\n")
        self.assertFalse(kinds(r.scan(), "duplicate-block"))


class Tests(unittest.TestCase):
    def test_code_without_tests_and_disabled_and_removed_tests(self):
        r = base_repo(self, {"tests/x.test.js": "test('a', () => {});\ntest('b', () => {});\n"})
        r.write("src/big.js", "".join("export const v%d = %d;\n" % (i, i) for i in range(40)))
        res = r.scan()
        self.assertEqual(len(kinds(res, "no-test-change")), 1)
        r.write("tests/x.test.js", "test.skip('a', () => {});\nsetTimeout(done, 500);\n")
        res = r.scan()
        self.assertFalse(kinds(res, "no-test-change"))
        self.assertEqual(len(kinds(res, "test-disabled")), 1)
        self.assertEqual(len(kinds(res, "test-sleep")), 1)
        self.assertEqual(len(kinds(res, "tests-removed")), 1)

    def test_skip_word_outside_tests_is_not_a_disabled_test(self):
        r = base_repo(self)
        r.write("src/list.js", "items.skip(2);\nconst it = describe;\nif (token === 'it.skip(') { xit(); }\n")
        self.assertFalse(kinds(r.scan(), "test-disabled"))


class Dependencies(unittest.TestCase):
    def test_new_dependency_and_stale_lockfile(self):
        r = base_repo(self, {"package.json": json.dumps({"dependencies": {"a": "^1.0.0"}}),
                             "package-lock.json": "{}\n"})
        r.write("package.json", json.dumps({"dependencies": {"a": "^1.1.0", "left-pad": "latest"}}))
        res = r.scan()
        self.assertEqual([s["evidence"].split()[0] for s in kinds(res, "dependency-added")], ["left-pad"])
        self.assertEqual(len(kinds(res, "dependency-changed")), 1)
        self.assertEqual(len(kinds(res, "dependency-unpinned")), 1)
        self.assertEqual(len(kinds(res, "lockfile-stale")), 1)
        r.write("package-lock.json", "{\"lockfileVersion\": 3}\n")
        self.assertFalse(kinds(r.scan(), "lockfile-stale"))

    def test_caret_ranges_with_a_lockfile_are_normal(self):
        r = base_repo(self, {"package.json": json.dumps({"dependencies": {}})})
        r.write("package.json", json.dumps({"dependencies": {"b": "^2.0.0"}}))
        res = r.scan()
        self.assertFalse(kinds(res, "dependency-unpinned"))
        self.assertFalse(kinds(res, "lockfile-stale"))  # no lockfile exists at all

    def test_requirements_line(self):
        r = base_repo(self, {"requirements.txt": "requests==2.31.0\n"})
        r.write("requirements.txt", "requests==2.31.0\n# a comment\nhttpx>=0.27\n")
        self.assertEqual(len(kinds(r.scan(), "dependency-added")), 1)


class Docs(unittest.TestCase):
    def test_links_stale_references_and_new_config(self):
        r = base_repo(self, {"docs/a.md": "x\n", "scripts/old_tool.sh": "echo hi\n",
                             "docs/tools.md": "Run scripts/old_tool.sh to start.\n",
                             "src/cfg.js": "const a = process.env.EXISTING_KEY;\n"})
        r.write("docs/b.md", "\n".join([
            "[ok](a.md)", "[missing](nope.md)", "[web](https://example.com/x.md)",
            "[anchor](#top)", "[ok with anchor](a.md#part)", "[root](/README.md)",
        ]) + "\n")
        r.remove("scripts/old_tool.sh")
        r.write("src/cfg.js", "\n".join([
            "const a = process.env.EXISTING_KEY;",
            "const b = process.env.BRAND_NEW_SECRET_NAME;",
            "const c = process.env.DOCUMENTED_FLAG;",
        ]) + "\n")
        r.write("src/moved.js", "const moved = process.env.EXISTING_KEY;\n")  # pre-existing, undocumented: not new
        r.write("README.md", "# fixture\nSet DOCUMENTED_FLAG to turn it on.\n")
        res = r.scan()
        broken = kinds(res, "broken-link")
        self.assertEqual([s["line"] for s in broken], [2], broken)
        stale = kinds(res, "stale-reference")
        self.assertEqual([s["path"] for s in stale], ["docs/tools.md"])
        cfg = kinds(res, "undocumented-config")
        self.assertEqual(len(cfg), 1)
        self.assertIn("BRAND_NEW_SECRET_NAME", cfg[0]["note"])


class Infra(unittest.TestCase):
    def test_ci_and_images(self):
        r = base_repo(self)
        r.write(".github/workflows/ci.yml", "\n".join([
            "jobs:", "  a:", "    steps:", "      - uses: actions/checkout@v4",
            "      - uses: someone/action@main", "        continue-on-error: true",
        ]) + "\n")
        r.write("Dockerfile", "FROM node\nFROM node:20 AS build\nFROM scratch\n")
        res = r.scan()
        unpinned = sorted((s["path"], s["line"]) for s in kinds(res, "unpinned"))
        self.assertEqual(unpinned, [(".github/workflows/ci.yml", 5), ("Dockerfile", 1)])
        self.assertEqual(len(kinds(res, "ci-weakened")), 1)

    def test_ci_rules_do_not_fire_outside_ci_files(self):
        r = base_repo(self)
        r.write("src/notes.js", "// continue-on-error: true is how the old pipeline worked\n")
        self.assertFalse(kinds(r.scan(), "ci-weakened"))


class Precision(unittest.TestCase):
    def test_method_named_eval_and_css_ids_are_not_flagged(self):
        r = base_repo(self)
        r.write("e2e/drive.mjs", "const t = await b.eval(panel, 'document.title');\nconst x = eval(code);\n")
        r.write("web/page.html", "\n".join(["<style>", "#ig-connect[data-state] .a { display:none; }",
                                          "#ig-connect .b { color: red; }", "#ig-connect .c { margin: 0; }",
                                          "#hero .d { padding: 0; }", "</style>"]) + "\n")
        r.write("src/x.js", "const sel = '#main'; // TODO: real one\nconst id = '#TODO';\n")
        res = r.scan()
        self.assertEqual([(s["path"], s["line"]) for s in kinds(res, "unsafe-exec")], [("e2e/drive.mjs", 2)])
        self.assertFalse(kinds(res, "commented-out-code"))
        self.assertEqual([(s["path"], s["line"]) for s in kinds(res, "satd")], [("src/x.js", 1)])

    def test_hash_comments_count_in_python_and_shell(self):
        r = base_repo(self)
        r.write("a.py", "# x = compute(1)\n# if x:\n#     run(x)\n")
        r.write("b.sh", "# TODO: quote this\nrm -f \"$f\"\n")
        res = r.scan()
        self.assertEqual([s["path"] for s in kinds(res, "commented-out-code")], ["a.py"])
        self.assertEqual([s["path"] for s in kinds(res, "satd")], ["b.sh"])


class Security(unittest.TestCase):
    def test_secret_is_flagged_and_never_echoed(self):
        r = base_repo(self)
        token = "ghp_" + "A1b2C3d4" * 5
        r.write("src/k.js", "const t = '%s';\n" % token)
        res = r.scan()
        sec = kinds(res, "secret")
        self.assertEqual(len(sec), 1)
        self.assertNotIn(token, json.dumps(res))
        self.assertNotIn(token, r.stdout)

    def test_sql_rls_and_definer(self):
        r = base_repo(self)
        r.write("supabase/migrations/1_a.sql", "\n".join([
            "create table public.notes (id uuid primary key);",
            "create table if not exists public.safe (id int);",
            "alter table public.safe enable row level security;",
            "create temp table scratch (id int);",
            "create function f() returns void language sql security definer as $$ select 1 $$;",
            "create function g() returns void language sql security definer set search_path = '' as $$ select 1 $$;",
        ]) + "\n")
        res = r.scan()
        self.assertEqual([s["line"] for s in kinds(res, "table-without-rls")], [1])
        self.assertEqual([s["line"] for s in kinds(res, "secdef-no-search-path")], [5])


class Design(unittest.TestCase):
    def test_versioned_names_and_their_originals(self):
        r = base_repo(self, {"src/ChatView.swift": "struct ChatView {}\n", "src/Household.swift": "class Household {}\n"})
        r.write("src/ChatViewV2.swift", "struct ChatViewV2 {}\nfunc renew() {}\nlet bold = 1\nclass HouseholdOld {}\n"
                "func fetchRowsV2() {}\nlet maxTemp = 3\nfunc makeCopy() {}\nlet isOld = true\nlet ipV6 = 1\n")
        res = r.scan()
        pv = kinds(res, "parallel-version")
        self.assertEqual(sorted(s["line"] for s in pv), [1, 4])
        v2 = [s for s in pv if s["line"] == 1][0]
        self.assertIn("original ChatView still referenced", v2["note"])

    def test_large_file_growth(self):
        r = base_repo(self, {"src/big.py": "".join("x%d = %d\n" % (i, i) for i in range(790))})
        r.write("src/big.py", "".join("x%d = %d\n" % (i, i) for i in range(850)))
        self.assertEqual(len(kinds(r.scan(), "large-file-growing")), 1)

    def test_commented_out_code(self):
        r = base_repo(self)
        r.write("src/a.js", "\n".join([
            "// let total = compute(items);", "// if (total > 10) {", "//   applyDiscount(total);",
            "", "// This explains why the next call exists and what it is for,",
            "// in plain prose that a reader needs.", "// Nothing here is code.",
        ]) + "\n")
        res = r.scan()
        self.assertEqual([s["line"] for s in kinds(res, "commented-out-code")], [1])


class Register(unittest.TestCase):
    def test_touched_and_paid(self):
        r = base_repo(self, {
            "src/a.js": "export const a = 1;\n",
            "docs/tech-debt/chat-v2.md": "---\ntitle: two chat views\nfiles: [src/a.js]\n---\nbody\n",
            "docs/tech-debt/old-thing.md": "---\nfiles:\n  - lib/\n---\nbody\n",
        })
        r.write("src/a.js", "export const a = 2;\n")
        r.remove("docs/tech-debt/old-thing.md")
        res = r.scan()
        self.assertEqual(res["register"]["touched"], [{"entry": "docs/tech-debt/chat-v2.md", "path": "src/a.js"}])
        self.assertEqual(res["register"]["paid"], ["docs/tech-debt/old-thing.md"])


class Collapse(unittest.TestCase):
    def test_repeats_collapse_to_one_signal_with_all_lines(self):
        r = base_repo(self)
        r.write("src/a.ts", "// TODO: one\nconst a = 1;\n// TODO: two\n// TODO: three\n")
        res = r.scan()
        raw = [s for s in res["signals"] if s["kind"] == "satd"]
        self.assertEqual(len(raw), 1)
        self.assertEqual(raw[0]["count"], 3)
        self.assertEqual(raw[0]["lines"], [1, 3, 4])
        self.assertEqual(res["counts"]["code"]["added"], 3)

    def test_version_bump_is_not_a_new_dependency(self):
        r = base_repo(self, {"gradle/libs.versions.toml": "[versions]\nkotlin = \"2.0.0\"\n"})
        r.write("gradle/libs.versions.toml", "[versions]\nkotlin = \"2.1.0\"\nokio = \"3.9.0\"\n")
        res = r.scan()
        self.assertEqual([s["evidence"] for s in kinds(res, "dependency-added")], ['okio = "3.9.0"'])
        changed = kinds(res, "dependency-changed")
        self.assertEqual(len(changed), 1)
        self.assertEqual(changed[0]["direction"], "info")


class ReviewFixes(unittest.TestCase):
    def test_guidance_changes_get_the_judge(self):
        r = base_repo(self)
        r.write(".claude/skills/x/SKILL.md", "".join("Rule %d: always do the thing.\n" % i for i in range(25)))
        res = r.scan()
        self.assertTrue(res["recommend_judge"])
        self.assertEqual(res["measured"]["guidance_changed"], 25)
        r2 = base_repo(self)
        r2.write("docs/notes.md", "".join("Note %d.\n" % i for i in range(25)))
        self.assertFalse(r2.scan()["recommend_judge"])
        r3 = base_repo(self)  # a skill's own script is code, not guidance
        r3.write(".claude/skills/x/scripts/tool.py", "".join("V%d = %d\n" % (i, i) for i in range(25)))
        self.assertEqual(r3.scan()["measured"]["guidance_changed"], 0)

    def test_touched_register_entry_alone_does_not_force_the_judge(self):
        r = base_repo(self, {"src/a.js": "export const a = 1;\n",
                             "docs/tech-debt/a.md": "---\nfiles: [src/a.js]\n---\nx\n"})
        r.write("src/a.js", "export const a = 2;\n")
        res = r.scan()
        self.assertEqual(len(res["register"]["touched"]), 1)
        self.assertFalse(res["recommend_judge"])

    def test_register_entry_whose_files_are_gone_is_stale(self):
        r = base_repo(self, {"src/old.js": "x\n", "docs/tech-debt/old.md": "---\nfiles: [src/old.js, lib/]\n---\nx\n",
                             "docs/tech-debt/live.md": "---\nfiles: [README.md]\n---\nx\n"})
        r.remove("src/old.js")
        res = r.scan()
        self.assertEqual([s["path"] for s in kinds(res, "register-stale")], ["docs/tech-debt/old.md"])

    def test_default_json_lives_in_the_git_dir_and_folders_are_created(self):
        r = base_repo(self)
        r.write("src/a.js", "export const a = 1;\n")
        proc = subprocess.run([sys.executable, SCAN], cwd=r.root, env=r.env, stdout=subprocess.PIPE,
                              stderr=subprocess.PIPE, universal_newlines=True)
        self.assertEqual(proc.returncode, 0, proc.stderr)
        default = os.path.realpath(os.path.join(r.root, ".git", "tech-debt", "scan.json"))  # macOS: /var is /private/var
        self.assertTrue(os.path.exists(default))
        printed = [l[len("json: "):] for l in proc.stdout.splitlines() if l.startswith("json: ")]
        self.assertEqual([os.path.realpath(p) for p in printed], [default])
        self.assertNotIn("tech-debt", r.git("status", "--porcelain"))
        nested = os.path.join(r.dir, "a", "b", "c.json")
        proc = subprocess.run([sys.executable, SCAN, "--json", nested], cwd=r.root, env=r.env,
                              stdout=subprocess.PIPE, stderr=subprocess.PIPE, universal_newlines=True)
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertTrue(os.path.exists(nested))

    def test_duplicate_check_reports_truncation(self):
        sys.path.insert(0, HERE)
        import debt_scan
        r = base_repo(self, {"src/billing.js": FUNC})
        r.write("src/copy.js", FUNC + FUNC.replace("computeTotals", "other"))
        repo = debt_scan.Repo(r.root, r.git("rev-parse", "main").strip(), False)
        files = debt_scan.collect_files(repo, False, "HEAD", repo.base)
        sig = debt_scan.Signals({})
        measured = {}
        debt_scan.check_duplication(sig, repo, files, set(), measured, max_windows=1)
        self.assertTrue(measured["dup_truncated"])
        measured = {}
        debt_scan.check_duplication(sig, repo, files, set(), measured)
        self.assertFalse(measured["dup_truncated"])


class SecondReviewFixes(unittest.TestCase):
    def test_security_rules_reach_config_files_and_secrets_reach_every_text_file(self):
        r = base_repo(self)
        r.write("ios/Info.plist", "<dict>\n<key>NSAllowsArbitraryLoads</key>\n<true/>\n</dict>\n")
        r.write("android/AndroidManifest.xml", '<application android:usesCleartextTraffic="true" android:debuggable="true"/>\n')
        r.write("config/.env.production", "API_TOKEN=ghp_" + "Z9y8X7w6" * 5 + "\n")
        r.write("docs/setup.md", "Use key sk-ant-" + "abcDEF123_" * 3 + " to start.\n")
        r.write("config/plain.json", '{"allowsArbitraryLoads": "documented elsewhere", "debug": false}\n')
        res = r.scan()
        got = sorted((s["kind"], s["path"]) for s in kinds(res) if s["category"] == "security")
        self.assertIn(("tls-off", "ios/Info.plist"), got)
        self.assertIn(("tls-off", "android/AndroidManifest.xml"), got)
        self.assertIn(("perm", "android/AndroidManifest.xml"), got)
        self.assertIn(("secret", "config/.env.production"), got)
        self.assertIn(("secret", "docs/setup.md"), got)
        self.assertFalse([g for g in got if g[1] == "config/plain.json"])
        self.assertNotIn("sk-ant-abc", json.dumps(res))

    def test_any_added_debt_summons_the_judge_even_without_code(self):
        r = base_repo(self, {"package.json": json.dumps({"dependencies": {}})})
        r.write("package.json", json.dumps({"dependencies": {"left-pad": "latest"}}))
        res = r.scan()
        self.assertTrue(res["recommend_judge"], res["reason"])

    def test_deleting_a_register_entry_needs_a_witness(self):
        r = base_repo(self, {"docs/tech-debt/x.md": "---\nfiles: [src/a.js]\n---\nx\n", "src/a.js": "a\n"})
        r.remove("docs/tech-debt/x.md")
        res = r.scan()
        self.assertEqual(res["register"]["paid"], ["docs/tech-debt/x.md"])
        self.assertTrue(res["recommend_judge"])

    def test_old_rot_is_not_blamed_on_an_unrelated_change(self):
        r = base_repo(self, {"docs/tech-debt/rotted.md": "---\nfiles: [src/never-existed.js]\n---\nx\n"})
        r.write("src/new.js", "export const n = 1;\n")
        self.assertFalse(kinds(r.scan(), "register-stale"))

    def test_diff_file_matches_what_was_scanned(self):
        r = base_repo(self, {"src/a.js": "export const a = 1;\n"})
        r.write("src/a.js", "export const a = 2;\n")
        r.commit("f")
        r.write("src/untracked.js", "export const u = 3;\n")
        out = os.path.join(r.dir, "o.json")
        subprocess.run([sys.executable, SCAN, "--json", out], cwd=r.root, env=r.env, check=True, stdout=subprocess.PIPE)
        with open(os.path.join(r.dir, "o.diff")) as fh:
            work = fh.read()
        self.assertIn("+export const a = 2;", work)
        self.assertIn("+export const u = 3;", work)
        subprocess.run([sys.executable, SCAN, "--committed", "--json", out], cwd=r.root, env=r.env, check=True, stdout=subprocess.PIPE)
        with open(os.path.join(r.dir, "o.diff")) as fh:
            committed = fh.read()
        self.assertIn("+export const a = 2;", committed)
        self.assertNotIn("untracked.js", committed)

    def test_stylesheets_do_not_summon_the_judge_by_size(self):
        r = base_repo(self)
        r.write("web/site.css", "".join(".c%d { color: red; }\n" % i for i in range(60)))
        res = r.scan()
        self.assertEqual(res["measured"]["code_added"], 0)
        self.assertFalse(res["recommend_judge"])


def commit_and_scan(r, *extra):
    """Commit the working tree and scan the committed diff, so parse_diff (not the untracked path) runs."""
    r.commit("change")
    return r.scan("--committed", *extra)


class ThirdReviewFixes(unittest.TestCase):
    def test_a_lone_carriage_return_does_not_end_the_hunk(self):
        r = base_repo(self)
        r.write("src/cr.ts", 'const sep = "a\rb";\n// TODO: one\n// FIXME: two\nconst y = x as any;\n')
        res = commit_and_scan(r)
        self.assertEqual(len(kinds(res, "satd")), 2)
        self.assertEqual(len(kinds(res, "suppression")), 1)

    def test_more_secret_shapes_everywhere_and_never_echoed(self):
        r = base_repo(self, {".gitattributes": "dist/** linguist-generated=true\n"})
        jwt = "eyJ" + "a" * 12 + ".eyJ" + "b" * 12 + "." + "c" * 12
        proj = "sk-proj-" + "Q1w2E3r4" * 5
        google = "AIza" + "x" * 35
        r.write("dist/cfg.js", "const k = '%s';\n" % jwt)                       # generated
        r.write("src/opted.js", "// debt-scan: ignore-file\nconst k = '%s';\n" % proj)  # opted out
        r.write("src/todo.js", "// TODO rotate %s\n" % google)
        r.write("docs/a.md", "[token](%s)\n" % ("ghp_" + "A1b2C3d4" * 5))
        res = commit_and_scan(r)
        paths = sorted(s["path"] for s in kinds(res, "secret"))
        self.assertEqual(paths, ["dist/cfg.js", "docs/a.md", "src/opted.js", "src/todo.js"])
        dumped = json.dumps(res) + r.stdout
        for token in (jwt, proj, google, "ghp_" + "A1b2C3d4" * 5):
            self.assertNotIn(token, dumped)

    def test_grants_in_list_form_and_across_lines(self):
        r = base_repo(self)
        r.write("supabase/migrations/2_g.sql", "\n".join([
            "grant execute on function public.f() to authenticated, anon;",
            "grant select on public.t",
            "  to anon;",
            "grant usage on schema public to authenticated;",
            "grant select on public.t to public_reader;",
        ]) + "\n")
        res = commit_and_scan(r)
        self.assertEqual([s["line"] for s in kinds(res, "sql-grant")], [1, 2])

    def test_personal_diff_settings_do_not_change_paths(self):
        r = base_repo(self, {"b/inner.js": "export const a = 1;\n"})
        r.git("config", "diff.mnemonicPrefix", "true")
        r.git("config", "diff.noprefix", "true")
        r.write("b/inner.js", "export const a = 2; // TODO: x\n")
        r.write("calc.js", FUNC)
        res = r.scan()
        self.assertEqual([s["path"] for s in kinds(res, "satd")], ["b/inner.js"])
        self.assertFalse(kinds(res, "duplicate-block"))

    def test_binary_and_mode_only_changes_are_measured(self):
        r = base_repo(self, {"run.sh": "echo hi\n"})
        with open(os.path.join(r.root, "logo.png"), "wb") as fh:
            fh.write(b"\x89PNG\x00\x01binary")
        os.chmod(os.path.join(r.root, "run.sh"), 0o755)
        res = commit_and_scan(r)
        self.assertEqual(res["measured"]["files"], 2)
        self.assertEqual(res["measured"]["binary"], 1)

    def test_head_named_like_a_folder(self):
        r = base_repo(self, {"docs/x.md": "x\n"})
        r.git("checkout", "-q", "-b", "docs")
        r.write("src/a.js", "export const a = 1; // TODO: x\n")
        r.commit("c")
        res = r.scan("--head", "docs", "--base", "main")
        self.assertEqual(len(kinds(res, "satd")), 1)
        self.assertIsNotNone(res["churn_90d"])

    def test_quoted_unicode_paths(self):
        r = base_repo(self)
        r.write('src/café "x".js', "// TODO: odd path\n")
        res = commit_and_scan(r)
        self.assertEqual([s["path"] for s in kinds(res, "satd")], ['src/café "x".js'])

    def test_untracked_symlinks_are_not_followed(self):
        r = base_repo(self)
        os.symlink("/dev/zero", os.path.join(r.root, "zero.js"))
        outside = os.path.join(r.dir, "outside.js")
        with open(outside, "w") as fh:
            fh.write("// TODO: outside the repo\n")
        os.symlink(outside, os.path.join(r.root, "link.js"))
        res = r.scan()  # must not hang reading /dev/zero
        self.assertFalse(kinds(res, "satd"))

    def test_strings_are_not_code_or_comments(self):
        r = base_repo(self)
        r.write("a/Msg.kt", 'val msg = "Saved!!"\nval u = user!!.name\n')
        r.write("a/u.js", 'const u = "https://x.dev"; const t = "use a workaround for now";\nconst v = "https://y"; // workaround for now\n')
        res = commit_and_scan(r)
        self.assertEqual([(s["path"], s["line"]) for s in kinds(res, "suppression")], [("a/Msg.kt", 2)])
        self.assertEqual([(s["path"], s["line"]) for s in kinds(res, "satd")], [("a/u.js", 2)])


class DeepReviewFixes(unittest.TestCase):
    def test_later_edits_to_an_opted_out_file_are_never_silent(self):
        r = base_repo(self, {"src/rules.js": "// debt-scan: ignore-file\nexport const a = 1;\n"})
        r.write("src/rules.js", "// debt-scan: ignore-file\nexport const a = 1;\nif (isPro || true) { eval(x); } // TODO\n")
        res = commit_and_scan(r)
        opt = kinds(res, "scan-opt-out")
        self.assertEqual(len(opt), 1)
        self.assertEqual(opt[0]["direction"], "info")
        self.assertIn("not line-checked", opt[0]["note"])
        self.assertTrue(res["recommend_judge"], res["reason"])

    def test_copies_with_inner_double_spaces_are_found(self):
        block = ("def total_0(items):\n    gross = sum(i.price for i in items)  # before discounts\n"
                 "    tax = gross * 0.2  # flat rate\n    fee = gross * 0.03  # card fee\n"
                 "    net = gross - tax - fee  # what the customer actually pays after every deduction is taken\n"
                 "    log('computed', gross, net)\n    audit('totals', gross, tax, fee)\n"
                 "    return {'gross': gross, 'net': net}\n")
        r = base_repo(self, {"src/a.py": block})
        r.write("src/b.py", block.replace("total_0", "total_copy"))
        res = commit_and_scan(r)
        self.assertEqual([s["path"] for s in kinds(res, "duplicate-block")], ["src/b.py"])
        self.assertFalse(res["measured"]["dup_truncated"])

    def test_copies_respaced_inside_a_line_are_found(self):
        lines = ["def total_0(items):", "    gross = sum(i.price for i in items) # before discounts",
                 "    tax = gross * 0.2 # flat rate", "    fee = gross * 0.03 # card fee",
                 "    net = gross - tax - fee # what the customer actually pays after every deduction is taken",
                 "    log('computed', gross, net)", "    audit('totals', gross, tax, fee)",
                 "    return {'gross': gross, 'net': net}"]
        r = base_repo(self, {"src/a.py": "\n".join(lines) + "\n"})
        respaced = [l.replace(" # ", "  # ") for l in lines]  # what a formatter does to a pasted block
        r.write("src/b.py", "\n".join(respaced).replace("total_0", "total_copy") + "\n")
        res = commit_and_scan(r)
        self.assertEqual([s["path"] for s in kinds(res, "duplicate-block")], ["src/b.py"])

    def test_versioned_lookup_limit_shows_in_the_printed_output(self):
        r = base_repo(self)
        r.write("src/many.js", "".join("function thing%03dV2() {}\n" % i for i in range(27)))
        res = commit_and_scan(r)
        self.assertTrue(res["measured"]["versions_truncated"])
        self.assertIn("versioned-name check TRUNCATED", r.stdout)
        self.assertTrue(all("unconfirmed" in s["note"] for s in kinds(res, "parallel-version")))

    def test_sql_comments_naming_security_definer_are_not_flagged(self):
        r = base_repo(self)
        r.write("supabase/migrations/3_c.sql", "\n".join([
            "-- Only the SECURITY DEFINER RPC below may write this table.",
            "-- create table public.ghost (id int);",
            "create function g() returns void language sql security definer set search_path = '' as $$ select 1 $$;",
        ]) + "\n")
        res = commit_and_scan(r)
        self.assertFalse(kinds(res, "secdef-no-search-path"))
        self.assertFalse(kinds(res, "table-without-rls"))

    def test_deleted_binary_still_counts_as_removed(self):
        r = Repo(self)
        r.write("docs/guide.md", "See web/img/hero.png for the banner.\n")
        os.makedirs(os.path.join(r.root, "web", "img"))
        with open(os.path.join(r.root, "web", "img", "hero.png"), "wb") as fh:
            fh.write(b"\x89PNG\x00binary")
        r.commit("base")
        r.branch()
        r.remove("web/img/hero.png")
        res = commit_and_scan(r)
        self.assertEqual([s["path"] for s in kinds(res, "stale-reference")], ["docs/guide.md"])

    def test_amora_secret_shapes(self):
        r = base_repo(self)
        tokens = ["re_" + "Ab3dE6gH" + "_" + "k" * 24, "sbp_" + "f" * 40, "whsec_" + "Q" * 24]
        r.write("src/keys.js", "".join("const k%d = '%s';\n" % (i, t) for i, t in enumerate(tokens)))
        res = commit_and_scan(r)
        self.assertEqual(len(kinds(res, "secret")), 3)
        for t in tokens:
            self.assertNotIn(t, json.dumps(res) + r.stdout)

    def test_moving_an_entry_out_of_the_register_counts_as_paid(self):
        r = base_repo(self, {"docs/tech-debt/x.md": "---\nfiles: [src/a.js]\n---\nx\n", "src/a.js": "a\n"})
        os.makedirs(os.path.join(r.root, "docs", "archive"))
        r.git("mv", "docs/tech-debt/x.md", "docs/archive/x.md")
        res = commit_and_scan(r)
        self.assertEqual(res["register"]["paid"], ["docs/tech-debt/x.md"])
        self.assertTrue(res["recommend_judge"])

    def test_renaming_or_narrowing_an_entry_inside_the_register_needs_a_witness(self):
        r = base_repo(self, {"docs/tech-debt/retry-in-a.md": "---\ntitle: retry\nfiles: [src/a.js, src/c.js]\n---\nLong body text so git sees a rename.\n",
                             "src/a.js": "a\n"})
        r.git("mv", "docs/tech-debt/retry-in-a.md", "docs/tech-debt/retry-in-b.md")
        r.write("docs/tech-debt/retry-in-b.md", "---\ntitle: retry\nfiles: [src/c.js]\n---\nLong body text so git sees a rename.\n")
        res = commit_and_scan(r)
        self.assertEqual(res["register"]["paid"], ["docs/tech-debt/retry-in-b.md (no longer names src/a.js)"])
        self.assertTrue(res["recommend_judge"])

    def test_dashes_inside_sql_strings_are_not_comments(self):
        r = base_repo(self)
        r.write("supabase/migrations/4_d.sql",
                "create function public.label(p text default '--') returns text language sql security definer as $$ select p $$;\n")
        res = commit_and_scan(r)
        self.assertEqual(len(kinds(res, "secdef-no-search-path")), 1)

    def test_versioned_lookups_cut_short_are_reported_not_dropped(self):
        sys.path.insert(0, HERE)
        import debt_scan
        r = base_repo(self, {"src/a.js": "function fetchRows() {}\nfunction loadThings() {}\n"})
        repo = debt_scan.Repo(r.root, r.git("rev-parse", "main").strip(), False)
        sig = debt_scan.Signals({})
        for name in ("fetchRowsV2", "loadThingsV2"):
            sig.add("parallel-version", "design", "src/b.js", 1, name, note="versioned name: %s" % name)
        debt_scan.annotate_parallel_versions(sig, repo, max_lookups=1)
        self.assertTrue(sig.versions_truncated)
        self.assertEqual(len(sig.items), 2)


class FreshReviewFixes(unittest.TestCase):
    def test_commented_out_rls_does_not_count(self):
        r = base_repo(self)
        r.write("supabase/migrations/5_e.sql", "create table public.secrets (id uuid primary key);\n"
                "-- alter table public.secrets enable row level security;\n")
        res = commit_and_scan(r)
        self.assertEqual([s["line"] for s in kinds(res, "table-without-rls")], [1])

    def test_untracked_diff_ignores_external_diff_tools(self):
        r = base_repo(self)
        marker = os.path.join(r.dir, "EXT_RAN")
        tool = os.path.join(r.dir, "ext.sh")
        with open(tool, "w") as fh:
            fh.write("#!/bin/sh\ntouch %s\necho EXTERNAL\n" % marker)
        os.chmod(tool, 0o755)
        r.git("config", "diff.external", tool)
        r.write("src/new.js", "export const n = 1;\n")
        out = os.path.join(r.dir, "o.json")
        subprocess.run([sys.executable, SCAN, "--json", out], cwd=r.root, env=r.env, check=True, stdout=subprocess.PIPE)
        with open(os.path.join(r.dir, "o.diff")) as fh:
            self.assertIn("+export const n = 1;", fh.read())
        self.assertFalse(os.path.exists(marker))

    def test_register_block_list_stops_at_front_matter(self):
        sys.path.insert(0, HERE)
        import debt_scan
        content = "---\ntitle: x\nfiles:\n  - a/b.py\n---\n- keep both paths\n- old step\n"
        self.assertEqual(debt_scan.register_files(content), ["a/b.py"])
        r = base_repo(self, {"docs/tech-debt/x.md": content, "a/b.py": "x = 1\n"})
        r.write("docs/tech-debt/x.md", content.replace("old step", "new step"))
        res = commit_and_scan(r)
        self.assertEqual(res["register"]["paid"], [])

    def test_register_entries_in_every_shape_keep_their_files(self):
        sys.path.insert(0, HERE)
        import debt_scan
        rf = debt_scan.register_files
        self.assertEqual(rf("files:\n  - a.py\n  - b.py\n\nBody.\n"), ["a.py", "b.py"])          # no front matter
        self.assertEqual(rf("---\r\nfiles:\r\n  - a.py\r\n---\r\nx\r\n"), ["a.py"])            # CRLF
        self.assertEqual(rf("\ufeff---\nfiles: [a.py]\n---\nx\n"), ["a.py"])                     # BOM
        self.assertEqual(rf("---\nfiles: [a.py]\n---\nfiles: [a.py, b.py]\n"), ["a.py"])         # body line ignored
        self.assertEqual(rf("files:\n  - a.py\n\n- body bullet\n"), ["a.py"])
        self.assertEqual(rf("---\n---\nfiles:\n- z.py\n---\n"), [])                              # empty front matter

    def test_removal_only_edit_to_opted_out_file_is_reported(self):
        r = base_repo(self, {"src/rules.py": "# debt-scan: ignore-file\nRULES = [\n    'a',\n    'b',\n]\n"})
        r.write("src/rules.py", "# debt-scan: ignore-file\nRULES = [\n    'a',\n]\n")
        res = commit_and_scan(r)
        self.assertEqual(len(kinds(res, "scan-opt-out")), 1)
        self.assertEqual(kinds(res, "scan-opt-out")[0]["line"], 1)
        self.assertTrue(res["recommend_judge"])

    def test_marker_quoted_inside_a_file_is_not_an_opt_out(self):
        r = base_repo(self)
        r.write("src/fixtures.py", "".join("X%d = 1\n" % i for i in range(35)) + "MARK = '# debt-scan: ignore-file'\n")
        self.assertFalse(kinds(commit_and_scan(r), "scan-opt-out"))


class Modes(unittest.TestCase):
    def test_committed_mode_ignores_uncommitted_and_untracked(self):
        r = base_repo(self, {"src/a.js": "export const a = 1;\n"})
        r.write("src/a.js", "export const a = 2; // TODO: committed\n")
        r.commit("feature")
        r.write("src/new.js", "// TODO: untracked\n")
        r.write("src/a.js", "export const a = 2; // TODO: committed\n// TODO: uncommitted edit\n")
        work = r.scan()
        self.assertEqual(len(kinds(work, "satd")), 3)
        committed = r.scan("--committed")
        self.assertEqual([s["path"] for s in kinds(committed, "satd")], ["src/a.js"])

    def test_head_option_scans_a_branch_without_checking_it_out(self):
        r = base_repo(self, {"src/a.js": "export const a = 1;\n"})
        r.write("src/a.js", "export const a = 2; // TODO: on feature\n")
        r.commit("feature")
        r.git("checkout", "-q", "main")
        r.write("src/scratch.js", "// TODO: local noise on main, must not count\n")
        res = r.scan("--head", "feature", "--base", "main")
        self.assertEqual([s["path"] for s in kinds(res, "satd")], ["src/a.js"])
        self.assertEqual(res["mode"], "committed")
        r.scan("--head", "nope", expect=2)

    def test_empty_change_exits_3_and_bad_base_exits_2(self):
        r = base_repo(self)
        r.scan(expect=3)
        self.assertIn("nothing was measured", r.stderr)
        r.scan("--base", "no-such-branch", expect=2)
        self.assertIn("CANNOT SCAN", r.stderr)

    def test_paths_with_spaces_and_unicode(self):
        r = base_repo(self)
        r.write("src/my file é.js", "// TODO: odd path\n")
        r.commit("x")
        res = r.scan("--committed")
        self.assertEqual([s["path"] for s in kinds(res, "satd")], ["src/my file é.js"])

    def test_generated_files_are_skipped_by_attribute(self):
        r = base_repo(self, {".gitattributes": "gen/** linguist-generated=true\n"})
        r.write("gen/out.js", "// TODO: generated\n")
        res = r.scan()
        self.assertFalse(kinds(res, "satd"))
        self.assertEqual(res["measured"]["generated_skipped"], 1)

    def test_opt_out_is_itself_reported(self):
        r = base_repo(self)
        r.write("src/rules.js", "// debt-scan: ignore-file\n// TODO: hidden\n")
        res = r.scan()
        self.assertFalse(kinds(res, "satd"))
        self.assertEqual(len(kinds(res, "scan-opt-out")), 1)

    def test_judge_recommendation(self):
        r = base_repo(self)
        r.write("docs/x.md", "words\n")
        self.assertFalse(r.scan()["recommend_judge"])
        r.write("src/a.js", "export const a = 1;\n")
        self.assertFalse(r.scan()["recommend_judge"])
        r.write("src/b.js", "".join("export const b%d = %d;\n" % (i, i) for i in range(45)))
        self.assertTrue(r.scan()["recommend_judge"])

    def test_measured_counts_are_positive_when_something_changed(self):
        r = base_repo(self)
        r.write("src/a.js", "export const a = 1;\n")
        res = r.scan()
        self.assertEqual(res["measured"]["files"], 1)
        self.assertEqual(res["measured"]["code_added"], 1)
        self.assertIn("measured: 1 files", r.stdout)

    def test_interest_counts_recent_commits(self):
        r = Repo(self)
        for i in range(11):
            r.write("src/hot.js", "export const v = %d;\n" % i)
            r.write("src/warm.js", "export const w = %d;\n" % (i // 3))
            r.commit("c%d" % i)
        r.branch()
        r.write("src/hot.js", "export const v = 99; // TODO: x\n")
        r.write("src/warm.js", "export const w = 99;\n")
        r.write("src/new.js", "export const n = 1;\n")
        res = r.scan()
        self.assertEqual(res["churn_90d"]["src/hot.js"], 11)
        self.assertEqual(res["churn_90d"]["src/warm.js"], 4)
        self.assertEqual(res["churn_90d"]["src/new.js"], 0)
        self.assertEqual(kinds(res, "satd")[0]["interest"], "high")
        self.assertEqual(res["hot_files"], [{"path": "src/hot.js", "commits_90d": 11}])
        self.assertIn("interest: hot files src/hot.js (11 commits/90d)", r.stdout)

    def test_shallow_clone_reports_unknown_interest(self):
        src = Repo(self)
        for i in range(5):
            src.write("src/a.js", "export const a = %d;\n" % i)
            src.commit("base %d" % i)
        src.branch()
        src.write("src/a.js", "export const a = 9; // TODO: x\n")
        src.commit("f")
        clone = os.path.join(src.dir, "shallow")
        subprocess.run(["git", "clone", "-q", "--depth", "2", "--no-single-branch", "file://" + src.root, clone],
                       env=src.env, check=True)
        shallow = subprocess.run(["git", "rev-parse", "--is-shallow-repository"], cwd=clone, env=src.env,
                                 stdout=subprocess.PIPE, universal_newlines=True).stdout.strip()
        self.assertEqual(shallow, "true")  # precondition: the fixture really is shallow
        out = subprocess.run([sys.executable, SCAN, "--base", "origin/main"], cwd=clone, env=src.env,
                             stdout=subprocess.PIPE, stderr=subprocess.PIPE, universal_newlines=True)
        self.assertEqual(out.returncode, 0, out.stderr)
        self.assertIn("interest: unknown (shallow clone)", out.stdout)

if __name__ == "__main__":
    unittest.main(verbosity=1)
