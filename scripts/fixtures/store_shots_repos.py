"""Throwaway repositories the real Agents work in for store screenshots.

Each entry maps a repository to its commits: (message, {path: text}).
"""

REPOS: dict[str, list[tuple[str, dict[str, str]]]] = {}

GUIDE = """# Working in this repository

Reply in English. Keep changes small and match the existing style.
Run `npm test` before you call a task done, and leave your changes uncommitted
so they can be reviewed.
"""

def write(root, files):
    for rel, text in files.items():
        p = root / rel
        p.parent.mkdir(parents=True, exist_ok=True)
        p.write_text(text.lstrip("\n"))

def git(root, *args):
    env = {**os.environ, "GIT_AUTHOR_NAME": "Demo Developer", "GIT_AUTHOR_EMAIL": "dev@example.com",
           "GIT_COMMITTER_NAME": "Demo Developer", "GIT_COMMITTER_EMAIL": "dev@example.com",
           "LEFTHOOK": "0", "GIT_CONFIG_GLOBAL": "/dev/null"}
    subprocess.run(["git", "-c", "core.hooksPath=/dev/null", *args], cwd=root, env=env, check=True,
                   stdout=subprocess.DEVNULL)

def repo(name, commits):
    root = WS / name
    root.mkdir(parents=True, exist_ok=True)
    git(root, "init", "-q", "-b", "main")
    git(root, "config", "user.name", "Demo Developer")
    git(root, "config", "user.email", "dev@example.com")
    for message, files in commits:
        write(root, files)
        git(root, "add", "-A")
        git(root, "commit", "-q", "-m", message)
    return root

STORE_PKG = """
{
  "name": "storefront",
  "version": "2.4.0",
  "private": true,
  "type": "module",
  "scripts": {
    "dev": "node --watch src/server.js",
    "test": "node --test"
  }
}
"""

REPOS["storefront"] = [
  ("chore: start the storefront", {
    "package.json": STORE_PKG, "CLAUDE.md": GUIDE, "AGENTS.md": GUIDE, ".gitignore": "node_modules\n",
    "README.md": """
# Storefront

The web checkout for our shop. `npm run dev` serves it on port 4321.
""",
    "src/cart.js": """
export class Cart {
  constructor(items = []) {
    this.items = items;
  }

  add(sku, quantity = 1, unitPrice = 0) {
    const line = this.items.find((item) => item.sku === sku);
    if (line) line.quantity += quantity;
    else this.items.push({ sku, quantity, unitPrice });
  }

  get total() {
    return this.items.reduce((sum, item) => sum + item.quantity * item.unitPrice, 0);
  }

  clear() {
    this.items = [];
  }
}
""",
  }),
  ("feat: charge the card at checkout", {
    "src/payments.js": """
export class PaymentDeclined extends Error {
  constructor(code) {
    super(`Payment declined: ${code}`);
    this.code = code;
  }
}

/** A gateway that declines the cards named in `declined`. */
export function gateway({ declined = [] } = {}) {
  return {
    async charge(card, amount) {
      if (declined.includes(card)) throw new PaymentDeclined('card_declined');
      return { id: `ch_${Date.now()}`, amount };
    },
  };
}
""",
    "src/checkout.js": """
import { PaymentDeclined } from './payments.js';

export class Checkout {
  constructor({ cart, gateway, shipping = 'standard', storeCredit = 0 }) {
    this.cart = cart;
    this.gateway = gateway;
    this.shipping = shipping;
    this.storeCredit = storeCredit;
    this.banner = null;
  }

  get amountDue() {
    return Math.max(this.cart.total - this.storeCredit, 0);
  }

  async submit(card) {
    try {
      const receipt = await this.gateway.charge(card, this.amountDue);
      this.cart.clear();
      return { ok: true, receipt };
    } catch (error) {
      if (!(error instanceof PaymentDeclined)) throw error;
      // Start the shopper over so a stale total is never charged.
      this.cart.clear();
      this.shipping = 'standard';
      this.storeCredit = 0;
      this.banner = 'Your payment was declined. Please start again.';
      return { ok: false, code: error.code };
    }
  }
}
""",
    "test/checkout.test.js": """
import assert from 'node:assert/strict';
import { test } from 'node:test';
import { Cart } from '../src/cart.js';
import { Checkout } from '../src/checkout.js';
import { gateway } from '../src/payments.js';

test('a successful payment empties the cart', async () => {
  const cart = new Cart();
  cart.add('mug', 2, 12);
  const checkout = new Checkout({ cart, gateway: gateway() });

  const result = await checkout.submit('4242');

  assert.equal(result.ok, true);
  assert.equal(result.receipt.amount, 24);
  assert.equal(cart.items.length, 0);
});

test('store credit reduces what is charged', async () => {
  const cart = new Cart();
  cart.add('mug', 1, 12);
  const checkout = new Checkout({ cart, gateway: gateway(), storeCredit: 5 });

  const result = await checkout.submit('4242');

  assert.equal(result.receipt.amount, 7);
});
""",
  }),
  ("feat: serve the checkout page", {
    "src/server.js": """
import { createServer } from 'node:http';

const port = Number(process.env.PORT ?? 4321);

createServer((request, response) => {
  console.log(`${new Date().toISOString().slice(11, 19)} ${request.method} ${request.url} 200`);
  response.end('<h1>Storefront</h1>');
}).listen(port, () => {
  console.log(`storefront ready on http://localhost:${port}/`);
});
""",
  }),
]

REPOS["payments-api"] = [
  ("chore: start the payments API", {
    "package.json": """
{
  "name": "payments-api",
  "version": "1.8.2",
  "private": true,
  "type": "module",
  "scripts": { "test": "node --test" }
}
""",
    "CLAUDE.md": GUIDE, "AGENTS.md": GUIDE,
    "README.md": "# Payments API\n\nCharges cards and tells merchants what happened through webhooks.\n",
    "src/webhooks.js": """
/** Sends one event to a merchant's endpoint. */
export async function deliver(event, endpoint, { send = fetch } = {}) {
  const response = await send(endpoint, {
    method: 'POST',
    headers: { 'content-type': 'application/json' },
    body: JSON.stringify(event),
  });
  if (!response.ok) throw new Error(`Webhook failed with ${response.status}`);
  return { delivered: true, attempts: 1 };
}
""",
    "test/webhooks.test.js": """
import assert from 'node:assert/strict';
import { test } from 'node:test';
import { deliver } from '../src/webhooks.js';

test('delivers an event once when the endpoint accepts it', async () => {
  const calls = [];
  const send = async (url, init) => {
    calls.push({ url, init });
    return { ok: true, status: 200 };
  };

  const result = await deliver({ type: 'charge.succeeded' }, 'https://merchant.test/hook', { send });

  assert.deepEqual(result, { delivered: true, attempts: 1 });
  assert.equal(calls.length, 1);
});
""",
  }),
]

REPOS["docs-site"] = [
  ("docs: first version of the guides", {
    "package.json": """
{
  "name": "docs-site",
  "private": true,
  "type": "module",
  "scripts": { "test": "node --test" }
}
""",
    "CLAUDE.md": GUIDE, "AGENTS.md": GUIDE,
    "guides/setup.md": """
# Set up the storefront

1. Install Node 14.
2. Run `yarn install`.
3. Run `yarn start` and open http://localhost:3000.

## Payments

Set `PAYMENTS_URL` to the sandbox before you try a checkout.
""",
    "guides/checkout.md": """
# Checkout

A declined payment empties the cart, and the shopper starts again.
""",
    "test/links.test.js": """
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { test } from 'node:test';

test('the setup guide names the dev command', async () => {
  const guide = await readFile(new URL('../guides/setup.md', import.meta.url), 'utf8');
  assert.match(guide, /npm run dev/);
});
""",
  }),
]

REPOS["search-service"] = [
  ("chore: start the search service", {
    "package.json": """
{
  "name": "search-service",
  "version": "1.3.0",
  "private": true,
  "type": "module",
  "scripts": { "test": "node --test" }
}
""",
    "CLAUDE.md": GUIDE, "AGENTS.md": GUIDE,
    "src/search.js": """
const tokens = (text) => text.toLowerCase().split(/\\W+/).filter(Boolean);

export function search(docs, query) {
  const terms = tokens(query);
  return docs.filter((doc) => terms.every((term) => tokens(doc.title).includes(term)));
}
""",
    "test/search.test.js": """
import test from "node:test";
import assert from "node:assert/strict";
import { search } from "../src/search.js";

const docs = [
  { id: 1, title: "Refund policy" },
  { id: 2, title: "Shipping and refund times" },
];

test("matches every term", () => {
  assert.deepEqual(search(docs, "refund times").map((d) => d.id), [2]);
});
""",
  }),
]

REPOS["inventory-sync"] = [
  ("chore: start inventory sync", {
    "package.json": """
{
  "name": "inventory-sync",
  "version": "1.3.0",
  "private": true,
  "type": "module",
  "scripts": { "test": "node --test" }
}
""",
    "CLAUDE.md": GUIDE, "AGENTS.md": GUIDE,
    "src/stock.js": """
export function applyMovements(stock, movements) {
  const next = { ...stock };
  for (const { sku, delta } of movements) {
    next[sku] = (next[sku] ?? 0) + delta;
  }
  return next;
}
""",
    "test/stock.test.js": """
import test from "node:test";
import assert from "node:assert/strict";
import { applyMovements } from "../src/stock.js";

test("adds deltas per sku", () => {
  assert.deepEqual(applyMovements({ a: 2 }, [{ sku: "a", delta: -1 }, { sku: "b", delta: 3 }]), { a: 1, b: 3 });
});
""",
  }),
]

def node_package(name, version):
    return (f'{{\n  "name": "{name}",\n  "version": "{version}",\n  "private": true,\n'
            '  "type": "module",\n  "scripts": { "test": "node --test" }\n}\n')

REPOS["mobile-app"] = [
  ("chore: start the mobile app", {
    "package.json": node_package("mobile-app", "3.0.2"),
    "CLAUDE.md": GUIDE, "AGENTS.md": GUIDE,
    "src/settings.js": """
export const defaults = { notifications: true, language: "en" };

export function loadSettings(stored = {}) {
  return { ...defaults, ...stored };
}
""",
    "test/settings.test.js": """
import test from "node:test";
import assert from "node:assert/strict";
import { loadSettings } from "../src/settings.js";

test("keeps stored values over defaults", () => {
  assert.equal(loadSettings({ language: "de" }).language, "de");
});
""",
  }),
]

REPOS["analytics"] = [
  ("chore: start analytics", {
    "package.json": node_package("analytics", "0.9.0"),
    "CLAUDE.md": GUIDE, "AGENTS.md": GUIDE,
    "src/events.js": """
export function byUser(events) {
  const users = new Map();
  for (const event of events) {
    if (!users.has(event.user)) users.set(event.user, []);
    users.get(event.user).push(event);
  }
  return users;
}
""",
    "test/events.test.js": """
import test from "node:test";
import assert from "node:assert/strict";
import { byUser } from "../src/events.js";

test("groups events per user", () => {
  assert.equal(byUser([{ user: "a" }, { user: "a" }, { user: "b" }]).get("a").length, 2);
});
""",
  }),
]

REPOS["auth-service"] = [
  ("chore: start the auth service", {
    "package.json": node_package("auth-service", "1.6.1"),
    "CLAUDE.md": GUIDE, "AGENTS.md": GUIDE,
    "src/login.js": """
export function login(users, name, password) {
  const user = users.get(name);
  if (!user || user.password !== password) return { ok: false };
  return { ok: true, user: name };
}
""",
    "test/login.test.js": """
import test from "node:test";
import assert from "node:assert/strict";
import { login } from "../src/login.js";

const users = new Map([["ada", { password: "secret" }]]);

test("accepts the right password", () => {
  assert.equal(login(users, "ada", "secret").ok, true);
});
""",
  }),
]

REPOS["notifications"] = [
  ("chore: start notifications", {
    "package.json": node_package("notifications", "2.2.0"),
    "CLAUDE.md": GUIDE, "AGENTS.md": GUIDE,
    "src/schedule.js": """
export function shouldSend(user, now) {
  return user.enabled !== false;
}
""",
    "test/schedule.test.js": """
import test from "node:test";
import assert from "node:assert/strict";
import { shouldSend } from "../src/schedule.js";

test("respects a disabled user", () => {
  assert.equal(shouldSend({ enabled: false }, new Date()), false);
});
""",
  }),
]

REPOS["admin-dashboard"] = [
  ("chore: start the admin dashboard", {
    "package.json": node_package("admin-dashboard", "1.1.0"),
    "CLAUDE.md": GUIDE, "AGENTS.md": GUIDE,
    "src/orders.js": """
export function totals(orders) {
  return orders.reduce((sum, order) => sum + order.total, 0);
}
""",
    "test/orders.test.js": """
import test from "node:test";
import assert from "node:assert/strict";
import { totals } from "../src/orders.js";

test("sums order totals", () => {
  assert.equal(totals([{ total: 5 }, { total: 7 }]), 12);
});
""",
  }),
]

REPOS["release-cli"] = [
  ("chore: start the release cli", {
    "package.json": node_package("release-cli", "0.4.0"),
    "CLAUDE.md": GUIDE, "AGENTS.md": GUIDE,
    "src/release.js": """
export function nextVersion(version, bump) {
  const [major, minor, patch] = version.split(".").map(Number);
  if (bump === "major") return `${major + 1}.0.0`;
  if (bump === "minor") return `${major}.${minor + 1}.0`;
  return `${major}.${minor}.${patch + 1}`;
}
""",
    "test/release.test.js": """
import test from "node:test";
import assert from "node:assert/strict";
import { nextVersion } from "../src/release.js";

test("bumps the patch by default", () => {
  assert.equal(nextVersion("1.2.3"), "1.2.4");
});
""",
  }),
]
