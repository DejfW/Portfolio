"""Mini calibration tasks: small, objectively checkable, one per router category.
Each task has starting `files`, an agent `prompt`, a `check(dir)` and a reference `solution`
(used only by `--selfcheck` to prove the check itself is sound)."""
import subprocess


def sh(d, cmd):
    r = subprocess.run(cmd, shell=True, cwd=d, capture_output=True, text=True, timeout=60)
    return r.returncode == 0, (r.stdout + r.stderr)[-400:]


def py(d, code):
    return sh(d, "python3 -c " + repr(code))


CALC = '''def clamp(x, lo, hi):
    if lo > hi:
        raise ValueError("lo > hi")
    return max(lo, min(x, hi))


def mean(xs):
    if not xs:
        raise ValueError("empty")
    return sum(xs) / len(xs)
'''
REPORT = '''def build_report(lines):
    out = []
    total = 0
    for line in lines:
        parts = line.split(",")
        if len(parts) != 2:
            continue
        name, qty = parts[0].strip(), parts[1].strip()
        if not qty.isdigit() or not name:
            continue
        total += int(qty)
        out.append(f"{name}: {int(qty)}")
    out.append(f"TOTAL: {total}")
    return "\\n".join(out)
'''


def check_tests(d):
    ok, out = sh(d, "python3 -m unittest -v test_calc 2>&1")
    n = out.count(" ... ok")
    if not ok or n < 4:
        return False, f"own tests must pass and be >=4 (ok={ok}, n={n})"
    for old, new in (("max(lo, min(x, hi))", "min(x, hi)"), ('raise ValueError("empty")', "return 0")):
        src = open(f"{d}/calc.py").read()
        open(f"{d}/calc.py", "w").write(src.replace(old, new))
        survived, _ = sh(d, "python3 -m unittest test_calc 2>&1")
        open(f"{d}/calc.py", "w").write(src)
        if survived:
            return False, f"tests did not catch mutant: {new}"
    return True, "tests pass and kill both mutants"


def check_ui(d):
    from html.parser import HTMLParser
    try:
        src = open(f"{d}/index.html").read()
    except OSError:
        return False, "no index.html"
    seen = {"ids": set(), "tags": set()}

    class P(HTMLParser):
        def handle_starttag(self, tag, attrs):
            seen["tags"].add(tag)
            seen["ids"].update(v for k, v in attrs if k == "id")
    P().feed(src)
    need = {"new-todo", "add", "list"}
    ok = need <= seen["ids"] and {"script", "style", "h1"} <= seen["tags"] and \
        ("addEventListener" in src or "onclick" in src)
    return ok, f"ids={sorted(seen['ids'])} tags={sorted(seen['tags'])}"


TASKS = [
    dict(id="simple", category="simple", difficulty="easy", files={},
         prompt="Create a .gitignore for a Python project that ignores __pycache__/, *.pyc and .venv/.",
         check=lambda d: sh(d, "grep -q __pycache__ .gitignore && grep -q '\\.pyc' .gitignore && grep -q '\\.venv' .gitignore"),
         solution={".gitignore": "__pycache__/\n*.pyc\n.venv/\n"}),
    dict(id="implement", category="implement", difficulty="medium", files={},
         prompt="Create slug.py with slugify(text): lowercase, strip accents (use unicodedata), collapse every run "
                "of non-alphanumeric characters into a single '-', and no leading/trailing '-'.",
         check=lambda d: py(d, "from slug import slugify as s; assert s('Hello, World!')=='hello-world'; "
                               "assert s('  Café Déjà vu ')=='cafe-deja-vu'; assert s('--a__b--')=='a-b'; assert s('')==''"),
         solution={"slug.py": "import re, unicodedata\n\n\ndef slugify(text):\n    t = unicodedata.normalize('NFKD', text)"
                              ".encode('ascii', 'ignore').decode().lower()\n    return re.sub(r'[^a-z0-9]+', '-', t).strip('-')\n"}),
    dict(id="debug", category="debug", difficulty="medium",
         files={"pager.py": "def paginate(items, page, size):\n    return items[page * size:page * size + size]\n"},
         prompt="paginate(items, page, size) in pager.py is meant to use 1-based pages but page 1 returns the second "
                "page. Fix the bug without changing the signature.",
         check=lambda d: py(d, "from pager import paginate as p; x=list(range(10)); assert p(x,1,3)==[0,1,2]; "
                               "assert p(x,4,3)==[9]; assert p(x,5,3)==[]"),
         solution={"pager.py": "def paginate(items, page, size):\n    return items[(page - 1) * size:page * size]\n"}),
    dict(id="tests", category="tests", difficulty="medium", files={"calc.py": CALC},
         prompt="Write test_calc.py (unittest) for calc.py: at least 4 tests covering clamp (below, inside, above, "
                "lo > hi raises ValueError) and mean (normal case, empty list raises ValueError). Do not change calc.py.",
         check=check_tests,
         solution={"test_calc.py": "import unittest\nfrom calc import clamp, mean\n\n\nclass T(unittest.TestCase):\n"
                   "    def test_below(self): self.assertEqual(clamp(-5, 0, 10), 0)\n"
                   "    def test_inside(self): self.assertEqual(clamp(5, 0, 10), 5)\n"
                   "    def test_above(self): self.assertEqual(clamp(50, 0, 10), 10)\n"
                   "    def test_bad_range(self):\n        with self.assertRaises(ValueError): clamp(1, 5, 0)\n"
                   "    def test_mean(self): self.assertEqual(mean([1, 2, 3]), 2)\n"
                   "    def test_mean_empty(self):\n        with self.assertRaises(ValueError): mean([])\n"}),
    dict(id="refactor", category="refactor", difficulty="hard", files={"report.py": REPORT},
         prompt="Refactor report.py: split build_report(lines) into parse_row(line) -> (name, qty_str) or None when the "
                "line does not have exactly 2 comma-separated fields; validate(name, qty_str) -> bool (name non-empty, "
                "qty all digits); and format_report(rows) -> str where rows is a list of (name, int). Keep build_report's "
                "output byte-for-byte identical and keep using it as the entry point.",
         check=lambda d: py(d, "import report as r; assert r.parse_row('a, 3')==('a','3'); assert r.parse_row('bad') is None; "
                               "assert r.validate('a','3') is True; assert r.validate('','3') is False; assert r.validate('a','x') is False; "
                               "assert r.format_report([('a',3),('b',4)])=='a: 3\\nb: 4\\nTOTAL: 7'; "
                               "assert r.build_report(['a, 3','bad','b,4','c,x'])=='a: 3\\nb: 4\\nTOTAL: 7'"),
         solution={"report.py": 'def parse_row(line):\n    p = line.split(",")\n    return (p[0].strip(), p[1].strip()) if len(p) == 2 else None\n\n\n'
                   'def validate(name, qty):\n    return bool(name) and qty.isdigit()\n\n\n'
                   'def format_report(rows):\n    out = [f"{n}: {q}" for n, q in rows]\n    out.append(f"TOTAL: {sum(q for _, q in rows)}")\n    return "\\n".join(out)\n\n\n'
                   'def build_report(lines):\n    rows = []\n    for l in lines:\n        r = parse_row(l)\n        if r and validate(*r):\n            rows.append((r[0], int(r[1])))\n    return format_report(rows)\n'}),
    dict(id="ui", category="ui", difficulty="medium", files={},
         prompt="Create index.html: an h1 'Todo', a text input id='new-todo', a button id='add', and an empty ul id='list'. "
                "Inline <style> and inline <script>: clicking the button appends the input text as an li to the list and clears the input.",
         check=check_ui,
         solution={"index.html": "<!doctype html><html><head><style>body{font:16px sans-serif}</style></head><body><h1>Todo</h1>"
                   "<input id='new-todo'><button id='add'>Add</button><ul id='list'></ul><script>"
                   "document.getElementById('add').addEventListener('click',()=>{const i=document.getElementById('new-todo');"
                   "const li=document.createElement('li');li.textContent=i.value;document.getElementById('list').appendChild(li);i.value=''})"
                   "</script></body></html>"}),
]


# ---------------------------------------------------------------------------------------------
# Harder set: multi-file, subtle bugs, strict specs. The checks use hidden scenarios beyond what the
# prompt shows, so special-casing the visible example does not pass.
import os, tempfile


def script(d, code):
    f = tempfile.NamedTemporaryFile("w", suffix=".py", delete=False)
    f.write(code)
    f.close()
    try:
        r = subprocess.run(["python3", f.name], cwd=d, env={**os.environ, "PYTHONPATH": str(d)},
                           capture_output=True, text=True, timeout=60)
    finally:
        os.unlink(f.name)
    return r.returncode == 0, (r.stdout + r.stderr)[-400:]


LRU_BUGGY = '''class LRU:
    def __init__(self, cap):
        self.cap = cap
        self.d = {}
        self.order = []

    def get(self, k):
        if k not in self.d:
            return None
        return self.d[k]

    def put(self, k, v):
        if k in self.d:
            self.d[k] = v
            return
        if len(self.d) >= self.cap:
            old = self.order.pop(0)
            del self.d[old]
        self.d[k] = v
        self.order.append(k)

    def __len__(self):
        return len(self.d)
'''
LRU_TEST = '''import unittest
from lru import LRU


class T(unittest.TestCase):
    def test_get_refreshes(self):
        c = LRU(2)
        c.put("a", 1)
        c.put("b", 2)
        c.get("a")
        c.put("c", 3)
        self.assertIsNone(c.get("b"))
        self.assertEqual(c.get("a"), 1)
'''
LRU_FIXED = '''from collections import OrderedDict


class LRU:
    def __init__(self, cap):
        self.cap = cap
        self.d = OrderedDict()

    def get(self, k):
        if k not in self.d:
            return None
        self.d.move_to_end(k)
        return self.d[k]

    def put(self, k, v):
        if k in self.d:
            self.d.move_to_end(k)
        self.d[k] = v
        if len(self.d) > self.cap:
            self.d.popitem(last=False)

    def __len__(self):
        return len(self.d)
'''
LRU_HIDDEN = '''from lru import LRU
c = LRU(2); c.put("a", 1); c.put("b", 2); c.put("a", 10); c.put("c", 3)
assert c.get("b") is None and c.get("a") == 10 and c.get("c") == 3, "put on existing key must refresh"
c = LRU(3)
for k in "abc": c.put(k, k)
c.get("a"); c.get("b"); c.put("d", "d")
assert c.get("c") is None and len(c) == 3, "evicts least recently used"
c = LRU(1); c.put("x", 1); c.put("y", 2)
assert c.get("x") is None and c.get("y") == 2 and len(c) == 1
assert LRU(2).get("nope") is None
'''
PRICING = 'from decimal import Decimal\n\nPRICES = {"A": Decimal("50.00"), "B": Decimal("55.05"), "C": Decimal("10.00")}\n'
INVENTORY = '''class OutOfStock(Exception):
    pass


STOCK = {"A": 5, "B": 5, "C": 1}


def reserve(sku, qty):
    if STOCK.get(sku, 0) < qty:
        raise OutOfStock(sku)
    STOCK[sku] -= qty


def release(sku, qty):
    STOCK[sku] += qty
'''
CHECKOUT_FIXED = '''from decimal import Decimal, ROUND_HALF_UP
import inventory
from pricing import PRICES


def checkout(items, coupon=None):
    if coupon not in (None, "SAVE10"):
        raise ValueError(coupon)
    done = []
    try:
        for sku, qty in items:
            PRICES[sku]
            inventory.reserve(sku, qty)
            done.append((sku, qty))
    except Exception:
        for sku, qty in done:
            inventory.release(sku, qty)
        raise
    subtotal = sum((PRICES[s] * q for s, q in items), Decimal(0))
    total = subtotal * Decimal("0.9") if coupon == "SAVE10" and subtotal >= 100 else subtotal
    return total.quantize(Decimal("0.01"), rounding=ROUND_HALF_UP)
'''
CHECKOUT_HIDDEN = '''from decimal import Decimal
import inventory
from checkout import checkout
def reset(): inventory.STOCK.update({"A": 5, "B": 5, "C": 1})
def stock(): return dict(inventory.STOCK)
reset()
assert checkout([("A", 1), ("B", 1)], "SAVE10") == Decimal("94.55"), "half-up rounding of 94.545"
assert stock() == {"A": 4, "B": 4, "C": 1}
reset(); assert checkout([("A", 1)], "SAVE10") == Decimal("50.00"), "no discount below 100"
reset(); assert checkout([("A", 2)], "SAVE10") == Decimal("90.00")
reset()
for items, exc in ((([("A", 2), ("C", 2)]), inventory.OutOfStock), (([("A", 1), ("Z", 1)]), KeyError)):
    try: checkout(items)
    except exc: pass
    else: raise AssertionError("expected " + exc.__name__)
    assert stock() == {"A": 5, "B": 5, "C": 1}, "failed checkout must roll back reservations"
try: checkout([("A", 1)], "BOGUS")
except ValueError: pass
else: raise AssertionError("unknown coupon must raise ValueError")
assert stock() == {"A": 5, "B": 5, "C": 1}
'''
DURATION_FIXED = '''import re

_RE = re.compile(r"(?:([0-9]+)d)?(?:([0-9]+)h)?(?:([0-9]+)m)?(?:([0-9]+)s)?")


def parse_duration(s):
    m = _RE.fullmatch(s)
    if not s or not m:
        raise ValueError(s)
    d, h, mi, sec = (int(x or 0) for x in m.groups())
    return d * 86400 + h * 3600 + mi * 60 + sec
'''
DURATION_HIDDEN = '''from duration import parse_duration as p
ok = {"90s": 90, "1h30m15s": 5415, "1d": 86400, "0s": 0, "2d3h": 183600, "10m": 600, "1d1h1m1s": 90061}
for s, v in ok.items(): assert p(s) == v, (s, p(s))
for bad in ["", "1.5h", "h", "5", " 1h", "1h ", "30m1h", "1h1h", "1H", "-1s", "1h\\n", "\\uff11h", "1s1m", "1h-2m"]:
    try: p(bad)
    except ValueError: continue
    raise AssertionError("should reject " + repr(bad))
'''
STORE = '''import os


def get_user(conn, name):
    return conn.execute(f"SELECT id, name FROM users WHERE name = '{name}'").fetchall()


def read_upload(base_dir, filename):
    with open(os.path.join(base_dir, filename), "rb") as f:
        return f.read()
'''
STORE_FIXED = '''import os


def get_user(conn, name):
    return conn.execute("SELECT id, name FROM users WHERE name = ?", (name,)).fetchall()


def read_upload(base_dir, filename):
    base = os.path.realpath(base_dir)
    path = os.path.realpath(os.path.join(base, filename))
    if os.path.commonpath([base, path]) != base:
        raise ValueError("path escapes base_dir")
    with open(path, "rb") as f:
        return f.read()
'''
STORE_HIDDEN = '''import os, sqlite3, tempfile
from store import get_user, read_upload
conn = sqlite3.connect(":memory:")
conn.execute("CREATE TABLE users (id INTEGER, name TEXT)")
conn.executemany("INSERT INTO users VALUES (?, ?)", [(1, "alice"), (2, "bob")])
assert get_user(conn, "alice") == [(1, "alice")]
assert get_user(conn, "' OR '1'='1") == [], "injection must not match rows"
assert get_user(conn, "x'; DROP TABLE users; --") == []
assert conn.execute("SELECT COUNT(*) FROM users").fetchone()[0] == 2
assert get_user(conn, "o'brien") == []
root = tempfile.mkdtemp(); base = os.path.join(root, "up"); os.makedirs(os.path.join(base, "sub"))
open(os.path.join(base, "a.txt"), "w").write("A"); open(os.path.join(base, "sub", "b.txt"), "w").write("B")
open(os.path.join(root, "secret.txt"), "w").write("S")
os.symlink(os.path.join(root, "secret.txt"), os.path.join(base, "link.txt"))
assert read_upload(base, "a.txt") == b"A" and read_upload(base, "sub/b.txt") == b"B"
for bad in ["../secret.txt", "sub/../../secret.txt", os.path.join(root, "secret.txt"), "link.txt"]:
    try: read_upload(base, bad)
    except ValueError: continue
    raise AssertionError("should refuse " + bad)
'''
MODELS = '''class User:
    def __init__(self, name):
        self.name = name
        self._orders = []

    @property
    def orders(self):
        return list(self._orders)

    def total_spent(self):
        return sum(o.amount for o in self._orders)


class Order:
    def __init__(self, user, amount):
        if amount <= 0:
            raise ValueError("amount must be positive")
        self.user = user
        self.amount = amount
        user._orders.append(self)


def top_customer(users):
    return max(users, key=lambda u: u.total_spent()) if users else None
'''
SPLIT_HIDDEN = '''import os
assert not os.path.exists("models.py"), "models.py must be deleted"
assert os.path.isfile("models/user.py") and os.path.isfile("models/order.py") and os.path.isfile("models/__init__.py")
from models import User, Order, top_customer
from models.user import User as U2
from models.order import Order as O2
assert User is U2 and Order is O2
a, b = User("a"), User("b")
o = Order(a, 5); Order(b, 9); Order(a, 3)
assert a.orders[0] is o and a.total_spent() == 8 and top_customer([a, b]) is b and top_customer([]) is None
try: Order(a, 0)
except ValueError: pass
else: raise AssertionError("amount validation lost")
'''


def check_lru(d):
    ok, out = sh(d, "python3 -m unittest test_lru 2>&1")
    if not ok:
        return False, "provided test still fails: " + out[-200:]
    return script(d, LRU_HIDDEN)


HARD = [
    dict(id="h_debug", category="debug", difficulty="hard",
         files={"lru.py": LRU_BUGGY, "test_lru.py": LRU_TEST},
         prompt="test_lru.py fails against lru.py. Fix lru.py (do NOT edit test_lru.py). The cache must evict the least "
                "recently used key, where both get() and put() (including put on an existing key) count as a use. "
                "Keep the public interface: LRU(cap), get(k) -> value or None, put(k, v), len().",
         check=check_lru, solution={"lru.py": LRU_FIXED}),
    dict(id="h_checkout", category="implement", difficulty="hard",
         files={"pricing.py": PRICING, "inventory.py": INVENTORY},
         prompt="Create checkout.py with checkout(items, coupon=None) -> Decimal. items is a list of (sku, qty). Rules: "
                "reserve every item with inventory.reserve in order; if anything fails (OutOfStock from reserve, KeyError "
                "for an unknown sku in pricing.PRICES) release everything already reserved and re-raise, so stock changes "
                "only on success. subtotal = sum(price * qty) as Decimal. coupon 'SAVE10' gives 10% off only when the "
                "subtotal is >= 100; any other non-None coupon raises ValueError and must leave stock untouched. Round the "
                "result to cents with ROUND_HALF_UP. Do not modify pricing.py or inventory.py.",
         check=lambda d: script(d, CHECKOUT_HIDDEN), solution={"checkout.py": CHECKOUT_FIXED}),
    dict(id="h_duration", category="implement", difficulty="hard", files={},
         prompt="Create duration.py with parse_duration(s) -> int seconds. Grammar: one or more '<digits><unit>' parts "
                "with units d, h, m, s, in that strict descending order, each unit at most once, no spaces or other "
                "characters, ASCII digits only, lowercase units only. 'd'=86400s, 'h'=3600s, 'm'=60s. Anything else "
                "(empty string, '1.5h', '5', ' 1h', '30m1h', '1h1h', '1H', negative numbers, trailing newline, non-ASCII "
                "digits) raises ValueError. Examples: '90s' -> 90, '1h30m15s' -> 5415, '0s' -> 0.",
         check=lambda d: script(d, DURATION_HIDDEN), solution={"duration.py": DURATION_FIXED}),
    dict(id="h_security", category="review", difficulty="hard", files={"store.py": STORE},
         prompt="store.py has two security vulnerabilities. Fix both without changing the function signatures or the "
                "normal behaviour: get_user(conn, name) must not be SQL-injectable; read_upload(base_dir, filename) must "
                "raise ValueError for any filename that resolves outside base_dir (../ sequences, absolute paths, symlinks "
                "pointing outside) while still allowing normal files and files in subdirectories.",
         check=lambda d: script(d, STORE_HIDDEN), solution={"store.py": STORE_FIXED}),
    dict(id="h_split", category="refactor", difficulty="hard", files={"models.py": MODELS},
         prompt="Convert the module models.py into a package models/: User in models/user.py, Order in models/order.py, "
                "top_customer in models/__init__.py, which must also re-export User and Order so that "
                "'from models import User, Order, top_customer' keeps working. Behaviour must not change. Delete models.py.",
         check=lambda d: script(d, SPLIT_HIDDEN),
         solution={"models.py": None, "models/__init__.py": "from .user import User\nfrom .order import Order\n\n\n"
                   "def top_customer(users):\n    return max(users, key=lambda u: u.total_spent()) if users else None\n",
                   "models/user.py": MODELS.split("class Order")[0].rstrip() + "\n",
                   "models/order.py": "class Order:\n    def __init__(self, user, amount):\n        if amount <= 0:\n"
                   "            raise ValueError(\"amount must be positive\")\n        self.user = user\n"
                   "        self.amount = amount\n        user._orders.append(self)\n"}),
]
ALL = TASKS + HARD
