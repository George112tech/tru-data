# TRU SMS (Android)

Sends TRU Data's text messages (order updates, admin alerts, "Send a text")
from **your own phone's SIM**, instead of through httpSMS. No outside service
is involved, so there is no monthly limit: each text costs what an SMS costs
on that SIM.

## How it works

```
TRU Data (website, database)                 Your phone (TRU SMS)
  order placed → text queued in sms_outbox
                                   ◀── every 10 s: gateway_poll(pairing code)
  hands over waiting texts         ──▶ sends each one from the SIM
                                   ◀── gateway_report: sent / failed / delivered
  Admin → SMS shows the results
```

- The phone proves who it is with a **pairing code** made in
  Admin → SMS → *Pair a phone*. Only the code's fingerprint (SHA-256) is kept
  in the database. Making a new code disconnects the old phone.
- A text the phone could not send goes back in the queue and is tried up to
  3 times. A text handed to a phone that went silent is handed out again after
  10 minutes. A text that was sent but not reported (no internet at that
  moment) is reported later, never sent twice.
- Long texts are sent in parts. On a dual-SIM phone you choose the SIM.
- It runs in the background (a "TRU SMS" notification stays in the status
  bar) and starts again by itself after the phone restarts.
- Admin → SMS shows whether the phone is online, its battery, SIM and how many
  texts are waiting.

## Install and set up

1. **Install the APK** on the phone that will send the texts:
   `release/trusms-v1.0.apk`, or build it yourself (below). Android may ask to
   allow installing from this source.
2. In TRU Data: **Admin → SMS → Who sends the texts → My phone (TRU SMS)**,
   then **Pair a phone**. Copy the code.
3. Open **TRU SMS**, paste the code, tap **Connect**. Allow **SMS** and
   **Phone** when Android asks, then allow it to run in the background.
4. Back in Admin → SMS: turn SMS **On** and **Save**. Send a test SMS.

Keep it running well:

- **Samsung:** Settings → Battery → Background usage limits → **Never
  sleeping apps** → add TRU SMS.
- Keep the phone **charging** and on **Wi-Fi or mobile data**.
- After about 30 texts in 30 minutes Android asks "TRU SMS is sending a large
  number of messages". Tap **Allow** / **Always allow**.
- A **SIM used only for TRU Data** is safest: networks may block a number that
  sends many identical texts.

## Build

The project uses only the Android SDK (no libraries).

- **AIDE / Android Studio:** open this folder and build. Note: an APK built
  there is signed with that tool's own key, so it cannot install over
  `release/trusms-v1.0.apk`: uninstall TRU SMS first, then pair again.
- **Command line:** `./gradlew assembleRelease` (Gradle 6.9.4, Android Gradle
  Plugin 4.2.2, Java 8), then sign it with the TRU SMS key.

`release/trusms-v1.0.apk` was built with aapt2, javac and dx and signed with
the TRU SMS key (`trusms.keystore`, alias `trusms`). The key and its password
are **not** in this repository (it would let anyone make an update of the
app); the owner keeps them. Sign every new version with that key so it
installs as an update; raise `versionCode` and `versionName` in
`app/build.gradle` (and `APP_VERSION` in `GatewayService.java`).

## Files

| File | What it does |
|---|---|
| `MainActivity.java` | The setup screen: status, pairing code, SIM, start/stop, battery, activity log |
| `GatewayService.java` | Runs in the background: collects texts, sends them, reports results |
| `Gateway.java` | Settings, activity log, and the calls to the database |
| `BootReceiver.java` | Starts TRU SMS again after a restart |
| `supabase/migrations/20261114090000_sms_phone_gateway.sql` | The database side (pairing, gateway_poll, gateway_report, the "who sends" switch) |
