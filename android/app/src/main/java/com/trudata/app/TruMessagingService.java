package com.trudata.app;

import com.google.firebase.messaging.FirebaseMessagingService;
import com.google.firebase.messaging.RemoteMessage;

import org.json.JSONObject;

import java.util.Map;

/**
 * Receives push notifications from Firebase (2.1.9).
 *
 * While the app is closed or in the background, Android shows the
 * notification itself (it pops up at the top of the screen; tapping it opens
 * My Orders). This class is called when the app is open: it puts the
 * notification in the list quietly and asks the page to show its own pop-up.
 */
public class TruMessagingService extends FirebaseMessagingService {

    @Override
    public void onNewToken(String token) {
        Push.saveToken(this, token);
        MainActivity a = MainActivity.current;
        if (a != null) a.deliverPushToken(token);
    }

    @Override
    public void onMessageReceived(RemoteMessage message) {
        Map<String, String> data = message.getData();
        String title = data.get("title");
        String body = data.get("body");
        RemoteMessage.Notification n = message.getNotification();
        if (n != null) {
            if (n.getTitle() != null) title = n.getTitle();
            if (n.getBody() != null) body = n.getBody();
        }
        if (title == null) title = getString(R.string.app_name);
        if (body == null) body = "";
        String ref = data.get("ref");
        MainActivity a = MainActivity.current;
        boolean open = a != null && a.isOnScreen();
        Push.show(this, title, body, data.get("open"), ref != null ? "order-" + ref : null, open);
        if (open) {
            try {
                JSONObject o = new JSONObject();
                o.put("title", title);
                o.put("body", body);
                o.put("data", new JSONObject(data));
                a.deliverPush(o.toString());
            } catch (Exception e) {
                // the notification is already in the list
            }
        }
    }
}
