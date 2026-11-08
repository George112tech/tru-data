package com.trudata.sms;

// TRU SMS: the part that runs in the background and sends the texts.
//
// Every 10 seconds (straight away again while there are more):
//   1. send the database any results it has not had yet (sent / failed / delivered),
//   2. ask for waiting texts (gateway_poll),
//   3. send each one from the SIM, a moment apart.
// Android tells us when each text has left the phone (sent) and, if the
// network supports it, when it reached the other phone (delivered).
//
// It runs as a foreground service ("TRU SMS is running" notification), keeps
// the CPU awake while running, and starts again after the phone restarts.

import android.app.Activity;
import android.app.Notification;
import android.app.NotificationChannel;
import android.app.NotificationManager;
import android.app.PendingIntent;
import android.app.Service;
import android.content.BroadcastReceiver;
import android.content.Context;
import android.content.Intent;
import android.content.IntentFilter;
import android.os.BatteryManager;
import android.os.Build;
import android.os.Handler;
import android.os.HandlerThread;
import android.os.IBinder;
import android.os.PowerManager;
import android.telephony.SmsManager;
import android.telephony.SmsMessage;
import android.telephony.SubscriptionInfo;
import android.telephony.SubscriptionManager;
import android.telephony.TelephonyManager;

import org.json.JSONArray;
import org.json.JSONObject;

import java.util.ArrayList;
import java.util.HashMap;
import java.util.Iterator;
import java.util.Map;

public class GatewayService extends Service {

    static final String APP_VERSION = "1.0";
    private static final String CHANNEL = "gateway";
    private static final int NOTIFICATION_ID = 1;

    private static final long POLL_MS = 10 * 1000;        // normal pace
    private static final long BUSY_MS = 1000;             // more texts are waiting
    private static final long PAUSED_MS = 30 * 1000;      // SMS off or httpSMS chosen
    private static final long NOT_PAIRED_MS = 60 * 1000;
    private static final long SEND_GAP_MS = 1500;         // between two texts
    private static final long RESULT_TIMEOUT_MS = 3 * 60 * 1000;
    private static final int BATCH = 10;

    private static final String ACTION_SENT = "com.trudata.sms.SENT";
    private static final String ACTION_DELIVERED = "com.trudata.sms.DELIVERED";

    private HandlerThread thread;
    private Handler worker;
    private PowerManager.WakeLock wakeLock;
    private long errorDelay = 0;
    private int requestCode = 1;
    private boolean stopping = false;

    // Texts handed to Android and waiting for its "sent" answer, by id.
    private final Map<String, Pending> pending = new HashMap<String, Pending>();

    private static final class Pending {
        final int parts;
        int answered = 0;
        String error = null;
        final long started = System.currentTimeMillis();

        Pending(int parts) {
            this.parts = parts;
        }
    }

    static void start(Context c) {
        Intent i = new Intent(c, GatewayService.class);
        if (Build.VERSION.SDK_INT >= 26) c.startForegroundService(i);
        else c.startService(i);
    }

    static void stop(Context c) {
        c.stopService(new Intent(c, GatewayService.class));
    }

    @Override
    public void onCreate() {
        super.onCreate();
        makeChannel();
        startForeground(NOTIFICATION_ID, notification("Starting…"));
        PowerManager pm = (PowerManager) getSystemService(POWER_SERVICE);
        if (pm != null) {
            wakeLock = pm.newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "TruSms:gateway");
            wakeLock.setReferenceCounted(false);
            wakeLock.acquire();
        }
        IntentFilter f = new IntentFilter();
        f.addAction(ACTION_SENT);
        f.addAction(ACTION_DELIVERED);
        registerReceiver(results, f);
        thread = new HandlerThread("TruSms");
        thread.start();
        worker = new Handler(thread.getLooper());
        Gateway.log(this, "Started");
    }

    @Override
    public int onStartCommand(Intent intent, int flags, int startId) {
        if (Gateway.code(this).length() != 20) {
            Gateway.setStatus(this, "Not paired");
            stopSelf();
            return START_NOT_STICKY;
        }
        worker.removeCallbacks(tick);
        worker.post(tick);
        return START_STICKY;
    }

    @Override
    public void onDestroy() {
        stopping = true;
        try {
            unregisterReceiver(results);
        } catch (Exception ignored) {
        }
        if (worker != null) worker.removeCallbacksAndMessages(null);
        if (thread != null) thread.quitSafely();
        if (wakeLock != null && wakeLock.isHeld()) wakeLock.release();
        Gateway.setStatus(this, "Stopped");
        Gateway.log(this, "Stopped");
        super.onDestroy();
    }

    @Override
    public IBinder onBind(Intent intent) {
        return null;
    }

    // ===================================================================
    // The loop
    // ===================================================================

    private final Runnable tick = new Runnable() {
        @Override
        public void run() {
            if (stopping) return;
            long next = POLL_MS;
            try {
                expireSilentTexts();
                sendReports();
                next = collectAndSend();
                errorDelay = 0;
            } catch (Gateway.ApiError e) {
                if (e.notPaired) {
                    Gateway.setStatus(GatewayService.this, "Not paired");
                    say("Not paired: enter a new code in TRU SMS");
                    Gateway.log(GatewayService.this, "The pairing code was refused. Make a new one in Admin → SMS.");
                    next = NOT_PAIRED_MS;
                } else {
                    next = backOff("Server: " + e.getMessage());
                }
            } catch (Exception e) {
                next = backOff("No connection (" + e.getClass().getSimpleName() + ")");
            }
            if (!stopping) worker.postDelayed(this, next);
        }
    };

    private long backOff(String why) {
        errorDelay = errorDelay == 0 ? 15000 : Math.min(errorDelay * 2, 120000);
        Gateway.setStatus(this, "Waiting for internet");
        say("Waiting for internet… trying again in " + (errorDelay / 1000) + " s");
        Gateway.log(this, why);
        return errorDelay;
    }

    // Ask for waiting texts and send them. Returns when to look again.
    private long collectAndSend() throws Exception {
        JSONObject body = new JSONObject();
        body.put("p_code", Gateway.code(this));
        body.put("p_limit", BATCH);
        body.put("p_info", phoneInfo());
        JSONObject answer = new JSONObject(Gateway.rpc("gateway_poll", body));
        Gateway.touchChecked(this);
        if (!answer.optBoolean("active", false)) {
            String reason = answer.optString("reason", "Paused");
            Gateway.setStatus(this, "Paused: " + reason);
            say("Paused: " + reason);
            return PAUSED_MS;
        }
        JSONArray messages = answer.optJSONArray("messages");
        int n = messages == null ? 0 : messages.length();
        Gateway.setStatus(this, "Running");
        for (int i = 0; i < n && !stopping; i++) {
            JSONObject m = messages.getJSONObject(i);
            sendOne(m.getString("id"), m.getString("to"), m.getString("content"));
            if (i < n - 1) Thread.sleep(SEND_GAP_MS);
        }
        say("Running · " + Gateway.sentToday(this) + " sent today");
        return n >= BATCH ? BUSY_MS : POLL_MS;
    }

    private void sendOne(String id, String to, String content) {
        if (Gateway.wasSent(this, id)) {
            // Sent before, but the database did not hear about it.
            Gateway.queueReport(this, id, "sent", null);
            return;
        }
        try {
            SmsManager sms = smsManager();
            ArrayList<String> parts = sms.divideMessage(content);
            ArrayList<PendingIntent> sent = new ArrayList<PendingIntent>();
            ArrayList<PendingIntent> delivered = new ArrayList<PendingIntent>();
            for (int i = 0; i < parts.size(); i++) {
                sent.add(resultIntent(ACTION_SENT, id));
                // One delivery report is enough: the last part's.
                delivered.add(i == parts.size() - 1 ? resultIntent(ACTION_DELIVERED, id) : null);
            }
            synchronized (pending) {
                pending.put(id, new Pending(parts.size()));
            }
            if (parts.size() == 1) sms.sendTextMessage(to, null, content, sent.get(0), delivered.get(0));
            else sms.sendMultipartTextMessage(to, null, parts, sent, delivered);
            Gateway.log(this, "Sending to " + to + (parts.size() > 1 ? " (" + parts.size() + " parts)" : ""));
        } catch (SecurityException e) {
            synchronized (pending) {
                pending.remove(id);
            }
            Gateway.queueReport(this, id, "failed", "TRU SMS is not allowed to send texts (open the app and allow SMS)");
            Gateway.log(this, "No permission to send texts");
        } catch (Exception e) {
            synchronized (pending) {
                pending.remove(id);
            }
            Gateway.queueReport(this, id, "failed", "Could not send: " + e.getMessage());
            Gateway.log(this, "Could not send to " + to + ": " + e.getMessage());
        }
    }

    private SmsManager smsManager() {
        int sim = Gateway.simId(this);
        if (sim >= 0 && Build.VERSION.SDK_INT >= 22) return SmsManager.getSmsManagerForSubscriptionId(sim);
        return SmsManager.getDefault();
    }

    private PendingIntent resultIntent(String action, String id) {
        Intent i = new Intent(action).setPackage(getPackageName()).putExtra("id", id);
        int flags = PendingIntent.FLAG_UPDATE_CURRENT;
        if (Build.VERSION.SDK_INT >= 23) flags |= PendingIntent.FLAG_IMMUTABLE;
        return PendingIntent.getBroadcast(this, requestCode++, i, flags);
    }

    // Android's answers: sent (each part) and delivered (last part).
    private final BroadcastReceiver results = new BroadcastReceiver() {
        @Override
        public void onReceive(Context c, Intent intent) {
            String id = intent.getStringExtra("id");
            if (id == null) return;
            if (ACTION_SENT.equals(intent.getAction())) {
                int code = getResultCode();
                Pending p;
                synchronized (pending) {
                    p = pending.get(id);
                    if (p == null) return;
                    p.answered++;
                    if (code != Activity.RESULT_OK && p.error == null) p.error = sendError(code);
                    if (p.answered < p.parts) return;
                    pending.remove(id);
                }
                if (p.error == null) {
                    Gateway.rememberSent(c, id);
                    Gateway.countSent(c);
                    Gateway.queueReport(c, id, "sent", null);
                    Gateway.log(c, "Sent ✓");
                } else {
                    Gateway.queueReport(c, id, "failed", p.error);
                    Gateway.log(c, "Failed: " + p.error);
                }
            } else if (ACTION_DELIVERED.equals(intent.getAction())) {
                if (delivered(intent)) Gateway.queueReport(c, id, "delivered", null);
            }
            if (worker != null) worker.post(new Runnable() {
                @Override
                public void run() {
                    try {
                        sendReports();
                    } catch (Exception ignored) {
                        // sent with the next round
                    }
                }
            });
        }
    };

    private static boolean delivered(Intent intent) {
        try {
            byte[] pdu = intent.getByteArrayExtra("pdu");
            if (pdu == null) return false;
            SmsMessage m = Build.VERSION.SDK_INT >= 23
                    ? SmsMessage.createFromPdu(pdu, intent.getStringExtra("format"))
                    : SmsMessage.createFromPdu(pdu);
            // 0: received by the other phone (GSM); anything else is pending or failed.
            return m != null && m.getStatus() == 0;
        } catch (Exception e) {
            return false;
        }
    }

    private static String sendError(int code) {
        switch (code) {
            case SmsManager.RESULT_ERROR_RADIO_OFF:
                return "The phone's network is off (airplane mode?)";
            case SmsManager.RESULT_ERROR_NO_SERVICE:
                return "No network signal on the sending phone";
            case SmsManager.RESULT_ERROR_NULL_PDU:
                return "The text could not be prepared";
            case SmsManager.RESULT_ERROR_GENERIC_FAILURE:
                return "The network refused it (check airtime or SMS bundle)";
            case 5: // RESULT_ERROR_LIMIT_EXCEEDED
                return "Android's limit on texts: tap Allow on the sending phone";
            case 7: // RESULT_ERROR_SHORT_CODE_NOT_ALLOWED
            case 8: // RESULT_ERROR_SHORT_CODE_NEVER_ALLOWED
                return "Texts to that short code are not allowed";
            default:
                return "Not sent (error " + code + ")";
        }
    }

    // Texts Android never answered for: report them as failed so they are tried again.
    private void expireSilentTexts() {
        long now = System.currentTimeMillis();
        synchronized (pending) {
            Iterator<Map.Entry<String, Pending>> it = pending.entrySet().iterator();
            while (it.hasNext()) {
                Map.Entry<String, Pending> e = it.next();
                if (now - e.getValue().started > RESULT_TIMEOUT_MS) {
                    Gateway.queueReport(this, e.getKey(), "failed", "No answer from the phone network");
                    it.remove();
                }
            }
        }
    }

    private void sendReports() throws Exception {
        JSONArray reports = Gateway.takeReports(this);
        if (reports.length() == 0) return;
        try {
            JSONObject body = new JSONObject();
            body.put("p_code", Gateway.code(this));
            body.put("p_results", reports);
            Gateway.rpc("gateway_report", body);
        } catch (Exception e) {
            Gateway.putBackReports(this, reports);
            throw e;
        }
    }

    // ===================================================================
    // What Admin -> SMS shows about this phone
    // ===================================================================

    private JSONObject phoneInfo() {
        JSONObject info = new JSONObject();
        try {
            info.put("app", APP_VERSION);
            info.put("model", Build.MANUFACTURER.equalsIgnoreCase("samsung") ? Build.MODEL : Build.MANUFACTURER + " " + Build.MODEL);
            info.put("android", Build.VERSION.RELEASE);
            Intent battery = registerReceiver(null, new IntentFilter(Intent.ACTION_BATTERY_CHANGED));
            if (battery != null) {
                int level = battery.getIntExtra(BatteryManager.EXTRA_LEVEL, -1);
                int scale = battery.getIntExtra(BatteryManager.EXTRA_SCALE, 100);
                if (level >= 0 && scale > 0) info.put("battery", Math.round(level * 100f / scale));
                info.put("charging", battery.getIntExtra(BatteryManager.EXTRA_PLUGGED, 0) != 0);
            }
            info.put("sim", simName());
            info.put("sent_today", Gateway.sentToday(this));
        } catch (Exception ignored) {
        }
        return info;
    }

    private String simName() {
        try {
            int sim = Gateway.simId(this);
            if (sim >= 0 && Build.VERSION.SDK_INT >= 22) {
                SubscriptionManager sm = (SubscriptionManager) getSystemService(TELEPHONY_SUBSCRIPTION_SERVICE);
                SubscriptionInfo s = sm == null ? null : sm.getActiveSubscriptionInfo(sim);
                if (s != null) return "SIM " + (s.getSimSlotIndex() + 1) + " " + s.getCarrierName();
            }
        } catch (Exception ignored) {
            // no permission to read SIM details
        }
        TelephonyManager tm = (TelephonyManager) getSystemService(TELEPHONY_SERVICE);
        String op = tm == null ? "" : tm.getNetworkOperatorName();
        return op == null || op.isEmpty() ? "SIM" : op;
    }

    // ===================================================================
    // Notification
    // ===================================================================

    private void makeChannel() {
        if (Build.VERSION.SDK_INT < 26) return;
        NotificationChannel ch = new NotificationChannel(CHANNEL, "TRU SMS running", NotificationManager.IMPORTANCE_LOW);
        ch.setDescription("Shows that TRU SMS is ready to send texts");
        ch.setShowBadge(false);
        NotificationManager nm = (NotificationManager) getSystemService(NOTIFICATION_SERVICE);
        if (nm != null) nm.createNotificationChannel(ch);
    }

    private Notification notification(String text) {
        Intent open = new Intent(this, MainActivity.class);
        int flags = PendingIntent.FLAG_UPDATE_CURRENT;
        if (Build.VERSION.SDK_INT >= 23) flags |= PendingIntent.FLAG_IMMUTABLE;
        PendingIntent tap = PendingIntent.getActivity(this, 0, open, flags);
        Notification.Builder b = Build.VERSION.SDK_INT >= 26
                ? new Notification.Builder(this, CHANNEL)
                : new Notification.Builder(this);
        b.setSmallIcon(R.drawable.ic_notify)
                .setContentTitle("TRU SMS")
                .setContentText(text)
                .setContentIntent(tap)
                .setOngoing(true)
                .setShowWhen(false);
        if (Build.VERSION.SDK_INT >= 21) b.setColor(0xFFB91C1C);
        return b.build();
    }

    private String lastSaid = "";

    private void say(String text) {
        if (text.equals(lastSaid)) return;
        lastSaid = text;
        NotificationManager nm = (NotificationManager) getSystemService(NOTIFICATION_SERVICE);
        if (nm != null) nm.notify(NOTIFICATION_ID, notification(text));
    }
}
