package com.trudata.sms;

// Starts TRU SMS again after the phone restarts (or after the app is updated),
// if it was running before.

import android.content.BroadcastReceiver;
import android.content.Context;
import android.content.Intent;

public class BootReceiver extends BroadcastReceiver {
    @Override
    public void onReceive(Context c, Intent intent) {
        if (Gateway.wantRunning(c) && Gateway.code(c).length() == 20) {
            Gateway.log(c, "Phone restarted: starting again");
            try {
                GatewayService.start(c);
            } catch (Exception e) {
                Gateway.log(c, "Could not start after restart: open TRU SMS");
            }
        }
    }
}
