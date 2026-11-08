// Builds the public website into dist/ for Cloudflare Pages.
//
// Only the files the site needs are published: the page, its CSS, images and
// fonts. Everything else in the repository (android/, supabase/, SQL, docs,
// config) stays private.
//
// For speed, the page's big inline script is moved into its own minified file
// (app.<hash>.js, loaded with defer so the browser can compile it off the main
// thread and cache it), and the CSS gets a content hash in its name. Both can
// then be cached for a year: a change gives them a new name.
//
// Each build gets a build id (the Git commit on Cloudflare), written into the
// page and into version.json. The page compares the two to know when a newer
// version has been published, so the Android app reloads itself.
//
// Cloudflare Pages settings: build command `node scripts/build-site.mjs`,
// build output directory `dist`.

import { cpSync, existsSync, mkdirSync, readdirSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { createHash } from "node:crypto";
import { join } from "node:path";

const hash = (data) => createHash("sha256").update(data).digest("hex").slice(0, 10);

// esbuild minifies the script. Without it (no npm install) the script is
// still moved out of the page, just not minified.
let esbuild = null;
try { esbuild = await import("esbuild"); } catch { console.warn("esbuild not installed: app script not minified"); }

const root = new URL("..", import.meta.url).pathname;
const out = join(root, "dist");
const build = (process.env.CF_PAGES_COMMIT_SHA || "").slice(0, 12) ||
  new Date().toISOString().replace(/[-:.TZ]/g, "").slice(0, 14);

rmSync(out, { recursive: true, force: true });
mkdirSync(out, { recursive: true });

// The page, with the build id stamped in.
let html = readFileSync(join(root, "index.html"), "utf8");
const marker = '<meta name="tru-build" content="dev">';
if (!html.includes(marker)) throw new Error(`index.html is missing ${marker}`);
html = html.replace(marker, `<meta name="tru-build" content="${build}">`);

// The app script: out of the page, minified, deferred (after the Supabase library).
const open = "\n<script>\n", close = "\n</script>\n</body>";
const start = html.indexOf(open), end = html.lastIndexOf(close);
if (start < 0 || end < start) throw new Error("index.html: main inline <script> not found");
let js = html.slice(start + open.length, end);
if (esbuild) {
  // Top-level names are not renamed (esbuild keeps them in a plain script), so the
  // page's onclick="..." handlers still find their functions.
  js = (await esbuild.transform(js, { loader: "js", minify: true, target: "es2019", legalComments: "none" })).code;
}
const appFile = `app.${hash(js)}.js`;
writeFileSync(join(out, appFile), js);
html = html.slice(0, start) + `\n<script src="${appFile}" defer></script>\n</body>` + html.slice(end + close.length);
const supa = '<script src="https://cdn.jsdelivr.net/npm/@supabase/supabase-js@2.45.4/dist/umd/supabase.js"></script>';
if (!html.includes(supa)) throw new Error("index.html: Supabase <script> not found");
html = html.replace(supa, supa.replace("></script>", " defer></script>"));

// CSS with a content hash in its name.
const css = readFileSync(join(root, "tailwind.css"));
const cssFile = `tailwind.${hash(css)}.css`;
writeFileSync(join(out, cssFile), css);
if (!html.includes('href="tailwind.css"')) throw new Error("index.html: tailwind.css link not found");
html = html.replace('href="tailwind.css"', `href="${cssFile}"`);

writeFileSync(join(out, "index.html"), html);
writeFileSync(join(out, "version.json"), JSON.stringify({ build }) + "\n");

// Images and fonts.
for (const f of readdirSync(root)) {
  if (/\.(webp|png|jpe?g|svg|ico)$/i.test(f)) cpSync(join(root, f), join(out, f));
}
// The web app manifest (Add to Home Screen).
if (existsSync(join(root, "manifest.webmanifest"))) cpSync(join(root, "manifest.webmanifest"), join(out, "manifest.webmanifest"));
if (existsSync(join(root, "fonts"))) cpSync(join(root, "fonts"), join(out, "fonts"), { recursive: true });

// Response headers (Cloudflare Pages reads dist/_headers).
writeFileSync(join(out, "_headers"), `/*
  X-Content-Type-Options: nosniff
  Referrer-Policy: strict-origin-when-cross-origin
  X-Frame-Options: SAMEORIGIN
/
  Cache-Control: no-cache
/index.html
  Cache-Control: no-cache
/version.json
  Cache-Control: no-store
/manifest.webmanifest
  Content-Type: application/manifest+json
  Cache-Control: public, max-age=86400
/app.*.js
  Cache-Control: public, max-age=31536000, immutable
/tailwind.*.css
  Cache-Control: public, max-age=31536000, immutable
/fonts/*
  Cache-Control: public, max-age=31536000
/*.webp
  Cache-Control: public, max-age=2592000
/*.png
  Cache-Control: public, max-age=2592000
`);

console.log(`Built dist/ (build ${build}): index.html ${(html.length / 1024).toFixed(0)} KB, ${appFile} ${(js.length / 1024).toFixed(0)} KB:`, readdirSync(out).join(", "));
