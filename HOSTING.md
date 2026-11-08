# Hosting the website on Cloudflare Pages

GitHub Pages publishes the whole repository on the website's domain (the
`android/` project, `supabase/` SQL and server code, config files). Cloudflare Pages publishes only what
`scripts/build-site.mjs` puts in `dist/`:

- `index.html`, with a build id stamped in, and its script moved to a
  minified `app.<hash>.js` (loaded with `defer`, cached for a year)
- `tailwind.<hash>.css`, the images, icons and `fonts/`
- `version.json`, the build id used by the app's auto-update
- `_headers`, the cache and security headers

The domain stays `trudata.rvhssystems.com`, so the Android app, Supabase
sign-in, password-reset links and Paystack need no changes.

## 1. Create the Cloudflare Pages project

1. Sign in at dash.cloudflare.com, then go to **Workers & Pages → Create →
   Pages → Connect to Git**.
2. Connect GitHub and allow the Cloudflare app to see the
   **George112tech/tru-data** repository. Choose "All repositories", or
   select this one. It keeps working after the repository is made private.
3. Select the repository and set:
   - Production branch: `main`
   - Framework preset: **None**
   - Build command: `node scripts/build-site.mjs`
   - Build output directory: `dist`
4. **Save and Deploy**. When it finishes, open the `https://<project>.pages.dev`
   address it shows and check the site works.

Every merge into `main` now publishes automatically. Pull requests get their
own preview address.

## 2. Move the domain

1. In the Pages project, go to **Custom domains → Set up a custom domain** and
   enter `trudata.rvhssystems.com`.
2. What happens next depends on where the DNS for `rvhssystems.com` is:
   - **On Cloudflare:** Cloudflare offers to update the record for you. Accept.
   - **Elsewhere** (your domain or hosting provider): open that DNS panel and
     change the `trudata` **CNAME** record from `george112tech.github.io` to
     the `<project>.pages.dev` address Cloudflare shows. Leave everything
     else alone.
3. Wait until Cloudflare shows the domain as **Active**. This usually takes a
   few minutes; DNS can take up to a few hours. Do it at a quiet time: the
   site may be unreachable for a few minutes while the certificate is issued.
4. Check that it's switched: `https://trudata.rvhssystems.com/version.json`
   shows `{"build":"..."}` on Cloudflare (it is "Not found" on GitHub Pages).

## 3. Turn off GitHub Pages and make the repository private

Only after step 2 works:

1. GitHub → the repository → **Settings → Pages**, and unpublish or turn
   off the site.
2. **Settings → General → Danger zone → Change visibility → Private.**
3. Check that `https://trudata.rvhssystems.com/android/README.md` now says
   "Not found".

The `CNAME` file in the repository was only for GitHub Pages. It is not
published to Cloudflare and can be deleted afterwards.

## Notes

- **Password-reset emails** link to the same domain, so Supabase needs no
  change. To test sign-in on the `pages.dev` address, add it under Supabase →
  Authentication → URL Configuration → Redirect URLs.
- **Speed:** Cloudflare installs the build tools from `package-lock.json`
  (esbuild minifies the script). If they are missing, the build still works,
  just without minifying.
- **Tailwind CSS** is prebuilt (`npm run build:css`) and committed, as before.
- **App updates:** the page compares its build id with `version.json` and
  reloads itself when a newer build is out, never during a purchase or while
  someone is typing. `index.html` and `version.json` are never cached for
  long (see `_headers`).
