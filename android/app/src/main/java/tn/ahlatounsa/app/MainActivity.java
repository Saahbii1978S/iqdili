package tn.ahlatounsa.app;

import android.app.Activity;
import android.content.Intent;
import android.content.pm.PackageManager;
import android.Manifest;
import android.net.Uri;
import android.os.Bundle;
import android.os.Build;
import android.webkit.CookieManager;
import android.webkit.ValueCallback;
import android.webkit.WebChromeClient;
import android.webkit.WebResourceRequest;
import android.webkit.WebSettings;
import android.webkit.WebView;
import android.webkit.WebViewClient;
import android.webkit.GeolocationPermissions;
import android.webkit.JavascriptInterface;
import android.widget.Toast;
import android.view.WindowInsets;
import android.graphics.Insets;
import android.window.OnBackInvokedCallback;
import android.window.OnBackInvokedDispatcher;

public class MainActivity extends Activity {
    private static final String HOME = "https://saahbii1978s.github.io/iqdili/";
    private static final String HOST = "saahbii1978s.github.io";
    private static final int FILE_CHOOSER_REQUEST = 701;
    private static final int LOCATION_PERMISSION_REQUEST = 702;
    private WebView webView;
    private ValueCallback<Uri[]> fileChooserCallback;
    private GeolocationPermissions.Callback pendingGeoCallback;
    private String pendingGeoOrigin;
    private OnBackInvokedCallback backInvokedCallback;

    public class ShareBridge {
        @JavascriptInterface
        public void share(String title, String message, String url) {
            runOnUiThread(() -> {
                Intent sendIntent = new Intent(Intent.ACTION_SEND);
                sendIntent.setType("text/plain");
                String content = (message == null ? "" : message.trim());
                if (url != null && !url.trim().isEmpty() && !content.contains(url.trim())) {
                    content = content.isEmpty() ? url.trim() : content + "\n" + url.trim();
                }
                sendIntent.putExtra(Intent.EXTRA_TEXT, content);
                try {
                    startActivity(Intent.createChooser(sendIntent,
                            (title == null || title.trim().isEmpty()) ? "مشاركة أحلى توانسة" : title));
                } catch (Exception e) {
                    Toast.makeText(MainActivity.this, "ما نجّمش نفتح قائمة المشاركة", Toast.LENGTH_SHORT).show();
                }
            });
        }
    }

    @Override
    protected void onCreate(Bundle savedInstanceState) {
        super.onCreate(savedInstanceState);
        webView = new WebView(this);
        setContentView(webView);

        // Target SDK 36 enforces edge-to-edge. Keep the WebView's interactive
        // content clear of status/navigation bars and display cutouts.
        final int basePaddingLeft = webView.getPaddingLeft();
        final int basePaddingTop = webView.getPaddingTop();
        final int basePaddingRight = webView.getPaddingRight();
        final int basePaddingBottom = webView.getPaddingBottom();
        webView.setOnApplyWindowInsetsListener((view, insets) -> {
            int left, top, right, bottom;
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
                Insets safe = insets.getInsets(
                        WindowInsets.Type.systemBars() | WindowInsets.Type.displayCutout());
                left = safe.left;
                top = safe.top;
                right = safe.right;
                bottom = safe.bottom;
            } else {
                left = insets.getSystemWindowInsetLeft();
                top = insets.getSystemWindowInsetTop();
                right = insets.getSystemWindowInsetRight();
                bottom = insets.getSystemWindowInsetBottom();
            }
            view.setPadding(basePaddingLeft + left, basePaddingTop + top,
                    basePaddingRight + right, basePaddingBottom + bottom);
            return insets;
        });
        webView.requestApplyInsets();

        // Android 13+ predictive-back dispatch no longer relies on onBackPressed.
        if (Build.VERSION.SDK_INT >= 33) {
            backInvokedCallback = () -> navigateBack();
            getOnBackInvokedDispatcher().registerOnBackInvokedCallback(
                    OnBackInvokedDispatcher.PRIORITY_DEFAULT, backInvokedCallback);
        }

        WebSettings settings = webView.getSettings();
        settings.setJavaScriptEnabled(true);
        settings.setDomStorageEnabled(true);
        settings.setCacheMode(WebSettings.LOAD_DEFAULT);
        settings.setLoadsImagesAutomatically(true);
        settings.setDatabaseEnabled(false);
        settings.setAllowFileAccess(false);
        settings.setAllowContentAccess(true);
        settings.setMixedContentMode(WebSettings.MIXED_CONTENT_NEVER_ALLOW);
        settings.setJavaScriptCanOpenWindowsAutomatically(false);
        settings.setSupportMultipleWindows(false);
        settings.setGeolocationEnabled(true);
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            settings.setSafeBrowsingEnabled(true);
        }

        webView.addJavascriptInterface(new ShareBridge(), "AndroidShare");
        CookieManager.getInstance().setAcceptCookie(true);
        CookieManager.getInstance().setAcceptThirdPartyCookies(webView, true);

        webView.setWebViewClient(new WebViewClient() {
            @Override
            public boolean shouldOverrideUrlLoading(WebView view, WebResourceRequest request) {
                return routeUrl(request.getUrl());
            }

            @Override
            public boolean shouldOverrideUrlLoading(WebView view, String url) {
                return routeUrl(Uri.parse(url));
            }
        });

        webView.setWebChromeClient(new WebChromeClient() {
            @Override
            public boolean onShowFileChooser(WebView view, ValueCallback<Uri[]> callback,
                    FileChooserParams params) {
                if (fileChooserCallback != null) fileChooserCallback.onReceiveValue(null);
                fileChooserCallback = callback;
                try {
                    startActivityForResult(params.createIntent(), FILE_CHOOSER_REQUEST);
                    return true;
                } catch (Exception e) {
                    fileChooserCallback = null;
                    callback.onReceiveValue(null);
                    Toast.makeText(MainActivity.this, "ما نجّمش نفتح معرض الصور", Toast.LENGTH_SHORT).show();
                    return false;
                }
            }

            @Override
            public void onGeolocationPermissionsShowPrompt(String origin,
                    GeolocationPermissions.Callback callback) {
                Uri requestingOrigin = Uri.parse(origin);
                boolean trustedOrigin = "https".equalsIgnoreCase(requestingOrigin.getScheme())
                        && HOST.equalsIgnoreCase(requestingOrigin.getHost());
                if (!trustedOrigin) {
                    callback.invoke(origin, false, false);
                    return;
                }

                boolean fineGranted = checkSelfPermission(Manifest.permission.ACCESS_FINE_LOCATION)
                        == PackageManager.PERMISSION_GRANTED;
                boolean coarseGranted = checkSelfPermission(Manifest.permission.ACCESS_COARSE_LOCATION)
                        == PackageManager.PERMISSION_GRANTED;
                if (fineGranted || coarseGranted) {
                    callback.invoke(origin, true, false);
                    return;
                }

                if (pendingGeoCallback != null) {
                    pendingGeoCallback.invoke(pendingGeoOrigin, false, false);
                }
                pendingGeoOrigin = origin;
                pendingGeoCallback = callback;
                requestPermissions(new String[] {
                        Manifest.permission.ACCESS_FINE_LOCATION,
                        Manifest.permission.ACCESS_COARSE_LOCATION
                }, LOCATION_PERMISSION_REQUEST);
            }
        });

        if (savedInstanceState == null) webView.loadUrl(HOME);
        else webView.restoreState(savedInstanceState);
    }

    private boolean routeUrl(Uri uri) {
        String scheme = uri.getScheme() == null ? "" : uri.getScheme().toLowerCase();
        String path = uri.getPath() == null ? "" : uri.getPath();
        boolean isProjectPage = "https".equals(scheme)
                && HOST.equalsIgnoreCase(uri.getHost())
                && ("/iqdili".equals(path) || path.startsWith("/iqdili/"));
        if (isProjectPage) return false;

        if ("http".equals(scheme) || "https".equals(scheme)
                || "tel".equals(scheme) || "mailto".equals(scheme)
                || "sms".equals(scheme) || "whatsapp".equals(scheme)) {
            try {
                startActivity(new Intent(Intent.ACTION_VIEW, uri));
            } catch (Exception e) {
                Toast.makeText(this, "ما نجّمش نفتح الرابط على الهاتف", Toast.LENGTH_SHORT).show();
            }
        }
        return true;
    }

    @Override
    public void onRequestPermissionsResult(int requestCode, String[] permissions, int[] grantResults) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults);
        if (requestCode == LOCATION_PERMISSION_REQUEST && pendingGeoCallback != null) {
            boolean fineGranted = checkSelfPermission(Manifest.permission.ACCESS_FINE_LOCATION)
                    == PackageManager.PERMISSION_GRANTED;
            boolean coarseGranted = checkSelfPermission(Manifest.permission.ACCESS_COARSE_LOCATION)
                    == PackageManager.PERMISSION_GRANTED;
            pendingGeoCallback.invoke(pendingGeoOrigin, fineGranted || coarseGranted, false);
            pendingGeoCallback = null;
            pendingGeoOrigin = null;
        }
    }

    @Override
    protected void onActivityResult(int requestCode, int resultCode, Intent data) {
        super.onActivityResult(requestCode, resultCode, data);
        if (requestCode == FILE_CHOOSER_REQUEST && fileChooserCallback != null) {
            Uri[] results = WebChromeClient.FileChooserParams.parseResult(resultCode, data);
            fileChooserCallback.onReceiveValue(results);
            fileChooserCallback = null;
        }
    }

    @Override
    protected void onSaveInstanceState(Bundle outState) {
        if (webView != null) webView.saveState(outState);
        super.onSaveInstanceState(outState);
    }

    @Override
    protected void onPause() {
        if (webView != null) webView.onPause();
        super.onPause();
    }

    @Override
    protected void onResume() {
        super.onResume();
        if (webView != null) webView.onResume();
    }

    private void navigateBack() {
        if (webView != null && webView.canGoBack()) webView.goBack();
        else finish();
    }

    @Override
    public void onBackPressed() {
        if (Build.VERSION.SDK_INT < 33) {
            if (webView != null && webView.canGoBack()) webView.goBack();
            else super.onBackPressed();
        } else {
            super.onBackPressed();
        }
    }

    @Override
    protected void onDestroy() {
        if (Build.VERSION.SDK_INT >= 33 && backInvokedCallback != null) {
            getOnBackInvokedDispatcher().unregisterOnBackInvokedCallback(backInvokedCallback);
            backInvokedCallback = null;
        }
        if (fileChooserCallback != null) {
            fileChooserCallback.onReceiveValue(null);
            fileChooserCallback = null;
        }
        if (pendingGeoCallback != null) {
            pendingGeoCallback.invoke(pendingGeoOrigin, false, false);
            pendingGeoCallback = null;
            pendingGeoOrigin = null;
        }
        if (webView != null) {
            webView.stopLoading();
            webView.destroy();
            webView = null;
        }
        super.onDestroy();
    }
}
