// Builds the public website into dist/ for Cloudflare Pages.
//
// Only the files the site needs are published: the page, its CSS, images and
// fonts. Everything else in the repository (android/, supabase/, SQL, docs,
// config) stays private.
//
// Each build gets a build id (the Git commit on Cloudflare), written into the
// page and into version.json. The page compares the two to know when a newer
// version has been published, so the Android app reloads itself.
//
// Cloudflare Pages settings: build command `node scripts/build-site.mjs`,
// build output directory `dist`.

import { cpSync, existsSync, mkdirSync, readdirSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { join } from "node:path";

const root = new URL("..", import.meta.url).pathname;
const out = join(root, "dist");
const build = (process.env.CF_PAGES_COMMIT_SHA || "").slice(0, 12) ||
  new Date().toISOString().replace(/[-:.TZ]/g, "").slice(0, 14);

rmSync(out, { recursive: true, force: true });
mkdirSync(out, { recursive: true });

// The page, with the build id stamped in.
const html = readFileSync(join(root, "index.html"), "utf8");
if (!html.includes('<meta name="tru-build" content="dev">')) {
  throw new Error("index.html is missing <meta name=\"tru-build\" content=\"dev\">");
}
writeFileSync(join(out, "index.html"), html.replace('<meta name="tru-build" content="dev">', `<meta name="tru-build" content="${build}">`));
writeFileSync(join(out, "version.json"), JSON.stringify({ build }) + "\n");

// CSS, images and fonts.
cpSync(join(root, "tailwind.css"), join(out, "tailwind.css"));
for (const f of readdirSync(root)) {
  if (/\.(webp|png|jpe?g|svg|ico)$/i.test(f)) cpSync(join(root, f), join(out, f));
}
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
/tailwind.css
  Cache-Control: no-cache
/fonts/*
  Cache-Control: public, max-age=2592000
`);

console.log(`Built dist/ (build ${build}):`, readdirSync(out).join(", "));
