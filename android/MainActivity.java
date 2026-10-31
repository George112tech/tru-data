package com.trudata.app;

// TRU Data Android app: a thin shell around the live website, with AdMob ads.
//
// The app shows https://trudata.rvhssystems.com instead of the copy of the
// site that used to be packed in assets/www, so every change merged on GitHub
// is in the app the next time it opens. A new APK is only needed to change
// this file, the layout, the manifest or the ads.
//
// Uses the app's existing layout (res/layout/activity_main.xml with
// @id/swipe_refresh, @id/webview, @id/progress_bar and @id/ad_container) and
// the existing AdMob SDK (InterstitialAd with isLoaded()).

import android.app.Activity;
import android.content.ActivityNotFoundException;
import android.content.Intent;
import android.graphics.Color;
import android.net.ConnectivityManager;
import android.net.NetworkInfo;
import android.net.Uri;
import android.os.Build;
import android.os.Bundle;
import android.view.KeyEvent;
import android.view.View;
import android.webkit.CookieManager;
import android.webkit.DownloadListener;
import android.webkit.WebChromeClient;
import android.webkit.WebSettings;
import android.webkit.WebView;
import android.webkit.WebViewClient;
import android.widget.FrameLayout;
import android.widget.ProgressBar;
import android.widget.Toast;

import androidx.swiperefreshlayout.widget.SwipeRefreshLayout;

import com.google.android.gms.ads.AdListener;
import com.google.android.gms.ads.AdRequest;
import com.google.android.gms.ads.AdSize;
import com.google.android.gms.ads.AdView;
import com.google.android.gms.ads.InterstitialAd;
import com.google.android.gms.ads.MobileAds;

public class MainActivity extends Activity {

    private static final String BANNER_AD_UNIT_ID =
            "ca-app-pub-8934706810849620/7330461846";

    private static final String INTERSTITIAL_AD_UNIT_ID =
            "ca-app-pub-8934706810849620/6017380172";

    // The live site. Its pages and the Paystack checkout open in the app;
    // everything else (WhatsApp, Patupaa, phone calls, downloads) opens outside it.
    private static final String HOME = "https://trudata.rvhssystems.com/";
    private static final String SITE_HOST = "trudata.rvhssystems.com";
    private static final String[] IN_APP_HOSTS = {SITE_HOST, "checkout.paystack.com", "standard.paystack.co", "js.paystack.co"};
    private static final int BRAND_RED = Color.parseColor("#DC2626");

    // Full-screen ad: every 3rd Back press, and never more than once a minute.
    private static final int INTERSTITIAL_EVERY = 3;
    private static final long INTERSTITIAL_MIN_GAP_MS = 60 * 1000;

    private WebView webView;
    private AdView bannerAd;
    private FrameLayout adContainer;
    private InterstitialAd interstitialAd;
    private ProgressBar progress;
    private SwipeRefreshLayout swipe;
    private int navigationCount = 0;
    private long lastInterstitialAt = 0;
    private long lastBackPress = 0;
    private boolean showingOffline = false;

    @Override
    protected void onCreate(Bundle savedInstanceState) {
        super.onCreate(savedInstanceState);
        setContentView(R.layout.activity_main);
        if (Build.VERSION.SDK_INT >= 21) getWindow().setStatusBarColor(BRAND_RED);

        MobileAds.initialize(this);

        webView = findViewById(R.id.webview);
        adContainer = findViewById(R.id.ad_container);
        swipe = findViewById(R.id.swipe_refresh);
        progress = findViewById(R.id.progress_bar);
        if (Build.VERSION.SDK_INT >= 21) progress.setProgressTintList(android.content.res.ColorStateList.valueOf(BRAND_RED));
        progress.setMax(100);

        setupWebView();
        setupPullToRefresh();
        setupAds();

        if (savedInstanceState != null) webView.restoreState(savedInstanceState);
        else loadWebApp(getIntent());
    }

    private void setupWebView() {
        WebSettings settings = webView.getSettings();
        settings.setJavaScriptEnabled(true);
        // Keeps people signed in after the app is closed (the site stores the session here).
        settings.setDomStorageEnabled(true);
        settings.setDatabaseEnabled(true);
        // Fresh pages when online; the saved copy when the network is down.
        settings.setCacheMode(isOnline() ? WebSettings.LOAD_DEFAULT : WebSettings.LOAD_CACHE_ELSE_NETWORK);
        settings.setLoadWithOverviewMode(true);
        settings.setUseWideViewPort(true);
        settings.setSupportZoom(false);
        settings.setTextZoom(100); // the phone's font size setting does not break the layout
        // window.open() (WhatsApp report, Patupaa) goes through shouldOverrideUrlLoading below.
        settings.setSupportMultipleWindows(false);
        settings.setJavaScriptCanOpenWindowsAutomatically(true);
        // The site hides its "Download the app" buttons when it sees this.
        settings.setUserAgentString(settings.getUserAgentString() + " TruDataApp/2.0");

        CookieManager.getInstance().setAcceptCookie(true);
        if (Build.VERSION.SDK_INT >= 21) CookieManager.getInstance().setAcceptThirdPartyCookies(webView, true);

        webView.setBackgroundColor(Color.WHITE);
        webView.setWebChromeClient(new WebChromeClient() {
            @Override
            public void onProgressChanged(WebView view, int newProgress) {
                progress.setProgress(newProgress);
                progress.setVisibility(newProgress < 100 ? View.VISIBLE : View.GONE);
                if (newProgress >= 100) doneRefreshing();
            }
        });
        webView.setWebViewClient(new WebViewClient() {
            @Override
            @SuppressWarnings("deprecation")
            public boolean shouldOverrideUrlLoading(WebView view, String url) {
                return openOutsideIfNeeded(Uri.parse(url));
            }

            @Override
            public void onPageFinished(WebView view, String url) {
                doneRefreshing();
                // Save the sign-in cookie straight away, not only when the app closes.
                if (Build.VERSION.SDK_INT >= 21) CookieManager.getInstance().flush();
            }

            @Override
            @SuppressWarnings("deprecation")
            public void onReceivedError(WebView view, int code, String description, String failingUrl) {
                doneRefreshing();
                if (failingUrl != null && failingUrl.startsWith(HOME)) showOffline();
            }
        });
        // Anything the site offers as a download (the APK) is handed to the browser.
        webView.setDownloadListener(new DownloadListener() {
            @Override
            public void onDownloadStart(String url, String userAgent, String contentDisposition, String mimetype, long length) {
                openExternal(Uri.parse(url));
            }
        });
    }

    // Pull down at the top of a page to reload it. The spinner always stops:
    // when the page has loaded, when it fails, or after 15 seconds at most.
    private final Runnable stopRefreshing = new Runnable() {
        @Override
        public void run() {
            if (swipe != null) swipe.setRefreshing(false);
        }
    };

    private void setupPullToRefresh() {
        swipe.setColorSchemeColors(BRAND_RED);
        // Only pull-to-refresh when the page is scrolled to the very top.
        swipe.setOnChildScrollUpCallback(new SwipeRefreshLayout.OnChildScrollUpCallback() {
            @Override
            public boolean canChildScrollUp(SwipeRefreshLayout parent, View child) {
                return webView.getScrollY() > 0;
            }
        });
        swipe.setOnRefreshListener(new SwipeRefreshLayout.OnRefreshListener() {
            @Override
            public void onRefresh() {
                updateCacheMode();
                if (showingOffline) {
                    showingOffline = false;
                    webView.loadUrl(HOME);
                } else {
                    webView.reload();
                }
                swipe.removeCallbacks(stopRefreshing);
                swipe.postDelayed(stopRefreshing, 15000);
            }
        });
    }

    private void doneRefreshing() {
        if (swipe != null) {
            swipe.removeCallbacks(stopRefreshing);
            swipe.setRefreshing(false);
        }
    }

    // Fresh pages when online; the saved copy only when the network is down.
    private void updateCacheMode() {
        webView.getSettings().setCacheMode(isOnline() ? WebSettings.LOAD_DEFAULT : WebSettings.LOAD_CACHE_ELSE_NETWORK);
    }

    private void setupAds() {
        bannerAd = new AdView(this);
        bannerAd.setAdUnitId(BANNER_AD_UNIT_ID);
        bannerAd.setAdSize(AdSize.SMART_BANNER);
        // The banner area stays hidden until an ad has loaded, so there is no empty gap.
        adContainer.setVisibility(View.GONE);
        bannerAd.setAdListener(new AdListener() {
            @Override
            public void onAdLoaded() {
                adContainer.setVisibility(View.VISIBLE);
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

    // Links like https://trudata.rvhssystems.com/?agent=AGT-123 open in the app.
    private void loadWebApp(Intent intent) {
        Uri data = intent != null ? intent.getData() : null;
        if (data != null && SITE_HOST.equals(data.getHost())) webView.loadUrl(data.toString());
        else webView.loadUrl(HOME);
    }

    @Override
    protected void onNewIntent(Intent intent) {
        super.onNewIntent(intent);
        loadWebApp(intent);
    }

    private boolean openOutsideIfNeeded(Uri uri) {
        String scheme = uri.getScheme() == null ? "" : uri.getScheme();
        String host = uri.getHost() == null ? "" : uri.getHost();
        if (scheme.equals("http") || scheme.equals("https")) {
            for (String h : IN_APP_HOSTS) {
                if (host.equals(h) || host.endsWith("." + h)) {
                    showingOffline = false;
                    return false;
                }
            }
        }
        openExternal(uri);
        return true;
    }

    private void openExternal(Uri uri) {
        try {
            startActivity(new Intent(Intent.ACTION_VIEW, uri));
        } catch (ActivityNotFoundException e) {
            Toast.makeText(this, "No app found to open this link", Toast.LENGTH_SHORT).show();
        }
    }

    private void showOffline() {
        showingOffline = true;
        String html = "<html><head><meta name='viewport' content='width=device-width,initial-scale=1'></head>"
                + "<body style='font-family:sans-serif;display:flex;align-items:center;justify-content:center;height:90vh;margin:0;text-align:center;color:#0f172a'>"
                + "<div style='padding:24px'><div style='font-size:48px'>&#128246;</div><h2>No internet connection</h2>"
                + "<p style='color:#64748b'>Check your mobile data or Wi-Fi, then try again.</p>"
                + "<a href='" + HOME + "' style='display:inline-block;margin-top:12px;background:#dc2626;color:#fff;padding:14px 28px;border-radius:14px;text-decoration:none;font-weight:bold'>Try again</a></div></body></html>";
        webView.loadDataWithBaseURL(HOME, html, "text/html", "utf-8", null);
    }

    private boolean isOnline() {
        ConnectivityManager cm = (ConnectivityManager) getSystemService(CONNECTIVITY_SERVICE);
        NetworkInfo n = cm != null ? cm.getActiveNetworkInfo() : null;
        return n != null && n.isConnected();
    }

    // Back goes back a page in the site (sometimes showing the full-screen ad);
    // on the first page, press twice to leave.
    @Override
    public boolean onKeyDown(int keyCode, KeyEvent event) {
        if (keyCode == KeyEvent.KEYCODE_BACK) {
            if (!showingOffline && webView.canGoBack()) {
                webView.goBack();
                showInterstitial();
                return true;
            }
            long now = System.currentTimeMillis();
            if (now - lastBackPress > 2000) {
                lastBackPress = now;
                Toast.makeText(this, "Press back again to exit", Toast.LENGTH_SHORT).show();
                return true;
            }
        }
        return super.onKeyDown(keyCode, event);
    }

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
        if (bannerAd != null) bannerAd.destroy();
        webView.destroy();
        super.onDestroy();
    }
}
