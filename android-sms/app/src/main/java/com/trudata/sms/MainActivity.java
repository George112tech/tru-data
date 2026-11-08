package com.trudata.sms;

// TRU SMS: the setup screen.
//
//   Status      running / paused / stopped, last check, texts sent today
//   Pairing     the code from Admin -> SMS -> "Pair a phone", and Connect
//   SIM         which SIM sends (dual-SIM phones)
//   Start/Stop
//   Background  turn off battery optimisation so Android does not stop it
//   Activity    the last things TRU SMS did
//
// The screen is built in code (no layout files) so the project stays small.

import android.Manifest;
import android.app.Activity;
import android.app.AlertDialog;
import android.content.Intent;
import android.content.pm.PackageManager;
import android.graphics.Color;
import android.graphics.Typeface;
import android.graphics.drawable.GradientDrawable;
import android.net.Uri;
import android.os.Build;
import android.os.Bundle;
import android.os.Handler;
import android.os.Looper;
import android.os.PowerManager;
import android.provider.Settings;
import android.telephony.SubscriptionInfo;
import android.telephony.SubscriptionManager;
import android.text.InputType;
import android.util.TypedValue;
import android.view.Gravity;
import android.view.View;
import android.widget.AdapterView;
import android.widget.ArrayAdapter;
import android.widget.Button;
import android.widget.EditText;
import android.widget.LinearLayout;
import android.widget.ScrollView;
import android.widget.Spinner;
import android.widget.TextView;
import android.widget.Toast;

import org.json.JSONObject;

import java.util.ArrayList;
import java.util.List;

public class MainActivity extends Activity {

    private static final int RED = 0xFFB91C1C;
    private static final int GREEN = 0xFF15803D;
    private static final int AMBER = 0xFFB45309;
    private static final int INK = 0xFF0F172A;
    private static final int MUTED = 0xFF64748B;
    private static final int PERMISSIONS = 7;

    private final Handler ui = new Handler(Looper.getMainLooper());
    private TextView statusTitle, statusSub, pairedText, logText, batteryText;
    private EditText codeInput;
    private Button connectButton, startButton, batteryButton;
    private Spinner simSpinner;
    private LinearLayout simCard;
    private final List<Integer> simIds = new ArrayList<Integer>();
    private Runnable afterPermission;

    @Override
    protected void onCreate(Bundle savedInstanceState) {
        super.onCreate(savedInstanceState);
        setContentView(buildScreen());
    }

    @Override
    protected void onResume() {
        super.onResume();
        refreshSims();
        refresh.run();
    }

    @Override
    protected void onPause() {
        ui.removeCallbacks(refresh);
        super.onPause();
    }

    // ===================================================================
    // Screen
    // ===================================================================

    private View buildScreen() {
        ScrollView scroll = new ScrollView(this);
        LinearLayout col = new LinearLayout(this);
        col.setOrientation(LinearLayout.VERTICAL);
        col.setPadding(dp(16), dp(16), dp(16), dp(32));
        scroll.addView(col);

        // Status
        LinearLayout status = card(col);
        statusTitle = text(status, "", 22, INK, true);
        statusSub = text(status, "", 14, MUTED, false);

        // Pairing
        LinearLayout pair = card(col);
        text(pair, "Pairing code", 13, MUTED, true);
        pairedText = text(pair, "", 14, INK, false);
        codeInput = new EditText(this);
        codeInput.setHint("xxxx-xxxx-xxxx-xxxx-xxxx");
        codeInput.setTypeface(Typeface.MONOSPACE);
        codeInput.setSingleLine(true);
        codeInput.setInputType(InputType.TYPE_CLASS_TEXT | InputType.TYPE_TEXT_FLAG_NO_SUGGESTIONS | InputType.TYPE_TEXT_VARIATION_VISIBLE_PASSWORD);
        pair.addView(codeInput, new LinearLayout.LayoutParams(-1, -2));
        connectButton = button(pair, "Connect", true);
        connectButton.setOnClickListener(new View.OnClickListener() {
            @Override
            public void onClick(View v) {
                connect();
            }
        });
        text(pair, "Get the code in TRU Data: Admin → SMS → Pair a phone.", 13, MUTED, false);

        // SIM
        simCard = card(col);
        text(simCard, "Send from", 13, MUTED, true);
        simSpinner = new Spinner(this);
        simCard.addView(simSpinner, new LinearLayout.LayoutParams(-1, -2));
        simSpinner.setOnItemSelectedListener(new AdapterView.OnItemSelectedListener() {
            @Override
            public void onItemSelected(AdapterView<?> parent, View view, int position, long id) {
                if (position < simIds.size() && simIds.get(position) != Gateway.simId(MainActivity.this)) {
                    Gateway.setSimId(MainActivity.this, simIds.get(position));
                    Gateway.log(MainActivity.this, "SIM changed to " + parent.getItemAtPosition(position));
                }
            }

            @Override
            public void onNothingSelected(AdapterView<?> parent) {
            }
        });

        // Start / stop
        startButton = button(col, "Start", true);
        startButton.setOnClickListener(new View.OnClickListener() {
            @Override
            public void onClick(View v) {
                if (Gateway.wantRunning(MainActivity.this)) stopGateway();
                else withPermissions(new Runnable() {
                    @Override
                    public void run() {
                        startGateway();
                    }
                });
            }
        });

        // Background
        LinearLayout bg = card(col);
        text(bg, "Keep TRU SMS running", 13, MUTED, true);
        batteryText = text(bg, "", 14, INK, false);
        batteryButton = button(bg, "Let it run in the background", false);
        batteryButton.setOnClickListener(new View.OnClickListener() {
            @Override
            public void onClick(View v) {
                askBattery();
            }
        });
        text(bg, "On Samsung phones also: Settings → Battery → Background usage limits → Never sleeping apps → add TRU SMS. "
                + "Keep the phone charging and connected to the internet. Android may ask \"TRU SMS is sending a large number "
                + "of messages\": tap Allow (or Always allow).", 13, MUTED, false);

        // Activity
        LinearLayout log = card(col);
        text(log, "Activity", 13, MUTED, true);
        logText = text(log, "", 12, INK, false);
        logText.setTypeface(Typeface.MONOSPACE);

        return scroll;
    }

    private final Runnable refresh = new Runnable() {
        @Override
        public void run() {
            boolean paired = Gateway.code(MainActivity.this).length() == 20;
            boolean running = Gateway.wantRunning(MainActivity.this);
            String st = Gateway.status(MainActivity.this);
            if (!paired) {
                statusTitle.setText("Not paired");
                statusTitle.setTextColor(AMBER);
            } else if (!running) {
                statusTitle.setText("Stopped");
                statusTitle.setTextColor(MUTED);
            } else if (st.startsWith("Running")) {
                statusTitle.setText("Running");
                statusTitle.setTextColor(GREEN);
            } else {
                statusTitle.setText(st.isEmpty() ? "Starting…" : st);
                statusTitle.setTextColor(st.startsWith("Paused") || st.startsWith("Waiting") || st.startsWith("Not paired") ? AMBER : INK);
            }
            long checked = Gateway.checkedAt(MainActivity.this);
            String last = checked == 0 ? "not checked yet" : "last check " + ago(checked);
            statusSub.setText(running ? last + " · " + Gateway.sentToday(MainActivity.this) + " sent today"
                    : Gateway.sentToday(MainActivity.this) + " sent today");

            String code = Gateway.code(MainActivity.this);
            pairedText.setText(paired ? "Paired ✓ (code ending " + code.substring(16) + ")" : "Not paired yet.");
            connectButton.setText(paired ? "Connect with a new code" : "Connect");
            startButton.setText(running ? "Stop" : "Start");
            startButton.setEnabled(paired);
            startButton.setAlpha(paired ? 1f : 0.5f);

            boolean ignoring = ignoringBattery();
            batteryText.setText(ignoring ? "✓ Battery optimisation is off for TRU SMS." : "Battery optimisation is on: Android may pause TRU SMS.");
            batteryText.setTextColor(ignoring ? GREEN : AMBER);
            batteryButton.setVisibility(ignoring || Build.VERSION.SDK_INT < 23 ? View.GONE : View.VISIBLE);

            String log = Gateway.logText(MainActivity.this);
            logText.setText(log.isEmpty() ? "Nothing yet." : log);
            ui.postDelayed(this, 2000);
        }
    };

    // ===================================================================
    // Actions
    // ===================================================================

    private void connect() {
        final String code = Gateway.normalizeCode(codeInput.getText().toString());
        if (code.length() != 20) {
            toast("The code has 20 letters and numbers, like a1b2-c3d4-e5f6-0718-293a");
            return;
        }
        withPermissions(new Runnable() {
            @Override
            public void run() {
                checkCode(code);
            }
        });
    }

    private void checkCode(final String code) {
        connectButton.setEnabled(false);
        connectButton.setText("Checking…");
        new Thread(new Runnable() {
            @Override
            public void run() {
                String error = null, note = null;
                try {
                    JSONObject body = new JSONObject();
                    body.put("p_code", code);
                    body.put("p_limit", 0); // only check the code
                    JSONObject answer = new JSONObject(Gateway.rpc("gateway_poll", body));
                    if (!answer.optBoolean("active", false)) note = answer.optString("reason", "");
                } catch (Gateway.ApiError e) {
                    error = e.notPaired ? "That code is not right, or a newer one was made. Make a new code in Admin → SMS." : e.getMessage();
                } catch (Exception e) {
                    error = "No internet connection. Try again.";
                }
                final String err = error, info = note;
                runOnUiThread(new Runnable() {
                    @Override
                    public void run() {
                        connectButton.setEnabled(true);
                        if (err != null) {
                            new AlertDialog.Builder(MainActivity.this).setTitle("Could not connect").setMessage(err).setPositiveButton("OK", null).show();
                            refresh.run();
                            return;
                        }
                        Gateway.setCode(MainActivity.this, code);
                        codeInput.setText("");
                        Gateway.log(MainActivity.this, "Paired with TRU Data");
                        startGateway();
                        if (info != null && !info.isEmpty()) {
                            new AlertDialog.Builder(MainActivity.this).setTitle("Connected")
                                    .setMessage("This phone is paired. It will send texts once this is fixed:\n\n" + info
                                            + "\n\nIn TRU Data: Admin → SMS → choose \"My phone (TRU SMS)\", turn SMS on and save.")
                                    .setPositiveButton("OK", null).show();
                        } else {
                            toast("Connected. TRU SMS is sending your texts.");
                        }
                    }
                });
            }
        }).start();
    }

    private void startGateway() {
        Gateway.setWantRunning(this, true);
        Gateway.setStatus(this, "Starting…");
        GatewayService.start(this);
        refresh.run();
        if (!ignoringBattery() && Build.VERSION.SDK_INT >= 23) askBattery();
    }

    private void stopGateway() {
        Gateway.setWantRunning(this, false);
        GatewayService.stop(this);
        toast("Stopped. Texts wait until you start TRU SMS again.");
        refresh.run();
    }

    private void askBattery() {
        if (Build.VERSION.SDK_INT < 23) return;
        try {
            Intent i = new Intent(Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS);
            i.setData(Uri.parse("package:" + getPackageName()));
            startActivity(i);
        } catch (Exception e) {
            try {
                startActivity(new Intent(Settings.ACTION_IGNORE_BATTERY_OPTIMIZATION_SETTINGS));
            } catch (Exception ignored) {
                toast("Open Settings → Battery and let TRU SMS run in the background");
            }
        }
    }

    private boolean ignoringBattery() {
        if (Build.VERSION.SDK_INT < 23) return true;
        PowerManager pm = (PowerManager) getSystemService(POWER_SERVICE);
        return pm != null && pm.isIgnoringBatteryOptimizations(getPackageName());
    }

    // ----- SIMs -----

    private void refreshSims() {
        List<String> names = new ArrayList<String>();
        simIds.clear();
        names.add("The phone's default SIM");
        simIds.add(-1);
        try {
            if (Build.VERSION.SDK_INT >= 22 && checkSelfPermissionCompat(Manifest.permission.READ_PHONE_STATE)) {
                SubscriptionManager sm = (SubscriptionManager) getSystemService(TELEPHONY_SUBSCRIPTION_SERVICE);
                List<SubscriptionInfo> subs = sm == null ? null : sm.getActiveSubscriptionInfoList();
                if (subs != null) {
                    for (SubscriptionInfo s : subs) {
                        names.add("SIM " + (s.getSimSlotIndex() + 1) + " · " + s.getCarrierName());
                        simIds.add(s.getSubscriptionId());
                    }
                }
            }
        } catch (Exception ignored) {
            // no SIM details without permission
        }
        ArrayAdapter<String> a = new ArrayAdapter<String>(this, android.R.layout.simple_spinner_dropdown_item, names);
        simSpinner.setAdapter(a);
        int chosen = simIds.indexOf(Gateway.simId(this));
        simSpinner.setSelection(chosen < 0 ? 0 : chosen);
        simCard.setVisibility(simIds.size() > 2 ? View.VISIBLE : View.GONE); // only for dual-SIM phones
    }

    // ----- Permissions (SMS, and phone state to list the SIMs) -----

    private void withPermissions(Runnable then) {
        if (Build.VERSION.SDK_INT < 23 || (checkSelfPermissionCompat(Manifest.permission.SEND_SMS)
                && checkSelfPermissionCompat(Manifest.permission.READ_PHONE_STATE))) {
            then.run();
            return;
        }
        afterPermission = then;
        requestPermissions(new String[]{Manifest.permission.SEND_SMS, Manifest.permission.READ_PHONE_STATE}, PERMISSIONS);
    }

    @Override
    public void onRequestPermissionsResult(int requestCode, String[] permissions, int[] results) {
        super.onRequestPermissionsResult(requestCode, permissions, results);
        if (requestCode != PERMISSIONS) return;
        refreshSims();
        if (checkSelfPermissionCompat(Manifest.permission.SEND_SMS)) {
            Runnable r = afterPermission;
            afterPermission = null;
            if (r != null) r.run();
        } else {
            new AlertDialog.Builder(this).setTitle("TRU SMS needs to send texts")
                    .setMessage("Allow \"Send and view SMS messages\" so TRU SMS can send your customers' texts from this phone.")
                    .setPositiveButton("OK", null).show();
        }
    }

    private boolean checkSelfPermissionCompat(String p) {
        return Build.VERSION.SDK_INT < 23 || checkSelfPermission(p) == PackageManager.PERMISSION_GRANTED;
    }

    // ===================================================================
    // Small helpers
    // ===================================================================

    private LinearLayout card(LinearLayout parent) {
        LinearLayout c = new LinearLayout(this);
        c.setOrientation(LinearLayout.VERTICAL);
        c.setPadding(dp(16), dp(14), dp(16), dp(14));
        GradientDrawable bg = new GradientDrawable();
        bg.setColor(Color.WHITE);
        bg.setCornerRadius(dp(16));
        bg.setStroke(dp(1), 0xFFE2E8F0);
        c.setBackground(bg);
        LinearLayout.LayoutParams lp = new LinearLayout.LayoutParams(-1, -2);
        lp.bottomMargin = dp(12);
        parent.addView(c, lp);
        return c;
    }

    private TextView text(LinearLayout parent, String s, int sp, int color, boolean bold) {
        TextView t = new TextView(this);
        t.setText(s);
        t.setTextSize(TypedValue.COMPLEX_UNIT_SP, sp);
        t.setTextColor(color);
        if (bold) t.setTypeface(Typeface.DEFAULT_BOLD);
        LinearLayout.LayoutParams lp = new LinearLayout.LayoutParams(-1, -2);
        lp.topMargin = dp(4);
        parent.addView(t, lp);
        return t;
    }

    private Button button(LinearLayout parent, String s, boolean primary) {
        Button b = new Button(this);
        b.setText(s);
        b.setAllCaps(false);
        b.setTextSize(TypedValue.COMPLEX_UNIT_SP, 16);
        b.setTypeface(Typeface.DEFAULT_BOLD);
        b.setTextColor(primary ? Color.WHITE : INK);
        GradientDrawable bg = new GradientDrawable();
        bg.setColor(primary ? RED : 0xFFF1F5F9);
        bg.setCornerRadius(dp(14));
        b.setBackground(bg);
        b.setGravity(Gravity.CENTER);
        LinearLayout.LayoutParams lp = new LinearLayout.LayoutParams(-1, dp(52));
        lp.topMargin = dp(8);
        lp.bottomMargin = dp(8);
        parent.addView(b, lp);
        return b;
    }

    private void toast(String s) {
        Toast.makeText(this, s, Toast.LENGTH_LONG).show();
    }

    private static String ago(long t) {
        long s = Math.max(0, (System.currentTimeMillis() - t) / 1000);
        if (s < 60) return s + " s ago";
        if (s < 3600) return (s / 60) + " min ago";
        return (s / 3600) + " h ago";
    }

    private int dp(int v) {
        return Math.round(v * getResources().getDisplayMetrics().density);
    }
}
