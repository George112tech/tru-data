# TRU Data Android app

The app is a thin shell around the live website, https://trudata.rvhssystems.com.
Every change merged to `main` on GitHub (published by GitHub Pages) appears in
the app the next time it is opened. You only build a new APK when you change
these two files.

## Build it in AIDE (once)

1. Open your existing TRU Data project in AIDE.
2. Replace `MainActivity.java` with the one in this folder. Change its first
   `package` line to your project's package name.
3. Copy the `<uses-permission>` lines, the `<application>` settings and the two
   `<intent-filter>` blocks from `AndroidManifest.xml` into your manifest.
   Keep your own `package` and icon.
4. Raise `versionCode` and `versionName` (for example 20 and 2.0.0).
5. Delete the old copy of the website from the project's `assets` folder if it
   is there; the app no longer uses it.
6. Build the APK. Install it over the old app on your phone to check it (it
   must be signed with the same key as the old app; building on the same
   AIDE install does that).

## Publish it

1. Upload the APK to the `app-updates` bucket as `trudata-v2.0.0.apk`
   (the name must follow `trudata-vX.Y.Z.apk`). The website's download
   buttons pick up the newest version automatically.
2. Update `update.json` in the same bucket to point at the new file, so the
   old app's update check offers it to people who still have it.

## What the shell does

- Keeps people signed in (DOM storage on).
- Opens WhatsApp, Patupaa, phone links and APK downloads outside the app;
  keeps the site and Paystack checkout inside.
- The phone's Back button goes back a page before leaving the app.
- Shows a "No internet connection" screen with a Try again button.
- Adds `TruDataApp` to its user agent, so the site hides its "Download the
  app" buttons inside the app.
