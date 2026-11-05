// Read or replace App Store Connect assets. Run through `scripts/store-shots.py asc`,
// which prepends `const ARGS`. Without ARGS.apply, write actions only print their plan.
const SLOTS = {
  ipad: { type: "APP_IPAD_PRO_3GEN_129", page: "ipad", input: 0 },
  iphone: { type: "APP_IPHONE_67", page: "iphone", input: 1 },
  duo: { type: "APP_IPHONE_DUO", page: "iphone", input: 2 },
};
const CREATIVE = {
  header: { type: "PRODUCT_PAGE_HEADER_ASSET", tab: "Header" },
  search: { type: "APP_STORE_SEARCH_RESULTS_ASSET", tab: "Search Results" },
};
const TEXT_FIELDS = {
  "whats-new": { attribute: "whatsNew", limit: 4000 },
  promo: { attribute: "promotionalText", limit: 170 },
};
const HEADERS = { "content-type": "application/json", "x-csrf-itc": "[asc-ui]" };
const BASE = `https://appstoreconnect.apple.com/apps/${ARGS.appId}/distribution/ios/version/inflight`;

const task = await taskSpace("heeler store shots asc");
const open = await task.pages();
const page = open.length ? task.page(open[0].label ?? open[0]) : await task.newPage();

const pause = (ms) => page.waitForTimeout(ms);
async function api(path, options) {
  const reply = await page.fetch(`/iris/v1/${path}`, options);
  if (!reply.ok) throw new Error(`${options?.method ?? "GET"} ${path}: ${reply.status} ${reply.body.slice(0, 300)}`);
  return reply.body ? JSON.parse(reply.body) : null;
}
const write = (method, path, data) =>
  api(path, { method, headers: HEADERS, body: data === undefined ? undefined : JSON.stringify({ data }) });

async function goto(url, ready) {
  await page.goto(url);
  for (let i = 0; i < 30; i++) {
    await pause(1000);
    if (ready.test(await page.evaluate(() => document.body.innerText))) return;
  }
  throw new Error(`Page never showed ${ready}: ${url}`);
}

async function findVersion() {
  const list = await api(`apps/${ARGS.appId}/appStoreVersions?limit=10&fields[appStoreVersions]=versionString,appStoreState`);
  const version = list.data.find((v) => v.attributes.versionString === ARGS.version);
  if (!version) throw new Error(`No store version ${ARGS.version}`);
  const locales = await api(`appStoreVersions/${version.id}/appStoreVersionLocalizations?fields[appStoreVersionLocalizations]=locale,whatsNew,promotionalText`);
  const localization = locales.data.find((l) => l.attributes.locale === ARGS.locale);
  if (!localization) throw new Error(`No ${ARGS.locale} localization; found ${locales.data.map((l) => l.attributes.locale)}`);
  return { version, localization, locales: locales.data };
}

async function screenshotSet(localizationId, type) {
  const sets = await api(`appStoreVersionLocalizations/${localizationId}/appScreenshotSets?limit=50`);
  const set = sets.data.find((s) => s.attributes.screenshotDisplayType === type);
  if (!set) throw new Error(`No ${type} set`);
  return set.id;
}
const screenshots = async (setId) =>
  (await api(`appScreenshotSets/${setId}/appScreenshots?limit=20&fields[appScreenshots]=fileName,assetDeliveryState,sourceFileChecksum`))
    .data.map((s) => ({ id: s.id, name: s.attributes.fileName, state: s.attributes.assetDeliveryState?.state }));

async function placements(localizationId) {
  const reply = await api(`appStoreVersionLocalizations/${localizationId}/placements?include=image&limit=500&filter[placementType]=PRODUCT_PAGE_HEADER_ASSET,APP_STORE_SEARCH_RESULTS_ASSET`);
  const images = Object.fromEntries((reply.included ?? []).map((i) => [i.id, i.attributes]));
  return reply.data.map((p) => {
    const image = images[p.relationships.image.data?.id] ?? {};
    return { type: p.attributes.placementType, state: p.attributes.state, name: image.referenceName, size: image.fileSize };
  });
}

async function status({ version, localization, locales }) {
  console.log(`${ARGS.version}: ${version.attributes.appStoreState}`);
  const sets = await api(`appStoreVersionLocalizations/${localization.id}/appScreenshotSets?limit=50`);
  for (const set of sets.data) {
    const rows = await screenshots(set.id);
    console.log(`\n${set.attributes.screenshotDisplayType} (${rows.length})`);
    for (const row of rows) console.log(`  ${row.name}  ${row.state}`);
  }
  console.log("\nCreative");
  for (const row of await placements(localization.id)) console.log(`  ${row.type}  ${row.state}  ${row.name}  ${row.size} bytes`);
  for (const l of locales) {
    console.log(`\nPromotional Text (${l.attributes.locale})\n${l.attributes.promotionalText ?? "(empty)"}`);
    console.log(`\nWhat's New (${l.attributes.locale})\n${l.attributes.whatsNew ?? "(empty)"}`);
  }
}

async function replaceScreenshots({ localization }) {
  const slot = SLOTS[ARGS.target];
  if (!slot) throw new Error(`Screenshot target must be one of ${Object.keys(SLOTS)}`);
  const setId = await screenshotSet(localization.id, slot.type);
  const before = await screenshots(setId);
  const names = ARGS.files.map((f) => f.name);
  const replaced = before.filter((s) => names.includes(s.name));
  const added = names.filter((n) => !before.some((s) => s.name === n));
  const removed = before.filter((s) => ARGS.remove.includes(s.name));
  const absent = ARGS.remove.filter((n) => !before.some((s) => s.name === n) || names.includes(n));
  if (absent.length) throw new Error(`Cannot remove ${absent.join(", ")}: not in the set, or also uploaded`);
  const kept = before.filter((s) => !removed.includes(s));
  if (kept.length + added.length > 10) throw new Error("A set holds at most 10 screenshots");
  const at = ARGS.at ?? kept.length + 1;
  if (at < 1 || at > kept.length + 1) throw new Error(`--at must be between 1 and ${kept.length + 1}`);
  console.log(`${slot.type}: replace ${replaced.map((s) => s.name).join(", ") || "nothing"}; ` +
    `remove ${removed.map((s) => s.name).join(", ") || "nothing"}; add ${added.join(", ") || "nothing"}` +
    (added.length ? ` at position ${at}` : ""));
  if (!ARGS.apply) return console.log("Plan only; pass --apply.");

  for (const old of [...replaced, ...removed]) await write("DELETE", `appScreenshots/${old.id}`);
  await goto(`${BASE}/media-manager/${slot.page}`, /of 10 App Screenshots/);
  await page.evaluate((index) => document.querySelectorAll("input[type=file]")[index].setAttribute("data-store-shots", "1"), slot.input);
  await page.setInputFiles('input[data-store-shots="1"]', ARGS.files.map((f) => f.path));

  const previous = new Set(before.map((s) => s.id));
  let fresh = [];
  for (let i = 0; i < 80; i++) {
    await pause(3000);
    fresh = (await screenshots(setId)).filter((s) => !previous.has(s.id));
    if (fresh.length === names.length && fresh.every((s) => s.state === "COMPLETE")) break;
    if (i === 79) throw new Error(`Uploads did not finish: ${JSON.stringify(fresh)}`);
  }
  // New files take the place of the ones they replace; others go to --at, last by default, in argument order.
  const byName = Object.fromEntries(fresh.map((s) => [s.name, s]));
  const order = kept.map((s) => (names.includes(s.name) ? byName[s.name] : s));
  order.splice(at - 1, 0, ...added.map((n) => byName[n]));
  await write("PATCH", `appScreenshotSets/${setId}/relationships/appScreenshots`, order.map((s) => ({ type: "appScreenshots", id: s.id })));
  console.log((await screenshots(setId)).map((s) => `  ${s.name}  ${s.state}`).join("\n"));
}

async function replaceCreative({ localization }) {
  const slot = CREATIVE[ARGS.target];
  if (!slot) throw new Error(`Creative target must be one of ${Object.keys(CREATIVE)}`);
  if (ARGS.files.length !== 1) throw new Error("Creative takes one file");
  const current = (await placements(localization.id)).find((p) => p.type === slot.type);
  console.log(`${slot.type}: ${current?.name ?? "empty"} -> ${ARGS.files[0].name}`);
  if (!ARGS.apply) return console.log("Plan only; pass --apply.");

  await goto(BASE, /Header and Search Results/);
  await page.evaluate((tab) => [...document.querySelectorAll("[role=tab]")].find((e) => e.innerText.trim() === tab).click(), slot.tab);
  await pause(1500);
  if (current) {
    await page.evaluate(() => {
      const buttons = [...document.querySelectorAll("button")].filter((e) => e.innerText.trim() === "Remove" && e.offsetParent);
      buttons[buttons.length - 1].click();
    });
    await pause(1200);
    await page.evaluate(() => [...document.querySelector("[role=dialog]").querySelectorAll("button")].find((b) => b.innerText.trim() === "Remove").click());
    await pause(2500);
  }
  await page.evaluate(() => [...document.querySelectorAll("input[type=file]")].find((e) => e.accept.includes(".png")).setAttribute("data-store-shots", "1"));
  await page.setInputFiles('input[data-store-shots="1"]', [ARGS.files[0].path]);
  for (let i = 0; i < 60; i++) {
    await pause(3000);
    const row = (await placements(localization.id)).find((p) => p.type === slot.type);
    if (row?.state === "ACTIVE" && row.size === ARGS.files[0].size) return console.log(`  ${row.name}  ACTIVE`);
  }
  throw new Error("The asset never became active");
}

async function setText({ localization }) {
  const { attribute, limit } = TEXT_FIELDS[ARGS.action];
  const fs = process.getBuiltinModule("fs");
  const text = fs.readFileSync(ARGS.files[0].path, "utf8").trim();
  console.log(`${attribute} (${ARGS.locale}), ${text.length} of ${limit} characters:\n${text}`);
  if (text.length > limit) throw new Error(`${attribute} is limited to ${limit} characters`);
  if (!ARGS.apply) return console.log("Plan only; pass --apply.");
  await write("PATCH", `appStoreVersionLocalizations/${localization.id}`, { type: "appStoreVersionLocalizations", id: localization.id, attributes: { [attribute]: text } });
  const saved = await api(`appStoreVersionLocalizations/${localization.id}?fields[appStoreVersionLocalizations]=${attribute}`);
  if (saved.data.attributes[attribute] !== text) throw new Error("Saved text differs");
  console.log("Saved.");
}

try {
  await goto(BASE, /Distribution/);
  const found = await findVersion();
  const action = { status, screenshots: replaceScreenshots, creative: replaceCreative, "whats-new": setText, promo: setText }[ARGS.action];
  await action(found);
} finally {
  await task.finish({ keep: [] });
}
