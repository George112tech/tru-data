// TRU Data Android app: a thin shell around the live website.
//
// The app shows https://trudata.rvhssystems.com, so every change merged on
// GitHub (and published by GitHub Pages) is in the app the next time it opens.
// A new APK is only needed to change this file itself.
//
// AIDE: replace the package line below with your app's existing package name
// (keep it the same as the old app so the new APK installs over it).
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
import android.webkit.CookieManager;
import android.webkit.DownloadListener;
import android.webkit.WebChromeClient;
import android.webkit.WebResourceError;
import android.webkit.WebResourceRequest;
import android.webkit.WebSettings;
import android.webkit.WebView;
import android.webkit.WebViewClient;
import android.widget.Toast;

public class MainActivity extends Activity {

    // The live site. Pages inside this site open in the app; everything else
    // (WhatsApp, Patupaa, phone calls, app downloads) opens outside it.
    private static final String HOME = "https://trudata.rvhssystems.com/";
    private static final String SITE_HOST = "trudata.rvhssystems.com";
    // Paystack's payment window must also stay inside the app.
    private static final String[] IN_APP_HOSTS = {SITE_HOST, "checkout.paystack.com", "standard.paystack.co", "js.paystack.co"};

    private WebView web;

    @SuppressLint("SetJavaScriptEnabled")
    @Override
    protected void onCreate(Bundle savedInstanceState) {
        super.onCreate(savedInstanceState);
        web = new WebView(this);
        web.setBackgroundColor(Color.WHITE);
        setContentView(web);

        WebSettings s = web.getSettings();
        s.setJavaScriptEnabled(true);
        // Keeps people signed in after the app is closed (the site stores the session here).
        s.setDomStorageEnabled(true);
        s.setDatabaseEnabled(true);
        // Use the cached site when the network is slow; always fetch fresh pages when online.
        s.setCacheMode(isOnline() ? WebSettings.LOAD_DEFAULT : WebSettings.LOAD_CACHE_ELSE_NETWORK);
        s.setLoadWithOverviewMode(true);
        s.setUseWideViewPort(true);
        s.setSupportZoom(false);
        s.setMediaPlaybackRequiresUserGesture(true);
        // window.open() (WhatsApp report, Patupaa) loads through shouldOverrideUrlLoading below.
        s.setSupportMultipleWindows(false);
        s.setJavaScriptCanOpenWindowsAutomatically(true);
        // The site hides its "Download the app" buttons when it sees this.
        s.setUserAgentString(s.getUserAgentString() + " TruDataApp/2.0");

        CookieManager.getInstance().setAcceptCookie(true);
        if (Build.VERSION.SDK_INT >= 21) CookieManager.getInstance().setAcceptThirdPartyCookies(web, true);

        web.setWebChromeClient(new WebChromeClient());
        web.setWebViewClient(new WebViewClient() {
            @Override
            public boolean shouldOverrideUrlLoading(WebView view, String url) {
                return openOutsideIfNeeded(Uri.parse(url));
            }

            @Override
            public boolean shouldOverrideUrlLoading(WebView view, WebResourceRequest request) {
                return openOutsideIfNeeded(request.getUrl());
            }

            @Override
            public void onReceivedError(WebView view, WebResourceRequest request, WebResourceError error) {
                if (Build.VERSION.SDK_INT >= 21 && request.isForMainFrame()) showOffline();
            }

            @Override
            public void onReceivedError(WebView view, int code, String description, String failingUrl) {
                showOffline();
            }
        });
        // Anything the site offers as a download (the APK) is handed to the browser.
        web.setDownloadListener(new DownloadListener() {
            @Override
            public void onDownloadStart(String url, String userAgent, String contentDisposition, String mimetype, long length) {
                openExternal(Uri.parse(url));
            }
        });

        if (savedInstanceState != null) web.restoreState(savedInstanceState);
        else web.loadUrl(startUrl(getIntent()));
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
            for (String h : IN_APP_HOSTS) if (host.equals(h) || host.endsWith("." + h)) return false;
            // Supabase sign-in links (password reset) go through the site; files go to the browser.
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
        String html = "<html><head><meta name='viewport' content='width=device-width,initial-scale=1'></head>"
                + "<body style='font-family:sans-serif;display:flex;align-items:center;justify-content:center;height:90vh;text-align:center;color:#0f172a'>"
                + "<div><h2>No internet connection</h2><p style='color:#64748b'>Check your data or Wi-Fi and try again.</p>"
                + "<a href='" + HOME + "' style='display:inline-block;margin-top:12px;background:#dc2626;color:#fff;padding:14px 28px;border-radius:14px;text-decoration:none;font-weight:bold'>Try again</a></div></body></html>";
        web.loadDataWithBaseURL(HOME, html, "text/html", "utf-8", HOME);
    }

    private boolean isOnline() {
        ConnectivityManager cm = (ConnectivityManager) getSystemService(CONNECTIVITY_SERVICE);
        NetworkInfo n = cm != null ? cm.getActiveNetworkInfo() : null;
        return n != null && n.isConnected();
    }

    // The phone's Back button goes back a page in the site before leaving the app.
    @Override
    public boolean onKeyDown(int keyCode, KeyEvent event) {
        if (keyCode == KeyEvent.KEYCODE_BACK && web.canGoBack()) {
            web.goBack();
            return true;
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
    }

    @Override
    protected void onPause() {
        web.onPause();
        super.onPause();
    }
}
