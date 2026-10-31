// TRU Data Android app: a thin shell around the live website, with an AdMob banner.
//
// The app shows https://trudata.rvhssystems.com, so every change merged on
// GitHub (and published by GitHub Pages) is in the app the next time it opens.
// A new APK is only needed to change this file, the manifest or the ads.
//
// AIDE: keep the package line the same as your app's package (com.trudata.app),
// and put your banner ad unit ID in BANNER_AD_UNIT_ID below.
package com.trudata.app;

import android.annotation.SuppressLint;
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
import android.view.ViewGroup;
import android.view.Window;
import android.webkit.CookieManager;
import android.webkit.DownloadListener;
import android.webkit.WebChromeClient;
import android.webkit.WebSettings;
import android.webkit.WebView;
import android.webkit.WebViewClient;
import android.widget.FrameLayout;
import android.widget.LinearLayout;
import android.widget.ProgressBar;
import android.widget.Toast;

import com.google.android.gms.ads.AdListener;
import com.google.android.gms.ads.AdRequest;
import com.google.android.gms.ads.AdSize;
import com.google.android.gms.ads.AdView;
import com.google.android.gms.ads.MobileAds;

public class MainActivity extends Activity {

    // Your AdMob banner ad unit ID (AdMob → Apps → TRU Data → Ad units).
    // It looks like ca-app-pub-8934706810849620/1234567890 (a slash, not a ~).
    private static final String BANNER_AD_UNIT_ID = "ca-app-pub-8934706810849620/REPLACE_WITH_BANNER_ID";

    // The live site. Its pages and the Paystack checkout open in the app;
    // everything else (WhatsApp, Patupaa, phone calls, downloads) opens outside it.
    private static final String HOME = "https://trudata.rvhssystems.com/";
    private static final String SITE_HOST = "trudata.rvhssystems.com";
    private static final String[] IN_APP_HOSTS = {SITE_HOST, "checkout.paystack.com", "standard.paystack.co", "js.paystack.co"};
    private static final int BRAND_RED = Color.parseColor("#DC2626");

    private WebView web;
    private ProgressBar progress;
    private AdView banner;
    private boolean showingOffline = false;
    private long lastBackPress = 0;

    @SuppressLint("SetJavaScriptEnabled")
    @Override
    protected void onCreate(Bundle savedInstanceState) {
        super.onCreate(savedInstanceState);
        if (Build.VERSION.SDK_INT >= 21) {
            Window w = getWindow();
            w.setStatusBarColor(BRAND_RED);
        }

        // Page on top, a thin loading bar over it, the banner at the bottom.
        LinearLayout root = new LinearLayout(this);
        root.setOrientation(LinearLayout.VERTICAL);
        root.setBackgroundColor(Color.WHITE);

        FrameLayout page = new FrameLayout(this);
        web = new WebView(this);
        web.setBackgroundColor(Color.WHITE);
        page.addView(web, new FrameLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.MATCH_PARENT));
        progress = new ProgressBar(this, null, android.R.attr.progressBarStyleHorizontal);
        progress.setMax(100);
        if (Build.VERSION.SDK_INT >= 21) progress.setProgressTintList(android.content.res.ColorStateList.valueOf(BRAND_RED));
        page.addView(progress, new FrameLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, dp(3)));
        root.addView(page, new LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, 0, 1f));

        banner = new AdView(this);
        banner.setAdSize(AdSize.BANNER);
        banner.setAdUnitId(BANNER_AD_UNIT_ID);
        banner.setVisibility(View.GONE); // shown once an ad has loaded, so there is no empty gap
        LinearLayout.LayoutParams adParams = new LinearLayout.LayoutParams(ViewGroup.LayoutParams.WRAP_CONTENT, ViewGroup.LayoutParams.WRAP_CONTENT);
        adParams.gravity = android.view.Gravity.CENTER_HORIZONTAL;
        root.addView(banner, adParams);
        setContentView(root);

        setUpWebView();
        setUpAds();

        if (savedInstanceState != null) web.restoreState(savedInstanceState);
        else web.loadUrl(startUrl(getIntent()));
    }

    @SuppressLint("SetJavaScriptEnabled")
    private void setUpWebView() {
        WebSettings s = web.getSettings();
        s.setJavaScriptEnabled(true);
        // Keeps people signed in after the app is closed (the site stores the session here).
        s.setDomStorageEnabled(true);
        s.setDatabaseEnabled(true);
        // Fresh pages when online; the saved copy when the network is down.
        s.setCacheMode(isOnline() ? WebSettings.LOAD_DEFAULT : WebSettings.LOAD_CACHE_ELSE_NETWORK);
        s.setLoadWithOverviewMode(true);
        s.setUseWideViewPort(true);
        s.setSupportZoom(false);
        s.setTextZoom(100); // the phone's font size setting does not break the layout
        s.setMediaPlaybackRequiresUserGesture(true);
        // window.open() (WhatsApp report, Patupaa) goes through shouldOverrideUrlLoading below.
        s.setSupportMultipleWindows(false);
        s.setJavaScriptCanOpenWindowsAutomatically(true);
        // The site hides its "Download the app" buttons when it sees this.
        s.setUserAgentString(s.getUserAgentString() + " TruDataApp/2.0");

        CookieManager.getInstance().setAcceptCookie(true);
        if (Build.VERSION.SDK_INT >= 21) CookieManager.getInstance().setAcceptThirdPartyCookies(web, true);

        web.setWebChromeClient(new WebChromeClient() {
            @Override
            public void onProgressChanged(WebView view, int newProgress) {
                progress.setProgress(newProgress);
                progress.setVisibility(newProgress < 100 ? View.VISIBLE : View.GONE);
            }
        });
        web.setWebViewClient(new WebViewClient() {
            @Override
            @SuppressWarnings("deprecation")
            public boolean shouldOverrideUrlLoading(WebView view, String url) {
                return openOutsideIfNeeded(Uri.parse(url));
            }

            @Override
            public void onPageFinished(WebView view, String url) {
                // Save the sign-in cookie straight away, not only when the app closes.
                if (Build.VERSION.SDK_INT >= 21) CookieManager.getInstance().flush();
            }

            @Override
            @SuppressWarnings("deprecation")
            public void onReceivedError(WebView view, int code, String description, String failingUrl) {
                if (failingUrl != null && failingUrl.startsWith(HOME)) showOffline();
            }
        });
        // Anything the site offers as a download (the APK) is handed to the browser.
        web.setDownloadListener(new DownloadListener() {
            @Override
            public void onDownloadStart(String url, String userAgent, String contentDisposition, String mimetype, long length) {
                openExternal(Uri.parse(url));
            }
        });
    }

    private void setUpAds() {
        MobileAds.initialize(this);
        banner.setAdListener(new AdListener() {
            @Override
            public void onAdLoaded() {
                banner.setVisibility(View.VISIBLE);
            }
        });
        banner.loadAd(new AdRequest.Builder().build());
    }

    // Links like https://trudata.rvhssystems.com/?agent=AGT-123 open in the app.
    private String startUrl(Intent intent) {
        Uri data = intent != null ? intent.getData() : null;
        if (data != null && SITE_HOST.equals(data.getHost())) return data.toString();
        return HOME;
    }

    @Override
    protected void onNewIntent(Intent intent) {
        super.onNewIntent(intent);
        web.loadUrl(startUrl(intent));
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
        web.loadDataWithBaseURL(HOME, html, "text/html", "utf-8", null);
    }

    private boolean isOnline() {
        ConnectivityManager cm = (ConnectivityManager) getSystemService(CONNECTIVITY_SERVICE);
        NetworkInfo n = cm != null ? cm.getActiveNetworkInfo() : null;
        return n != null && n.isConnected();
    }

    private int dp(int value) {
        return Math.round(value * getResources().getDisplayMetrics().density);
    }

    // Back goes back a page in the site; on the first page, press twice to leave.
    @Override
    public boolean onKeyDown(int keyCode, KeyEvent event) {
        if (keyCode == KeyEvent.KEYCODE_BACK) {
            if (!showingOffline && web.canGoBack()) {
                web.goBack();
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
        web.saveState(outState);
    }

    @Override
    protected void onResume() {
        super.onResume();
        web.onResume();
        banner.resume();
    }

    @Override
    protected void onPause() {
        banner.pause();
        web.onPause();
        if (Build.VERSION.SDK_INT >= 21) CookieManager.getInstance().flush();
        super.onPause();
    }

    @Override
    protected void onDestroy() {
        banner.destroy();
        web.destroy();
        super.onDestroy();
    }
}
