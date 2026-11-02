# TRU Data Android app (2.1.0)

This folder is the complete Android project. Open it in AIDE (or Android Studio)
and build it as it is.

Design: Figma file "TRU Data – Mobile App":
https://www.figma.com/design/BNCeJWwtcRPB3IHV3sZHYn

## What the app does itself, and what comes from the website

| The app (needs a new APK to change)          | The website (changes reach the app at once)          |
|----------------------------------------------|------------------------------------------------------|
| Red top bar: logo or back arrow + page title, wallet balance, initials | Home: greeting, balance card, quick actions, network switcher, bundles, recent orders |
| Tab bar: Home, Orders, Wallet, Agent, Account | Buy sheet (slides up, drag down to close)            |
| Red heartbeat splash screen                  | Wallet, MoMo top-up, orders, agent hub, account      |
| "You're offline" screen, retries by itself   | Bundles, prices, MoMo number, announcements (admin)  |
| Pull to refresh, haptics, share sheet        | Terms, privacy, account deletion                     |
| AdMob banner + interstitial (same IDs)       | "Update available" prompt for new APKs               |

The app adds `TruDataApp/<version> TruShell/1` to its user agent. When the site
sees `TruShell`, it hides its own menu and footer and shows the app screens.
Older app versions (2.0.x) don't send `TruShell`, so they keep showing the
normal site.

**Merge the website changes (index.html) before you install this APK.** Until
the site is in app mode, the app keeps its own bars hidden and simply shows
the site, so nothing breaks in the meantime.

## Build

The project includes the Gradle wrapper (`gradlew`, Gradle 6.9.4) and uses
Android Gradle Plugin 4.2.2 (compile SDK 29, build tools 29.0.3, target SDK
29, min SDK 21). Both run on Java 8, like AIDE's built-in JDK. It needs
internet access the first time.

**In AIDE / AndroidIDE on the phone**
1. Unzip and open the `TruData` folder as the project.
2. Let it sync (it downloads Gradle and the libraries the first time).
3. Build → release APK, signed with your usual key so it installs over the
   old app. (Debug APKs can't install over a release-signed app.)

**From a terminal** (Termux or a computer):
```
cd TruData
chmod +x gradlew        # only if the file lost its permission when copied
./gradlew assembleRelease
```
The APK is in `app/build/outputs/apk/release/`.

Same package (`com.trudata.app`), same AdMob app ID and ad unit IDs as before, plus an app open ad (2.1.1).
Version: `versionCode 26`, `versionName 2.1.1` in `app/build.gradle`. Raise
both for every new APK.

## Publish the update

Upload the APK to the Supabase bucket `app-updates` named exactly
`trudata-v2.1.1.apk` (no extra dot after the `v`). The site picks the newest
file by itself: the download button on the website and the "Update available"
card inside older-version apps point to it. Update `update.json` too if you
still use it.

## Files

```
android/
  build.gradle, settings.gradle, gradle.properties
  gradlew, gradle/wrapper/              Gradle wrapper (Gradle 6.9.4)
  app/build.gradle                      SDKs, version, AdMob 19.7.0 (keep 19.x)
  app/proguard-rules.pro
  app/src/main/AndroidManifest.xml      AdMob app ID, deep links, TruTheme
  app/src/main/java/com/trudata/app/MainActivity.java
  app/src/main/res/layout/activity_main.xml
  app/src/main/res/drawable/            tab icons (Lucide) and shapes
  app/src/main/res/values/              colours (design tokens), strings, theme
  app/src/main/res/mipmap-*/            launcher icons
  app/src/main/assets/fonts/            Inter (SIL Open Font License 1.1)
```

If you would rather keep your old launcher icon, copy your old `mipmap-*`
folders over the new ones before building.
