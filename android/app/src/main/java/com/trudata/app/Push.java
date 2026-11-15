package com.trudata.app;

import android.app.NotificationChannel;
import android.app.NotificationManager;
import android.app.PendingIntent;
import android.content.Context;
import android.content.Intent;
import android.os.Build;

import androidx.core.app.NotificationCompat;
import androidx.core.app.NotificationManagerCompat;
import androidx.core.content.ContextCompat;

/**
 * Push notifications (2.1.9): the two notification channels, this phone's
 * Firebase token, and showing a notification.
 *
 * "orders" (high importance) pops up at the top of the screen with sound and
 * vibration. "orders_quiet" is used while the app is open: the app already
 * shows the update on screen, so the notification only goes in the list.
 */
final class Push {
    static final String CHANNEL_ORDERS = "orders";
    static final String CHANNEL_QUIET = "orders_quiet";
    private static final String PREFS = "tru_push";
    private static final String KEY_TOKEN = "token";

    private Push() {
    }

    static void createChannels(Context c) {
        if (Build.VERSION.SDK_INT < 26) return;
        NotificationManager nm = (NotificationManager) c.getSystemService(Context.NOTIFICATION_SERVICE);
        if (nm == null) return;
        NotificationChannel orders = new NotificationChannel(CHANNEL_ORDERS,
                c.getString(R.string.notif_channel_orders), NotificationManager.IMPORTANCE_HIGH);
        orders.setDescription(c.getString(R.string.notif_channel_orders_desc));
        orders.enableVibration(true);
        orders.enableLights(true);
        orders.setLightColor(0xFFDC2626);
        nm.createNotificationChannel(orders);
        NotificationChannel quiet = new NotificationChannel(CHANNEL_QUIET,
                c.getString(R.string.notif_channel_quiet), NotificationManager.IMPORTANCE_LOW);
        quiet.setDescription(c.getString(R.string.notif_channel_quiet_desc));
        nm.createNotificationChannel(quiet);
    }

    static void saveToken(Context c, String token) {
        c.getSharedPreferences(PREFS, Context.MODE_PRIVATE).edit().putString(KEY_TOKEN, token == null ? "" : token).apply();
    }

    static String token(Context c) {
        return c.getSharedPreferences(PREFS, Context.MODE_PRIVATE).getString(KEY_TOKEN, "");
    }

    /** Shows a notification; tapping it opens the app on {@code open} (for example "#/my-orders"). */
    static void show(Context c, String title, String body, String open, String tag, boolean quiet) {
        createChannels(c);
        Intent i = new Intent(c, MainActivity.class);
        i.setFlags(Intent.FLAG_ACTIVITY_NEW_TASK | Intent.FLAG_ACTIVITY_SINGLE_TOP);
        if (open != null && open.startsWith("#/")) i.putExtra("open", open);
        int id = (tag != null && tag.length() > 0 ? tag : String.valueOf(System.currentTimeMillis())).hashCode();
        int flags = PendingIntent.FLAG_UPDATE_CURRENT;
        if (Build.VERSION.SDK_INT >= 23) flags |= PendingIntent.FLAG_IMMUTABLE;
        PendingIntent tap = PendingIntent.getActivity(c, id, i, flags);
        NotificationCompat.Builder b = new NotificationCompat.Builder(c, quiet ? CHANNEL_QUIET : CHANNEL_ORDERS)
                .setSmallIcon(R.drawable.ic_notification)
                .setColor(ContextCompat.getColor(c, R.color.brand_red))
                .setContentTitle(title)
                .setContentText(body)
                .setStyle(new NotificationCompat.BigTextStyle().bigText(body))
                .setCategory(NotificationCompat.CATEGORY_STATUS)
                .setAutoCancel(true)
                .setContentIntent(tap)
                .setPriority(quiet ? NotificationCompat.PRIORITY_LOW : NotificationCompat.PRIORITY_HIGH);
        if (!quiet) b.setDefaults(NotificationCompat.DEFAULT_ALL);
        try {
            NotificationManagerCompat.from(c).notify(id, b.build());
        } catch (SecurityException e) {
            // notifications switched off for the app
        }
    }
}
