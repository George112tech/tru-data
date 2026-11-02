package com.trudata.app;

// TRU Data Android app 2.1: native app chrome around the live website.
//
// Design: Figma "TRU Data – Mobile App".
//
// The app draws these itself, so they always look and feel like an app:
//   - the red top bar (logo, or back arrow + page title, wallet balance, avatar)
//   - the tab bar (Home, Orders, Wallet, Agent, Account) with haptic feedback
//   - the red heartbeat splash screen and the "You're offline" screen
//   - pull to refresh, AdMob banner + interstitial, sharing, deep links
//
// Everything inside (buying, wallet, orders, agent hub, admin) is the website
// https://trudata.rvhssystems.com in "app mode". Changes merged on GitHub or
// made in the admin dashboard show up in the app straight away; a new APK is
// only needed to change this file, the layout, the icons or the ads.
//
// How the two talk:
//   page -> app   window.TruApp.onState(json)  what to show in the bars
//                 window.TruApp.haptic(kind)   "tick", "success", "error"
//                 window.TruApp.share(text)    the phone's share sheet
//   app -> page   TruAppBridge.go(tab), TruAppBridge.back(), TruAppBridge.refresh()
// The site switches to app mode when the user agent contains "TruShell/1".

import android.app.Activity;
import android.content.ActivityNotFoundException;
import android.content.BroadcastReceiver;
import android.content.Context;
import android.content.Intent;
import android.content.IntentFilter;
import android.content.pm.PackageManager;
import android.graphics.Color;
import android.graphics.PorterDuff;
import android.graphics.Typeface;
import android.graphics.drawable.GradientDrawable;
import android.net.ConnectivityManager;
import android.net.NetworkInfo;
import android.net.Uri;
import android.os.Build;
import android.os.Bundle;
import android.os.Handler;
import android.os.Looper;
import android.os.VibrationEffect;
import android.os.Vibrator;
import android.util.TypedValue;
import android.view.Gravity;
import android.view.HapticFeedbackConstants;
import android.view.View;
import android.view.ViewGroup;
import android.view.ViewTreeObserver;
import android.webkit.CookieManager;
import android.webkit.DownloadListener;
import android.webkit.JavascriptInterface;
import android.webkit.ValueCallback;
import android.webkit.WebChromeClient;
import android.webkit.WebSettings;
import android.webkit.WebView;
import android.webkit.WebViewClient;
import android.widget.FrameLayout;
import android.widget.ImageButton;
import android.widget.ImageView;
import android.widget.LinearLayout;
import android.widget.ProgressBar;
import android.widget.TextView;
import android.widget.Toast;

import androidx.swiperefreshlayout.widget.SwipeRefreshLayout;

import com.google.android.gms.ads.AdListener;
import com.google.android.gms.ads.AdRequest;
import com.google.android.gms.ads.AdSize;
import com.google.android.gms.ads.AdView;
import com.google.android.gms.ads.InterstitialAd;
import com.google.android.gms.ads.MobileAds;

import org.json.JSONObject;

public class MainActivity extends Activity {

    // ----- AdMob (unchanged) -----
    private static final String BANNER_AD_UNIT_ID = "ca-app-pub-8934706810849620/7330461846";
    private static final String INTERSTITIAL_AD_UNIT_ID = "ca-app-pub-8934706810849620/6017380172";
    // Full-screen ad: every 3rd Back press, and never more than once a minute.
    private static final int INTERSTITIAL_EVERY = 3;
    private static final long INTERSTITIAL_MIN_GAP_MS = 60 * 1000;

    // ----- The site -----
    private static final String HOME = "https://trudata.rvhssystems.com/";
    private static final String SITE_HOST = "trudata.rvhssystems.com";
    // These open inside the app; everything else (WhatsApp, calls, downloads) opens outside it.
    private static final String[] IN_APP_HOSTS = {SITE_HOST, "checkout.paystack.com", "standard.paystack.co", "js.paystack.co"};

    // ----- Design tokens (res/values/colors.xml) -----
    // Shades of red, used together (gradients) rather than one flat bright red.
    private static final int RED_800 = Color.parseColor("#8E1616");
    private static final int RED_700 = Color.parseColor("#B91C1C");
    private static final int RED_600 = Color.parseColor("#C9302C");
    private static final int INK_500 = Color.parseColor("#64748B");

    // ----- Tabs: key (as the site names them), label, icon, address -----
    private static final String[] TAB_KEYS = {"home", "orders", "wallet", "agent", "account"};
    private static final int[] TAB_LABELS = {R.string.tab_home, R.string.tab_orders, R.string.tab_wallet, R.string.tab_agent, R.string.tab_account};
    private static final int[] TAB_ICONS = {R.drawable.ic_tab_home, R.drawable.ic_tab_orders, R.drawable.ic_tab_wallet, R.drawable.ic_tab_agent, R.drawable.ic_tab_account};
    private static final String[] TAB_HASH = {"", "#/orders", "#/wallet", "#/agent", "#/account"};

    private static final long SPLASH_MIN_MS = 1200; // long enough to see the heartbeat

    private final Handler handler = new Handler(Looper.getMainLooper());

    private View root;
    private WebView webView;
    private SwipeRefreshLayout swipe;
    private ProgressBar progress;
    private View offlineView;
    private LinearLayout topBar;
    private ImageButton backButton;
    private View logo;
    private TextView titleView;
    private View balanceChip;
    private TextView balanceText;
    private TextView avatar;
    private LinearLayout tabBar;
    private FrameLayout adContainer;
    private final View[] tabPills = new View[TAB_KEYS.length];
    private final ImageView[] tabIcons = new ImageView[TAB_KEYS.length];
    private final TextView[] tabLabels = new TextView[TAB_KEYS.length];

    private Typeface fontSemiBold, fontBold, fontBlack;
    private String versionName = "2.1.0";

    // What the site last told us.
    private boolean chromeReady = false;
    private boolean tabsAllowed = false;
    private String selectedTab = "";
    private boolean keyboardOpen = false;
    private boolean adLoaded = false;

    private AdView bannerAd;
    private InterstitialAd interstitialAd;
    private boolean adsStarted = false;
    private int navigationCount = 0;
    private long lastInterstitialAt = 0;
    private long lastBackPress = 0;

    private boolean offlineShown = false;
    private boolean loadFailed = false;
    private View splash;
    private android.animation.ValueAnimator heartbeat;
    private long splashShownAt = 0;
    private boolean receiverRegistered = false;

    // =====================================================================
    // Start-up
    // =====================================================================

    @Override
    protected void onCreate(Bundle savedInstanceState) {
        super.onCreate(savedInstanceState);
        getWindow().setBackgroundDrawableResource(R.drawable.bg_splash);
        setContentView(R.layout.activity_main);
        if (Build.VERSION.SDK_INT >= 21) getWindow().setStatusBarColor(RED_800);
        if (Build.VERSION.SDK_INT >= 27) {
            // White navigation bar with dark buttons, to sit under the white tab bar.
            getWindow().setNavigationBarColor(Color.WHITE);
            getWindow().getDecorView().setSystemUiVisibility(View.SYSTEM_UI_FLAG_LIGHT_NAVIGATION_BAR);
        }

        try {
            versionName = getPackageManager().getPackageInfo(getPackageName(), 0).versionName;
        } catch (PackageManager.NameNotFoundException e) {
            // keep the default
        }
        loadFonts();
        findViews();
        setupTopBar();
        buildTabs();
        setupWebView();
        setupPullToRefresh();
        setupOfflineView();
        watchKeyboard();

        // Start loading the site first; everything else waits so it does not slow it down.
        if (savedInstanceState != null) webView.restoreState(savedInstanceState);
        else loadWebApp(getIntent());
        showSplash();

        registerReceiver(networkReceiver, new IntentFilter(ConnectivityManager.CONNECTIVITY_ACTION));
        receiverRegistered = true;

        // Ads start once the page is up (or after 4 seconds at most).
        handler.postDelayed(new Runnable() {
            @Override
            public void run() {
                startAds();
            }
        }, 4000);
    }

    // Inter, the font used on the site and in the design (app/src/main/assets/fonts).
    private void loadFonts() {
        fontSemiBold = font("fonts/inter_semibold.ttf", Typeface.DEFAULT);
        fontBold = font("fonts/inter_bold.ttf", Typeface.DEFAULT_BOLD);
        fontBlack = font("fonts/inter_black.ttf", Typeface.DEFAULT_BOLD);
    }

    private Typeface font(String path, Typeface fallback) {
        try {
            return Typeface.createFromAsset(getAssets(), path);
        } catch (RuntimeException e) {
            return fallback;
        }
    }

    private void findViews() {
        root = findViewById(R.id.root);
        webView = findViewById(R.id.webview);
        swipe = findViewById(R.id.swipe_refresh);
        progress = findViewById(R.id.progress_bar);
        offlineView = findViewById(R.id.offline_view);
        topBar = findViewById(R.id.top_bar);
        backButton = findViewById(R.id.btn_back);
        logo = findViewById(R.id.logo);
        titleView = findViewById(R.id.title);
        balanceChip = findViewById(R.id.balance_chip);
        balanceText = findViewById(R.id.balance_text);
        avatar = findViewById(R.id.avatar);
        tabBar = findViewById(R.id.tab_bar);
        adContainer = findViewById(R.id.ad_container);
        if (Build.VERSION.SDK_INT >= 21) {
            progress.setProgressTintList(android.content.res.ColorStateList.valueOf(RED_600));
        }
    }

    // =====================================================================
    // Top bar
    // =====================================================================

    private void setupTopBar() {
        ((TextView) findViewById(R.id.logo_tru)).setTypeface(fontBlack);
        ((TextView) findViewById(R.id.logo_data)).setTypeface(fontBlack);
        titleView.setTypeface(fontBold);
        balanceText.setTypeface(fontBold);
        avatar.setTypeface(fontBlack);
        backButton.setColorFilter(Color.WHITE, PorterDuff.Mode.SRC_IN);
        ((ImageView) findViewById(R.id.balance_icon)).setColorFilter(Color.WHITE, PorterDuff.Mode.SRC_IN);

        backButton.setOnClickListener(new View.OnClickListener() {
            @Override
            public void onClick(View v) {
                haptic("tick");
                goBack(false);
            }
        });
        balanceChip.setOnClickListener(new View.OnClickListener() {
            @Override
            public void onClick(View v) {
                onTabClick("wallet");
            }
        });
        avatar.setOnClickListener(new View.OnClickListener() {
            @Override
            public void onClick(View v) {
                onTabClick("account");
            }
        });
    }

    // =====================================================================
    // Tab bar
    // =====================================================================

    private void buildTabs() {
        TypedValue ripple = new TypedValue();
        getTheme().resolveAttribute(android.R.attr.selectableItemBackgroundBorderless, ripple, true);
        for (int i = 0; i < TAB_KEYS.length; i++) {
            final String key = TAB_KEYS[i];
            LinearLayout item = new LinearLayout(this);
            item.setOrientation(LinearLayout.VERTICAL);
            item.setGravity(Gravity.CENTER_HORIZONTAL);
            item.setPadding(0, dp(5), 0, dp(4));
            item.setClickable(true);
            item.setFocusable(true);
            if (ripple.resourceId != 0) item.setBackgroundResource(ripple.resourceId);
            item.setContentDescription(getString(TAB_LABELS[i]));

            FrameLayout pill = new FrameLayout(this);
            ImageView icon = new ImageView(this);
            icon.setImageResource(TAB_ICONS[i]);
            pill.addView(icon, new FrameLayout.LayoutParams(dp(22), dp(22), Gravity.CENTER));
            item.addView(pill, new LinearLayout.LayoutParams(dp(56), dp(30)));

            TextView label = new TextView(this);
            label.setText(TAB_LABELS[i]);
            label.setTextSize(TypedValue.COMPLEX_UNIT_SP, 11);
            label.setGravity(Gravity.CENTER);
            label.setSingleLine(true);
            label.setIncludeFontPadding(false);
            LinearLayout.LayoutParams lp = new LinearLayout.LayoutParams(ViewGroup.LayoutParams.WRAP_CONTENT, ViewGroup.LayoutParams.WRAP_CONTENT);
            lp.topMargin = dp(4);
            item.addView(label, lp);

            item.setOnClickListener(new View.OnClickListener() {
                @Override
                public void onClick(View v) {
                    onTabClick(key);
                }
            });
            tabBar.addView(item, new LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.WRAP_CONTENT, 1f));
            tabPills[i] = pill;
            tabIcons[i] = icon;
            tabLabels[i] = label;
        }
        paintTabs(false);
    }

    private void paintTabs(boolean animate) {
        for (int i = 0; i < TAB_KEYS.length; i++) {
            boolean on = TAB_KEYS[i].equals(selectedTab);
            tabPills[i].setBackgroundResource(on ? R.drawable.bg_tab_pill : 0);
            tabIcons[i].setColorFilter(on ? RED_700 : INK_500, PorterDuff.Mode.SRC_IN);
            tabLabels[i].setTextColor(on ? RED_700 : INK_500);
            tabLabels[i].setTypeface(on ? fontBold : fontSemiBold);
            tabBar.getChildAt(i).setSelected(on);
            if (on && animate) {
                tabIcons[i].setScaleX(0.8f);
                tabIcons[i].setScaleY(0.8f);
                tabIcons[i].animate().scaleX(1f).scaleY(1f).setDuration(220)
                        .setInterpolator(new android.view.animation.OvershootInterpolator(3f)).start();
            }
        }
    }

    private void selectTab(String key, boolean animate) {
        if (key == null) key = "";
        if (key.equals(selectedTab)) return;
        selectedTab = key;
        paintTabs(animate);
    }

    private void onTabClick(String key) {
        haptic("tick");
        if (offlineShown) {
            retry();
            return;
        }
        selectTab(key, true); // straight away; the site confirms a moment later
        int i = indexOf(key);
        final String fallback = HOME + (i >= 0 ? TAB_HASH[i] : "");
        webView.evaluateJavascript(
                "(function(){if(window.TruAppBridge){TruAppBridge.go('" + key + "');return 'ok';}return 'none';})()",
                new ValueCallback<String>() {
                    @Override
                    public void onReceiveValue(String value) {
                        // Not on the site (for example the Paystack page): open the tab's address.
                        if (value == null || !value.contains("ok")) webView.loadUrl(fallback);
                    }
                });
    }

    private int indexOf(String key) {
        for (int i = 0; i < TAB_KEYS.length; i++) if (TAB_KEYS[i].equals(key)) return i;
        return -1;
    }

    // Bars only show once the site is in app mode (an old version of the site
    // keeps its own menu), and the tabs hide while the keyboard is open.
    private void updateChrome() {
        topBar.setVisibility(chromeReady ? View.VISIBLE : View.GONE);
        tabBar.setVisibility(chromeReady && tabsAllowed && !keyboardOpen ? View.VISIBLE : View.GONE);
        adContainer.setVisibility(adLoaded && !keyboardOpen ? View.VISIBLE : View.GONE);
    }

    // =====================================================================
    // State from the site
    // =====================================================================

    // {"view","tab","title","root","logo","loggedIn","admin","sheet","balance","initials"}
    private void applyState(String json) {
        if (!onSite()) return;
        JSONObject s;
        try {
            s = new JSONObject(json);
        } catch (Exception e) {
            return;
        }
        boolean first = !chromeReady;
        chromeReady = true;
        boolean loggedIn = s.optBoolean("loggedIn");
        boolean admin = s.optBoolean("admin");
        boolean showLogo = s.optBoolean("logo");
        boolean isRoot = s.optBoolean("root", true);
        String title = s.optString("title", "");
        String balance = s.optString("balance", "");
        String initials = s.optString("initials", "");

        backButton.setVisibility(isRoot ? View.GONE : View.VISIBLE);
        topBar.setPadding(dp(isRoot ? 16 : 8), 0, dp(16), 0);
        logo.setVisibility(showLogo ? View.VISIBLE : View.GONE);
        String newTitle = showLogo ? "" : title;
        if (!newTitle.contentEquals(titleView.getText())) {
            titleView.setText(newTitle);
            if (!first) {
                titleView.setAlpha(0f);
                titleView.setTranslationX(dp(6));
                titleView.animate().alpha(1f).translationX(0).setDuration(180).start();
            }
        }

        boolean chip = !showLogo && !admin && balance.length() > 0;
        if (chip && !balance.contentEquals(balanceText.getText()) && balanceChip.getVisibility() == View.VISIBLE) {
            balanceChip.setScaleX(1.08f);
            balanceChip.setScaleY(1.08f);
            balanceChip.animate().scaleX(1f).scaleY(1f).setDuration(260).start();
        }
        balanceText.setText(balance);
        balanceChip.setVisibility(chip ? View.VISIBLE : View.GONE);

        boolean showAvatar = showLogo && loggedIn && !admin && initials.length() > 0;
        avatar.setText(initials);
        avatar.setVisibility(showAvatar ? View.VISIBLE : View.GONE);

        tabsAllowed = loggedIn && !admin;
        selectTab(s.optString("tab", ""), false);
        // No pull-to-refresh while a sheet or dialog is open (it is dragged down to close).
        swipe.setEnabled(!s.optBoolean("sheet"));
        updateChrome();
    }

    private boolean onSite() {
        String url = webView.getUrl();
        if (url == null) return false;
        String host = Uri.parse(url).getHost();
        return SITE_HOST.equals(host);
    }

    // window.TruApp, called by the page (on a background thread).
    private class Bridge {
        @JavascriptInterface
        public void onState(final String json) {
            runOnUiThread(new Runnable() {
                @Override
                public void run() {
                    applyState(json);
                }
            });
        }

        @JavascriptInterface
        public void haptic(final String kind) {
            runOnUiThread(new Runnable() {
                @Override
                public void run() {
                    if (onSite()) MainActivity.this.haptic(kind);
                }
            });
        }

        @JavascriptInterface
        public void share(final String text) {
            runOnUiThread(new Runnable() {
                @Override
                public void run() {
                    if (onSite()) shareText(text);
                }
            });
        }

        @JavascriptInterface
        public String version() {
            return versionName;
        }
    }

    // =====================================================================
    // Haptics and sharing
    // =====================================================================

    private void haptic(String kind) {
        if (kind == null || kind.equals("tick")) {
            root.performHapticFeedback(HapticFeedbackConstants.VIRTUAL_KEY, HapticFeedbackConstants.FLAG_IGNORE_VIEW_SETTING);
            return;
        }
        Vibrator v = (Vibrator) getSystemService(Context.VIBRATOR_SERVICE);
        if (v == null || !v.hasVibrator()) return;
        long[] pattern = kind.equals("error") ? new long[]{0, 35, 60, 35} : new long[]{0, 15, 70, 25};
        try {
            if (Build.VERSION.SDK_INT >= 26) v.vibrate(VibrationEffect.createWaveform(pattern, -1));
            else v.vibrate(pattern, -1);
        } catch (RuntimeException e) {
            // some phones refuse; never crash for a vibration
        }
    }

    private void shareText(String text) {
        Intent send = new Intent(Intent.ACTION_SEND);
        send.setType("text/plain");
        send.putExtra(Intent.EXTRA_TEXT, text);
        try {
            startActivity(Intent.createChooser(send, getString(R.string.share_title)));
        } catch (ActivityNotFoundException e) {
            Toast.makeText(this, R.string.no_app_for_link, Toast.LENGTH_SHORT).show();
        }
    }

    // =====================================================================
    // Splash: bright red, the TRU DATA logo beating like a heart with
    // pulse rings, faded out as soon as the site has drawn something.
    // =====================================================================

    private void showSplash() {
        FrameLayout box = new FrameLayout(this);
        box.setBackgroundResource(R.drawable.bg_splash);
        box.setClickable(true);

        final View ring1 = ring();
        final View ring2 = ring();
        box.addView(ring1, new FrameLayout.LayoutParams(dp(210), dp(210), Gravity.CENTER));
        box.addView(ring2, new FrameLayout.LayoutParams(dp(210), dp(210), Gravity.CENTER));

        LinearLayout center = new LinearLayout(this);
        center.setOrientation(LinearLayout.VERTICAL);
        center.setGravity(Gravity.CENTER_HORIZONTAL);

        LinearLayout logoRow = new LinearLayout(this);
        logoRow.setOrientation(LinearLayout.HORIZONTAL);
        logoRow.setGravity(Gravity.CENTER_VERTICAL);
        TextView tru = new TextView(this);
        tru.setText("TRU");
        tru.setTextColor(RED_700);
        tru.setTextSize(TypedValue.COMPLEX_UNIT_SP, 32);
        tru.setTypeface(fontBlack);
        tru.setIncludeFontPadding(false);
        GradientDrawable pill = new GradientDrawable();
        pill.setColor(Color.WHITE);
        pill.setCornerRadius(dp(14));
        tru.setBackground(pill);
        tru.setPadding(dp(14), dp(6), dp(14), dp(6));
        TextView data = new TextView(this);
        data.setText("DATA");
        data.setTextColor(Color.WHITE);
        data.setTextSize(TypedValue.COMPLEX_UNIT_SP, 32);
        data.setTypeface(fontBlack);
        data.setIncludeFontPadding(false);
        LinearLayout.LayoutParams dataLp = new LinearLayout.LayoutParams(ViewGroup.LayoutParams.WRAP_CONTENT, ViewGroup.LayoutParams.WRAP_CONTENT);
        dataLp.leftMargin = dp(8);
        logoRow.addView(tru);
        logoRow.addView(data, dataLp);
        center.addView(logoRow);

        TextView tagline = new TextView(this);
        tagline.setText(R.string.splash_tagline);
        tagline.setTextColor(Color.WHITE);
        tagline.setAlpha(0.85f);
        tagline.setTextSize(TypedValue.COMPLEX_UNIT_SP, 14);
        tagline.setTypeface(fontSemiBold);
        LinearLayout.LayoutParams tagLp = new LinearLayout.LayoutParams(ViewGroup.LayoutParams.WRAP_CONTENT, ViewGroup.LayoutParams.WRAP_CONTENT);
        tagLp.topMargin = dp(18);
        center.addView(tagline, tagLp);
        box.addView(center, new FrameLayout.LayoutParams(ViewGroup.LayoutParams.WRAP_CONTENT, ViewGroup.LayoutParams.WRAP_CONTENT, Gravity.CENTER));

        TextView footer = new TextView(this);
        footer.setText("Made in Ghana · v" + versionName);
        footer.setTextColor(Color.WHITE);
        footer.setAlpha(0.6f);
        footer.setTextSize(TypedValue.COMPLEX_UNIT_SP, 12);
        footer.setTypeface(fontSemiBold);
        FrameLayout.LayoutParams footLp = new FrameLayout.LayoutParams(ViewGroup.LayoutParams.WRAP_CONTENT, ViewGroup.LayoutParams.WRAP_CONTENT, Gravity.BOTTOM | Gravity.CENTER_HORIZONTAL);
        footLp.bottomMargin = dp(36);
        box.addView(footer, footLp);

        splash = box;
        splashShownAt = System.currentTimeMillis();
        addContentView(splash, new FrameLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.MATCH_PARENT));
        startHeartbeat(logoRow, ring1, ring2);
        handler.postDelayed(new Runnable() {
            @Override
            public void run() {
                hideSplash();
            }
        }, 8000);
    }

    private View ring() {
        View v = new View(this);
        GradientDrawable d = new GradientDrawable();
        d.setShape(GradientDrawable.OVAL);
        d.setColor(Color.WHITE);
        v.setBackground(d);
        v.setAlpha(0f);
        return v;
    }

    // Two quick beats (big, then a little smaller), a rest, and again; a ring
    // ripples out on each beat.
    private void startHeartbeat(final View logoRow, final View ring1, final View ring2) {
        heartbeat = android.animation.ValueAnimator.ofFloat(0f, 1f);
        heartbeat.setDuration(1100);
        heartbeat.setRepeatCount(android.animation.ValueAnimator.INFINITE);
        heartbeat.setInterpolator(new android.view.animation.LinearInterpolator());
        heartbeat.addUpdateListener(new android.animation.ValueAnimator.AnimatorUpdateListener() {
            @Override
            public void onAnimationUpdate(android.animation.ValueAnimator a) {
                float t = (float) a.getAnimatedValue();
                float scale;
                if (t < 0.12f) scale = 1f + 0.16f * (t / 0.12f);
                else if (t < 0.24f) scale = 1.16f - 0.16f * ((t - 0.12f) / 0.12f);
                else if (t < 0.36f) scale = 1f + 0.10f * ((t - 0.24f) / 0.12f);
                else if (t < 0.50f) scale = 1.10f - 0.10f * ((t - 0.36f) / 0.14f);
                else scale = 1f;
                logoRow.setScaleX(scale);
                logoRow.setScaleY(scale);
                pulse(ring1, t);
                pulse(ring2, (t + 0.5f) % 1f);
            }
        });
        heartbeat.start();
    }

    private void pulse(View ring, float t) {
        float s = 0.7f + 0.9f * t;
        ring.setScaleX(s);
        ring.setScaleY(s);
        ring.setAlpha(0.16f * (1f - t));
    }

    private void hideSplash() {
        if (splash == null) return;
        long shown = System.currentTimeMillis() - splashShownAt;
        if (shown < SPLASH_MIN_MS) {
            handler.postDelayed(new Runnable() {
                @Override
                public void run() {
                    hideSplash();
                }
            }, SPLASH_MIN_MS - shown);
            return;
        }
        final View v = splash;
        splash = null;
        v.animate().alpha(0f).setDuration(350).withEndAction(new Runnable() {
            @Override
            public void run() {
                if (heartbeat != null) heartbeat.cancel();
                ViewGroup parent = (ViewGroup) v.getParent();
                if (parent != null) parent.removeView(v);
            }
        });
        startAds();
    }

    // =====================================================================
    // WebView
    // =====================================================================

    private void setupWebView() {
        WebSettings settings = webView.getSettings();
        settings.setJavaScriptEnabled(true);
        // Keeps people signed in after the app is closed (the site stores the session here).
        settings.setDomStorageEnabled(true);
        settings.setDatabaseEnabled(true);
        settings.setCacheMode(isOnline() ? WebSettings.LOAD_DEFAULT : WebSettings.LOAD_CACHE_ELSE_NETWORK);
        settings.setLoadWithOverviewMode(true);
        settings.setUseWideViewPort(true);
        settings.setSupportZoom(false);
        settings.setTextZoom(100); // the phone's font size setting does not break the layout
        settings.setSupportMultipleWindows(false);
        settings.setJavaScriptCanOpenWindowsAutomatically(true);
        // "TruDataApp" hides the site's app-download buttons; "TruShell/1" turns on app mode.
        settings.setUserAgentString(settings.getUserAgentString() + " TruDataApp/" + versionName + " TruShell/1");

        CookieManager.getInstance().setAcceptCookie(true);
        if (Build.VERSION.SDK_INT >= 21) CookieManager.getInstance().setAcceptThirdPartyCookies(webView, true);

        webView.setBackgroundColor(Color.parseColor("#F5F6F8"));
        webView.setOverScrollMode(View.OVER_SCROLL_NEVER);
        webView.setVerticalScrollBarEnabled(false);
        webView.addJavascriptInterface(new Bridge(), "TruApp");

        webView.setWebChromeClient(new WebChromeClient() {
            @Override
            public void onProgressChanged(WebView view, int newProgress) {
                progress.setProgress(newProgress);
                progress.setVisibility(newProgress < 100 ? View.VISIBLE : View.GONE);
                if (newProgress >= 100) doneRefreshing();
                if (newProgress >= 60) hideSplash();
            }
        });
        webView.setWebViewClient(new WebViewClient() {
            @Override
            @SuppressWarnings("deprecation")
            public boolean shouldOverrideUrlLoading(WebView view, String url) {
                return openOutsideIfNeeded(Uri.parse(url));
            }

            @Override
            public void onPageStarted(WebView view, String url, android.graphics.Bitmap favicon) {
                loadFailed = false;
            }

            @Override
            public void onPageFinished(WebView view, String url) {
                doneRefreshing();
                hideSplash();
                if (!loadFailed) hideOffline();
                // Save the sign-in cookie straight away, not only when the app closes.
                if (Build.VERSION.SDK_INT >= 21) CookieManager.getInstance().flush();
            }

            @Override
            @SuppressWarnings("deprecation")
            public void onReceivedError(WebView view, int code, String description, String failingUrl) {
                // Called for the page itself (not for images or scripts).
                loadFailed = true;
                doneRefreshing();
                hideSplash();
                showOffline();
            }
        });
        // Anything the site offers as a download (the APK update) is handed to the browser.
        webView.setDownloadListener(new DownloadListener() {
            @Override
            public void onDownloadStart(String url, String userAgent, String contentDisposition, String mimetype, long length) {
                openExternal(Uri.parse(url));
            }
        });
    }

    // Links like https://trudata.rvhssystems.com/?agent=AGT-123 open in the app.
    private void loadWebApp(Intent intent) {
        Uri data = intent != null ? intent.getData() : null;
        if (data != null && SITE_HOST.equals(data.getHost())) webView.loadUrl(data.toString());
        else webView.loadUrl(HOME);
    }

    @Override
    protected void onNewIntent(Intent intent) {
        super.onNewIntent(intent);
        if (intent != null && intent.getData() != null) loadWebApp(intent);
    }

    private boolean openOutsideIfNeeded(Uri uri) {
        String scheme = uri.getScheme() == null ? "" : uri.getScheme();
        String host = uri.getHost() == null ? "" : uri.getHost();
        if (scheme.equals("http") || scheme.equals("https")) {
            for (String h : IN_APP_HOSTS) {
                if (host.equals(h) || host.endsWith("." + h)) return false;
            }
        }
        openExternal(uri);
        return true;
    }

    private void openExternal(Uri uri) {
        try {
            startActivity(new Intent(Intent.ACTION_VIEW, uri));
        } catch (ActivityNotFoundException e) {
            Toast.makeText(this, R.string.no_app_for_link, Toast.LENGTH_SHORT).show();
        }
    }

    // =====================================================================
    // Pull to refresh: refreshes the page's data in place (fast); a full
    // reload only when the site is not in app mode or the app is offline.
    // =====================================================================

    private final Runnable stopRefreshing = new Runnable() {
        @Override
        public void run() {
            if (swipe != null) swipe.setRefreshing(false);
        }
    };

    private void setupPullToRefresh() {
        swipe.setColorSchemeColors(RED_600, RED_700, RED_800);
        swipe.setOnChildScrollUpCallback(new SwipeRefreshLayout.OnChildScrollUpCallback() {
            @Override
            public boolean canChildScrollUp(SwipeRefreshLayout parent, View child) {
                return webView.getScrollY() > 0;
            }
        });
        swipe.setOnRefreshListener(new SwipeRefreshLayout.OnRefreshListener() {
            @Override
            public void onRefresh() {
                haptic("tick");
                updateCacheMode();
                swipe.removeCallbacks(stopRefreshing);
                if (offlineShown) {
                    retry();
                    swipe.postDelayed(stopRefreshing, 15000);
                    return;
                }
                webView.evaluateJavascript(
                        "(function(){if(window.TruAppBridge){TruAppBridge.refresh();return 'ok';}return 'none';})()",
                        new ValueCallback<String>() {
                            @Override
                            public void onReceiveValue(String value) {
                                if (value != null && value.contains("ok")) {
                                    swipe.postDelayed(stopRefreshing, 900);
                                } else {
                                    webView.reload();
                                    swipe.postDelayed(stopRefreshing, 15000);
                                }
                            }
                        });
            }
        });
    }

    private void doneRefreshing() {
        if (swipe != null) {
            swipe.removeCallbacks(stopRefreshing);
            swipe.setRefreshing(false);
        }
    }

    private void updateCacheMode() {
        webView.getSettings().setCacheMode(isOnline() ? WebSettings.LOAD_DEFAULT : WebSettings.LOAD_CACHE_ELSE_NETWORK);
    }

    // =====================================================================
    // Offline screen (native), retried by itself when the connection is back
    // =====================================================================

    private void setupOfflineView() {
        ((ImageView) findViewById(R.id.offline_icon)).setColorFilter(RED_700, PorterDuff.Mode.SRC_IN);
        ((TextView) findViewById(R.id.offline_title)).setTypeface(fontBold);
        ((TextView) findViewById(R.id.offline_text)).setTypeface(fontSemiBold);
        ((TextView) findViewById(R.id.offline_hint)).setTypeface(fontSemiBold);
        TextView retry = findViewById(R.id.offline_retry);
        retry.setTypeface(fontBold);
        retry.setOnClickListener(new View.OnClickListener() {
            @Override
            public void onClick(View v) {
                haptic("tick");
                retry();
            }
        });
    }

    private void showOffline() {
        if (offlineShown) return;
        offlineShown = true;
        offlineView.setAlpha(0f);
        offlineView.setVisibility(View.VISIBLE);
        offlineView.animate().alpha(1f).setDuration(200).start();
        View ring = findViewById(R.id.offline_ring);
        ring.setScaleX(0.85f);
        ring.setScaleY(0.85f);
        ring.animate().scaleX(1f).scaleY(1f).setDuration(320)
                .setInterpolator(new android.view.animation.OvershootInterpolator(2f)).start();
        updateChrome();
    }

    private void hideOffline() {
        if (!offlineShown) return;
        offlineShown = false;
        offlineView.animate().alpha(0f).setDuration(200).withEndAction(new Runnable() {
            @Override
            public void run() {
                if (!offlineShown) offlineView.setVisibility(View.GONE);
            }
        }).start();
        updateChrome();
    }

    private void retry() {
        updateCacheMode();
        String url = webView.getUrl();
        if (url == null || !url.startsWith("http")) url = HOME;
        webView.loadUrl(url);
    }

    private final BroadcastReceiver networkReceiver = new BroadcastReceiver() {
        @Override
        public void onReceive(Context context, Intent intent) {
            updateCacheMode();
            if (offlineShown && isOnline()) retry();
        }
    };

    private boolean isOnline() {
        ConnectivityManager cm = (ConnectivityManager) getSystemService(CONNECTIVITY_SERVICE);
        NetworkInfo n = cm != null ? cm.getActiveNetworkInfo() : null;
        return n != null && n.isConnected();
    }

    // =====================================================================
    // Keyboard: hide the tab bar and banner while typing
    // =====================================================================

    private void watchKeyboard() {
        root.getViewTreeObserver().addOnGlobalLayoutListener(new ViewTreeObserver.OnGlobalLayoutListener() {
            @Override
            public void onGlobalLayout() {
                android.graphics.Rect r = new android.graphics.Rect();
                root.getWindowVisibleDisplayFrame(r);
                int screen = root.getRootView().getHeight();
                boolean open = screen - r.bottom > screen * 0.2f;
                if (open != keyboardOpen) {
                    keyboardOpen = open;
                    updateChrome();
                }
            }
        });
    }

    // =====================================================================
    // Ads
    // =====================================================================

    private void startAds() {
        if (adsStarted || isFinishing()) return;
        adsStarted = true;
        MobileAds.initialize(this);
        setupAds();
    }

    private void setupAds() {
        bannerAd = new AdView(this);
        bannerAd.setAdUnitId(BANNER_AD_UNIT_ID);
        bannerAd.setAdSize(AdSize.SMART_BANNER);
        // The banner area stays hidden until an ad has loaded, so there is no empty gap.
        bannerAd.setAdListener(new AdListener() {
            @Override
            public void onAdLoaded() {
                adLoaded = true;
                updateChrome();
            }
        });
        adContainer.addView(bannerAd);
        bannerAd.loadAd(new AdRequest.Builder().build());

        interstitialAd = new InterstitialAd(this);
        interstitialAd.setAdUnitId(INTERSTITIAL_AD_UNIT_ID);
        interstitialAd.setAdListener(new AdListener() {
            @Override
            public void onAdClosed() {
                interstitialAd.loadAd(new AdRequest.Builder().build());
            }
        });
        interstitialAd.loadAd(new AdRequest.Builder().build());
    }

    private void showInterstitial() {
        navigationCount++;
        long now = System.currentTimeMillis();
        if (navigationCount % INTERSTITIAL_EVERY == 0
                && now - lastInterstitialAt > INTERSTITIAL_MIN_GAP_MS
                && interstitialAd != null
                && interstitialAd.isLoaded()) {
            lastInterstitialAt = now;
            interstitialAd.show();
        }
    }

    // =====================================================================
    // Back: the site decides (close the sheet, go up a page); on Home,
    // press twice to leave.
    // =====================================================================

    @Override
    public void onBackPressed() {
        if (offlineShown) {
            if (webView.canGoBack()) {
                hideOffline();
                webView.goBack();
            } else {
                confirmExit();
            }
            return;
        }
        goBack(true);
    }

    private void goBack(final boolean fromSystem) {
        webView.evaluateJavascript(
                "(function(){try{return window.TruAppBridge?TruAppBridge.back():'none';}catch(e){return 'none';}})()",
                new ValueCallback<String>() {
                    @Override
                    public void onReceiveValue(String value) {
                        String r = value == null ? "" : value.replace("\"", "");
                        if (r.equals("handled")) {
                            showInterstitial();
                        } else if (r.equals("exit")) {
                            if (fromSystem) confirmExit();
                        } else if (webView.canGoBack()) {
                            webView.goBack();
                            showInterstitial();
                        } else if (fromSystem) {
                            confirmExit();
                        }
                    }
                });
    }

    private void confirmExit() {
        long now = System.currentTimeMillis();
        if (now - lastBackPress < 2000) {
            finish();
        } else {
            lastBackPress = now;
            Toast.makeText(this, R.string.press_back_again, Toast.LENGTH_SHORT).show();
        }
    }

    // =====================================================================
    // Lifecycle
    // =====================================================================

    @Override
    protected void onSaveInstanceState(Bundle outState) {
        super.onSaveInstanceState(outState);
        webView.saveState(outState);
    }

    @Override
    protected void onResume() {
        super.onResume();
        updateCacheMode();
        webView.onResume();
        if (bannerAd != null) bannerAd.resume();
        // Ask the page for the bars' state again (balance may have changed meanwhile).
        webView.evaluateJavascript("window.TruAppBridge&&TruAppBridge.state()", null);
    }

    @Override
    protected void onPause() {
        if (bannerAd != null) bannerAd.pause();
        webView.onPause();
        if (Build.VERSION.SDK_INT >= 21) CookieManager.getInstance().flush();
        super.onPause();
    }

    @Override
    protected void onDestroy() {
        handler.removeCallbacksAndMessages(null);
        if (receiverRegistered) {
            try {
                unregisterReceiver(networkReceiver);
            } catch (IllegalArgumentException e) {
                // already gone
            }
        }
        if (heartbeat != null) heartbeat.cancel();
        if (bannerAd != null) bannerAd.destroy();
        webView.destroy();
        super.onDestroy();
    }

    private int dp(int value) {
        return Math.round(value * getResources().getDisplayMetrics().density);
    }
}
