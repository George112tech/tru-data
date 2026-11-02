# The page talks to the app through these methods (window.TruApp).
-keepclassmembers class com.trudata.app.MainActivity$Bridge {
    @android.webkit.JavascriptInterface <methods>;
}
-keepattributes JavascriptInterface
