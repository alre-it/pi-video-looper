// Upload page + playlist server for the signage Pis.
//
// People upload videos/images here and give each one a "show from" / "show
// until" window and the screens it belongs on. Each Pi polls
// GET /api/screens/<name>/manifest every two minutes (bin/sync-media.sh) and
// mirrors the files that are currently active. Nothing runs on a schedule to
// expire content: an item simply drops out of the manifest once its window
// has passed, and the Pi deletes its local copy on the next sync.
//
// State is two JSON files plus a directory of uploaded files under DATA_DIR.
// A stored file never changes for a given id, so the id doubles as the
// version the Pis compare against.
"use strict";

const crypto = require("crypto");
const fs = require("fs");
const os = require("os");
const path = require("path");
const express = require("express");
const multer = require("multer");

const PORT = Number(process.env.PORT || 8300);
const DATA_DIR = process.env.DATA_DIR || path.join(os.homedir(), "bermon-upload-data");
const FILES_DIR = path.join(DATA_DIR, "files");
const ITEMS_FILE = path.join(DATA_DIR, "items.json");
const SETTINGS_FILE = path.join(DATA_DIR, "settings.json");
const SCREENS = (process.env.SCREENS || "bermon01,bermon02").split(",").map((s) => s.trim()).filter(Boolean);
// Display names for the page; the Pis keep using their hostnames as ids.
// SCREEN_LABELS="bermon01=Eingang,bermon02=Pausenraum EG"
const SCREEN_LABELS = Object.fromEntries(
  (process.env.SCREEN_LABELS || "").split(",").map((pair) => pair.split("=").map((s) => s.trim())).filter(([id, label]) => id && label),
);
const AUTH_USER = process.env.AUTH_USER || "";
const AUTH_PASS = process.env.AUTH_PASS || "";
// Expired items stay listed (so the window can be extended) and are removed
// for good this many days after their "show until".
const PURGE_DAYS = Number(process.env.PURGE_DAYS || 30);
const MAX_UPLOAD_BYTES = Number(process.env.MAX_UPLOAD_MB || 2048) * 1024 * 1024;
const DEFAULT_IMAGE_DURATION = 240;

// Must match the extensions build-playlist.sh picks up on the Pi.
const ALLOWED_EXT = new Set([".mp4", ".mkv", ".mov", ".webm", ".jpg", ".jpeg", ".png", ".gif"]);

fs.mkdirSync(FILES_DIR, { recursive: true });

// ---------------------------------------------------------------- storage

function readJson(file, fallback) {
  try {
    return JSON.parse(fs.readFileSync(file, "utf8"));
  } catch (err) {
    if (err.code === "ENOENT") return fallback;
    throw err;
  }
}

function writeJson(file, value) {
  const tmp = `${file}.${process.pid}.tmp`;
  fs.writeFileSync(tmp, JSON.stringify(value, null, 2) + "\n");
  fs.renameSync(tmp, file);
}

let items = readJson(ITEMS_FILE, []);
let settings = { imageDuration: DEFAULT_IMAGE_DURATION, ...readJson(SETTINGS_FILE, {}) };

const saveItems = () => writeJson(ITEMS_FILE, items);
const saveSettings = () => writeJson(SETTINGS_FILE, settings);

// ---------------------------------------------------------------- helpers

function newId() {
  // Sortable by upload time, unique enough for a handful of uploads a day.
  return `${Date.now().toString(36)}-${crypto.randomBytes(4).toString("hex")}`;
}

// Keep the original name recognisable on the Pi (the playlist is sorted by
// file name), but strip anything that could break a path or the tab-separated
// manifest.
function safeName(name) {
  const base = path.basename(String(name || "")).normalize("NFC");
  const cleaned = base.replace(/[\x00-\x1f\x7f/\\]+/g, "_").replace(/^\.+/, "_").trim();
  return cleaned.slice(0, 200) || "datei";
}

// Accepts an ISO string or a local "YYYY-MM-DDTHH:MM"; empty means unset.
function parseWhen(value) {
  if (value === undefined || value === null || value === "") return null;
  const d = new Date(value);
  if (Number.isNaN(d.getTime())) throw badRequest("Ungültiges Datum");
  return d.toISOString();
}

function parseScreens(value) {
  const list = Array.isArray(value) ? value : String(value || "").split(",");
  const chosen = [...new Set(list.map((s) => String(s).trim()).filter(Boolean))];
  const unknown = chosen.filter((s) => !SCREENS.includes(s));
  if (unknown.length) throw badRequest(`Unbekannter Bildschirm: ${unknown.join(", ")}`);
  if (!chosen.length) throw badRequest("Mindestens ein Bildschirm");
  return SCREENS.filter((s) => chosen.includes(s));
}

function badRequest(message) {
  const err = new Error(message);
  err.status = 400;
  return err;
}

function status(item, now = Date.now()) {
  if (item.enabled === false) return "deaktiviert";
  if (item.showFrom && now < Date.parse(item.showFrom)) return "geplant";
  if (item.showUntil && now >= Date.parse(item.showUntil)) return "abgelaufen";
  return "aktiv";
}

function isActive(item, screen, now = Date.now()) {
  return item.screens.includes(screen) && status(item, now) === "aktiv";
}

function withStatus(item) {
  return { ...item, status: status(item), url: `/media/${item.id}` };
}

function findItem(id) {
  const item = items.find((i) => i.id === id);
  if (!item) {
    const err = new Error("Nicht gefunden");
    err.status = 404;
    throw err;
  }
  return item;
}

function removeItem(item) {
  items = items.filter((i) => i !== item);
  saveItems();
  fs.rm(path.join(FILES_DIR, item.storedName), { force: true }, (err) => {
    if (err) console.error(`could not delete ${item.storedName}:`, err.message);
  });
}

function purgeExpired() {
  const cutoff = Date.now() - PURGE_DAYS * 86400 * 1000;
  for (const item of items.filter((i) => i.showUntil && Date.parse(i.showUntil) < cutoff)) {
    console.log(`purging ${item.name} (expired ${item.showUntil})`);
    removeItem(item);
  }
}

// Names the Pi will use. Two items may carry the same original name, so the
// second one gets the id appended before the extension.
function manifestNames(list) {
  const seen = new Set();
  return list.map((item) => {
    let name = item.name;
    if (seen.has(name)) {
      const ext = path.extname(name);
      name = `${name.slice(0, name.length - ext.length)}-${item.id}${ext}`;
    }
    seen.add(name);
    return [item, name];
  });
}

// ---------------------------------------------------------------- app

const app = express();
app.disable("x-powered-by");
app.set("etag", false);

function basicAuth(req, res, next) {
  if (!AUTH_PASS) return next();
  const header = req.get("authorization") || "";
  const [scheme, encoded] = header.split(" ");
  if (scheme === "Basic" && encoded) {
    const [user, ...rest] = Buffer.from(encoded, "base64").toString().split(":");
    const pass = rest.join(":");
    const same = (a, b) => a.length === b.length && crypto.timingSafeEqual(Buffer.from(a), Buffer.from(b));
    if (same(user, AUTH_USER) && same(pass, AUTH_PASS)) return next();
  }
  res.set("WWW-Authenticate", 'Basic realm="Bermon Upload", charset="UTF-8"');
  res.status(401).send("Anmeldung erforderlich");
}

// --- consumed by the Pis: no auth, no caching

app.get("/api/screens/:screen/manifest", (req, res) => {
  const { screen } = req.params;
  if (!SCREENS.includes(screen)) return res.status(404).type("text").send("unknown screen\n");
  const now = Date.now();
  const active = items.filter((i) => isActive(i, screen, now));
  const lines = [`#IMAGE_DISPLAY_DURATION=${settings.imageDuration}`];
  for (const [item, name] of manifestNames(active)) lines.push(`${item.id}\t${name}`);
  res.set("Cache-Control", "no-store").type("text").send(lines.join("\n") + "\n");
});

app.get("/media/:id", (req, res, next) => {
  const item = items.find((i) => i.id === req.params.id);
  if (!item) return res.status(404).type("text").send("not found\n");
  res.set("Cache-Control", "no-store");
  res.sendFile(path.join(FILES_DIR, item.storedName), (err) => err && next(err));
});

app.get("/healthz", (req, res) => res.type("text").send("ok\n"));

// --- the upload page and its API

app.use(basicAuth);
app.use(express.static(path.join(__dirname, "public"), { etag: false, lastModified: false, cacheControl: false }));
app.use(express.json());

app.get("/api/config", (req, res) =>
  res.json({ screens: SCREENS.map((id) => ({ id, label: SCREEN_LABELS[id] || id })), settings, purgeDays: PURGE_DAYS }),
);

app.get("/api/items", (req, res) => {
  const now = Date.now();
  const order = { aktiv: 0, geplant: 1, deaktiviert: 2, abgelaufen: 3 };
  const list = items.map(withStatus).sort((a, b) => {
    const s = order[status(a, now)] - order[status(b, now)];
    return s || a.name.localeCompare(b.name, "de", { numeric: true });
  });
  res.json(list);
});

const upload = multer({
  storage: multer.diskStorage({
    destination: FILES_DIR,
    filename: (req, file, cb) => {
      const ext = path.extname(file.originalname || "").toLowerCase();
      cb(null, `${newId()}${ext}`);
    },
  }),
  limits: { fileSize: MAX_UPLOAD_BYTES },
  fileFilter: (req, file, cb) => {
    // multer decodes field names and file names as latin1 in some versions;
    // browsers send UTF-8, so re-decode when it looks mangled.
    const ext = path.extname(file.originalname || "").toLowerCase();
    if (!ALLOWED_EXT.has(ext)) {
      return cb(badRequest(`${file.originalname}: Dateityp nicht erlaubt (${[...ALLOWED_EXT].join(" ")})`));
    }
    cb(null, true);
  },
});

function fixEncoding(name) {
  // Express/multer hand over the original file name as latin1 when the
  // browser sent UTF-8; "Gänse" shows up as "GÃ¤nse". Undo that.
  const utf8 = Buffer.from(name, "latin1").toString("utf8");
  return utf8.includes("�") ? name : utf8;
}

app.post("/api/items", upload.array("files", 50), (req, res, next) => {
  const cleanup = () => (req.files || []).forEach((f) => fs.rm(f.path, { force: true }, () => {}));
  try {
    if (!req.files || !req.files.length) throw badRequest("Keine Datei");
    const showFrom = parseWhen(req.body.showFrom);
    const showUntil = parseWhen(req.body.showUntil);
    if (showFrom && showUntil && showUntil <= showFrom) throw badRequest('"Anzeigen bis" liegt vor "Anzeigen ab"');
    const screens = parseScreens(req.body.screens);
    const created = req.files.map((f) => ({
      id: path.basename(f.filename, path.extname(f.filename)),
      name: safeName(fixEncoding(f.originalname)),
      storedName: f.filename,
      size: f.size,
      uploadedAt: new Date().toISOString(),
      showFrom,
      showUntil,
      screens,
      enabled: true,
    }));
    items.push(...created);
    saveItems();
    res.status(201).json(created.map(withStatus));
  } catch (err) {
    cleanup();
    next(err);
  }
});

app.patch("/api/items/:id", (req, res, next) => {
  try {
    const item = findItem(req.params.id);
    const body = req.body || {};
    const next_ = { ...item };
    if ("showFrom" in body) next_.showFrom = parseWhen(body.showFrom);
    if ("showUntil" in body) next_.showUntil = parseWhen(body.showUntil);
    if ("screens" in body) next_.screens = parseScreens(body.screens);
    if ("name" in body) next_.name = safeName(body.name);
    if ("enabled" in body) next_.enabled = Boolean(body.enabled);
    if (next_.showFrom && next_.showUntil && next_.showUntil <= next_.showFrom) {
      throw badRequest('"Anzeigen bis" liegt vor "Anzeigen ab"');
    }
    Object.assign(item, next_);
    saveItems();
    res.json(withStatus(item));
  } catch (err) {
    next(err);
  }
});

app.delete("/api/items/:id", (req, res, next) => {
  try {
    removeItem(findItem(req.params.id));
    res.status(204).end();
  } catch (err) {
    next(err);
  }
});

app.put("/api/settings", (req, res, next) => {
  try {
    const d = Number(req.body && req.body.imageDuration);
    if (!Number.isInteger(d) || d < 5 || d > 3600) throw badRequest("Bilddauer: 5 bis 3600 Sekunden");
    settings.imageDuration = d;
    saveSettings();
    res.json(settings);
  } catch (err) {
    next(err);
  }
});

// eslint-disable-next-line no-unused-vars
app.use((err, req, res, next) => {
  if (err instanceof multer.MulterError) {
    err.status = 400;
    if (err.code === "LIMIT_FILE_SIZE") err.message = `Datei zu groß (max. ${MAX_UPLOAD_BYTES / 1024 / 1024} MB)`;
  }
  const code = err.status || 500;
  if (code >= 500) console.error(err);
  res.status(code).json({ error: err.message || "Fehler" });
});

if (require.main === module) {
  purgeExpired();
  setInterval(purgeExpired, 3600 * 1000).unref();
  app.listen(PORT, () => {
    console.log(`bermon-upload listening on :${PORT}, data in ${DATA_DIR}, screens ${SCREENS.join(",")}, auth ${AUTH_PASS ? "on" : "OFF"}`);
  });
}

module.exports = { app, status, safeName, manifestNames };
