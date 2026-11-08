package com.trudata.sms;

// TRU SMS: shared settings, the activity log, and the calls to TRU Data's
// database (Supabase).
//
// The phone talks to two database functions, with its pairing code:
//   gateway_poll(p_code, p_limit, p_info)  -> {"active", "messages": [{"id","to","content"}], "reason"}
//   gateway_report(p_code, p_results)      -> results: [{"id","stage":"sent"|"failed"|"delivered","error"}]
// The URL and key below are the website's public ones (the same the site
// uses); they only allow what the database lets anyone do. The pairing code
// is what proves this is your phone.

import android.content.Context;
import android.content.SharedPreferences;

import org.json.JSONArray;
import org.json.JSONObject;

import java.io.ByteArrayOutputStream;
import java.io.InputStream;
import java.io.OutputStream;
import java.net.HttpURLConnection;
import java.net.URL;
import java.text.SimpleDateFormat;
import java.util.Date;
import java.util.Locale;

final class Gateway {

    static final String SUPABASE_URL = "https://kefcmjfvrqbgtivssdwn.supabase.co";
    static final String SUPABASE_KEY = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6ImtlZmNtamZ2cnFiZ3RpdnNzZHduIiwicm9sZSI6ImFub24iLCJpYXQiOjE3Njg2MDM1NTIsImV4cCI6MjA4NDE3OTU1Mn0.HoXeKRW4-cGfMexGZpdmEvDHK-XXtXDSoMWWWbq4HKw";

    private static final String PREFS = "gateway";
    private static final int LOG_LINES = 60;
    private static final int SENT_IDS = 300;

    private Gateway() {
    }

    // ----- Settings -----

    static SharedPreferences prefs(Context c) {
        return c.getApplicationContext().getSharedPreferences(PREFS, Context.MODE_PRIVATE);
    }

    // The pairing code, as 20 hex digits (dashes and capitals removed).
    static String normalizeCode(String code) {
        return code == null ? "" : code.replaceAll("[^0-9A-Fa-f]", "").toLowerCase(Locale.US);
    }

    static String code(Context c) {
        return prefs(c).getString("code", "");
    }

    static void setCode(Context c, String code) {
        prefs(c).edit().putString("code", normalizeCode(code)).apply();
    }

    static boolean wantRunning(Context c) {
        return prefs(c).getBoolean("running", false);
    }

    static void setWantRunning(Context c, boolean on) {
        prefs(c).edit().putBoolean("running", on).apply();
    }

    // Which SIM sends (subscription id), or -1 for the phone's default SIM.
    static int simId(Context c) {
        return prefs(c).getInt("sim", -1);
    }

    static void setSimId(Context c, int id) {
        prefs(c).edit().putInt("sim", id).apply();
    }

    // ----- What the screen shows -----

    static void setStatus(Context c, String status) {
        prefs(c).edit().putString("status", status).putLong("status_at", System.currentTimeMillis()).apply();
    }

    static String status(Context c) {
        return prefs(c).getString("status", "");
    }

    static void touchChecked(Context c) {
        prefs(c).edit().putLong("checked_at", System.currentTimeMillis()).apply();
    }

    static long checkedAt(Context c) {
        return prefs(c).getLong("checked_at", 0);
    }

    static String today() {
        return new SimpleDateFormat("yyyy-MM-dd", Locale.US).format(new Date());
    }

    static synchronized void countSent(Context c) {
        SharedPreferences p = prefs(c);
        String day = today();
        int n = day.equals(p.getString("sent_day", "")) ? p.getInt("sent_today", 0) : 0;
        p.edit().putString("sent_day", day).putInt("sent_today", n + 1).putLong("sent_total", p.getLong("sent_total", 0) + 1).apply();
    }

    static int sentToday(Context c) {
        SharedPreferences p = prefs(c);
        return today().equals(p.getString("sent_day", "")) ? p.getInt("sent_today", 0) : 0;
    }

    static synchronized void log(Context c, String line) {
        String time = new SimpleDateFormat("HH:mm:ss", Locale.US).format(new Date());
        String old = prefs(c).getString("log", "");
        String all = time + "  " + line + (old.isEmpty() ? "" : "\n" + old);
        String[] lines = all.split("\n");
        if (lines.length > LOG_LINES) {
            StringBuilder b = new StringBuilder();
            for (int i = 0; i < LOG_LINES; i++) {
                if (i > 0) b.append('\n');
                b.append(lines[i]);
            }
            all = b.toString();
        }
        prefs(c).edit().putString("log", all).apply();
    }

    static String logText(Context c) {
        return prefs(c).getString("log", "");
    }

    // ----- Texts already sent (so one is never sent twice) -----
    // If the phone sent a text but could not tell the database (no internet at
    // that moment), the database hands it out again later; this list makes the
    // phone report it as sent instead of sending it a second time.

    static synchronized boolean wasSent(Context c, String id) {
        return ("," + prefs(c).getString("sent_ids", "") + ",").contains("," + id + ",");
    }

    static synchronized void rememberSent(Context c, String id) {
        String old = prefs(c).getString("sent_ids", "");
        String[] ids = old.isEmpty() ? new String[0] : old.split(",");
        StringBuilder b = new StringBuilder(id);
        for (int i = 0; i < ids.length && i < SENT_IDS - 1; i++) b.append(',').append(ids[i]);
        prefs(c).edit().putString("sent_ids", b.toString()).apply();
    }

    // ----- Reports waiting to reach the database -----

    static synchronized void queueReport(Context c, String id, String stage, String error) {
        try {
            JSONArray a = new JSONArray(prefs(c).getString("reports", "[]"));
            JSONObject r = new JSONObject();
            r.put("id", id);
            r.put("stage", stage);
            if (error != null) r.put("error", error);
            a.put(r);
            prefs(c).edit().putString("reports", a.toString()).apply();
        } catch (Exception e) {
            // a broken list is dropped below
            prefs(c).edit().putString("reports", "[]").apply();
        }
    }

    static synchronized JSONArray takeReports(Context c) {
        JSONArray a;
        try {
            a = new JSONArray(prefs(c).getString("reports", "[]"));
        } catch (Exception e) {
            a = new JSONArray();
        }
        prefs(c).edit().putString("reports", "[]").apply();
        return a;
    }

    static synchronized void putBackReports(Context c, JSONArray failed) {
        try {
            JSONArray now = new JSONArray(prefs(c).getString("reports", "[]"));
            for (int i = 0; i < now.length(); i++) failed.put(now.get(i));
            prefs(c).edit().putString("reports", failed.toString()).apply();
        } catch (Exception e) {
            prefs(c).edit().putString("reports", failed.toString()).apply();
        }
    }

    // ----- Calling the database -----

    static final class ApiError extends Exception {
        final int status;
        final boolean notPaired;

        ApiError(int status, String message, boolean notPaired) {
            super(message);
            this.status = status;
            this.notPaired = notPaired;
        }
    }

    // POST /rest/v1/rpc/<function> and return the answer's text.
    static String rpc(String function, JSONObject body) throws Exception {
        HttpURLConnection http = (HttpURLConnection) new URL(SUPABASE_URL + "/rest/v1/rpc/" + function).openConnection();
        try {
            http.setRequestMethod("POST");
            http.setConnectTimeout(15000);
            http.setReadTimeout(25000);
            http.setDoOutput(true);
            http.setRequestProperty("apikey", SUPABASE_KEY);
            http.setRequestProperty("Authorization", "Bearer " + SUPABASE_KEY);
            http.setRequestProperty("Content-Type", "application/json");
            http.setRequestProperty("Accept", "application/json");
            byte[] out = body.toString().getBytes("UTF-8");
            OutputStream os = http.getOutputStream();
            os.write(out);
            os.close();
            int status = http.getResponseCode();
            InputStream in = status >= 400 ? http.getErrorStream() : http.getInputStream();
            String text = read(in);
            if (status >= 400) {
                String message = "Server error " + status;
                String code = "";
                try {
                    JSONObject e = new JSONObject(text);
                    message = e.optString("message", message);
                    code = e.optString("code", "");
                } catch (Exception ignored) {
                }
                throw new ApiError(status, message, "28000".equals(code) || message.contains("not paired"));
            }
            return text;
        } finally {
            http.disconnect();
        }
    }

    private static String read(InputStream in) throws Exception {
        if (in == null) return "";
        ByteArrayOutputStream b = new ByteArrayOutputStream();
        byte[] buf = new byte[4096];
        int n;
        while ((n = in.read(buf)) > 0) b.write(buf, 0, n);
        in.close();
        return b.toString("UTF-8");
    }
}
