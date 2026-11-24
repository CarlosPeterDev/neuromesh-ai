package com.neuromesh.ai.stopfixture;

import android.app.Activity;
import android.app.Instrumentation;
import android.app.Notification;
import android.app.NotificationManager;
import android.content.Context;
import android.content.Intent;
import android.os.Bundle;
import android.os.SystemClock;
import android.service.notification.StatusBarNotification;
import android.util.Log;

import java.lang.reflect.Proxy;
import java.util.ArrayList;
import java.util.Collections;
import java.util.List;

/** Drives the packaged service's real Android notification pending intents. */
public final class BackgroundWorkSmoke extends Instrumentation {
    @Override
    public void onCreate(Bundle arguments) {
        super.onCreate(arguments);
        start();
    }

    @Override
    public void onStart() {
        Bundle result = new Bundle();
        try {
            checkStopActions();
            result.putString("stream", "\nBACKGROUND_WORK_NOTIFICATION_STOP_OK\n");
            finish(Activity.RESULT_OK, result);
        } catch (Throwable error) {
            result.putString("stream", "\n" + Log.getStackTraceString(error));
            finish(Activity.RESULT_CANCELED, result);
        }
    }

    private void checkStopActions() throws Exception {
        Context app = getTargetContext();
        Intent launch = app.getPackageManager().getLaunchIntentForPackage(app.getPackageName());
        require(launch != null, "target activity is missing");
        startActivitySync(launch);

        ClassLoader loader = app.getClassLoader();
        Class<?> service = loader.loadClass("com.neuromesh.ai.BackgroundWorkService");
        Object bridge = service.getField("Companion").get(null);
        Class<?> function = loader.loadClass("kotlin.jvm.functions.Function1");
        Object unit = loader.loadClass("kotlin.Unit").getField("INSTANCE").get(null);
        List<String> stopped = Collections.synchronizedList(new ArrayList<>());
        Object listener = Proxy.newProxyInstance(loader, new Class<?>[] {function},
                (proxy, method, args) -> {
                    stopped.add((String) args[0]);
                    return unit;
                });

        runOnMainSync(() -> {
            try {
                bridge.getClass().getMethod("setOnStopRequested", function).invoke(bridge, listener);
                bridge.getClass().getMethod("begin", Context.class, String.class, String.class)
                        .invoke(bridge, app, "model-test", "model");
                bridge.getClass().getMethod("begin", Context.class, String.class, String.class)
                        .invoke(bridge, app, "image-test", "image");
                bridge.getClass().getMethod("begin", Context.class, String.class, String.class)
                        .invoke(bridge, app, "relay-test", "relay");
            } catch (ReflectiveOperationException error) {
                throw new AssertionError(error);
            }
        });

        NotificationManager manager = app.getSystemService(NotificationManager.class);
        Notification model = awaitNotification(manager, 4203, "Local model loaded");
        Notification both = awaitNotification(manager, 4202, "NeuroMesh background work");
        Notification.Action image = action(both, "Stop image generation");
        action(both, "Stop remote access");
        getUiAutomation().executeShellCommand("input keyevent KEYCODE_HOME").close();
        SystemClock.sleep(400);
        action(model, "Stop model").actionIntent.send();
        long modelDeadline = SystemClock.elapsedRealtime() + 5000;
        while ((current(manager, 4203) != null || stopped.isEmpty())
                && SystemClock.elapsedRealtime() < modelDeadline) {
            SystemClock.sleep(50);
        }
        require(current(manager, 4203) == null, "loaded model notification remained");
        require(stopped.equals(Collections.singletonList("model-test")), "model stop reached the wrong job");
        require(current(manager, 4202) != null, "model stop removed the other jobs");
        image.actionIntent.send();
        Notification relay = awaitNotification(manager, 4202, "Remote access is on");
        require(stopped.size() == 2 && stopped.get(1).equals("image-test"), "wrong job stopped");
        image.actionIntent.send();
        action(relay, "Stop").actionIntent.send();
        long deadline = SystemClock.elapsedRealtime() + 5000;
        while ((current(manager, 4202) != null || stopped.size() < 3)
                && SystemClock.elapsedRealtime() < deadline) SystemClock.sleep(50);
        require(current(manager, 4202) == null, "notification remained after the last stop");
        require(stopped.size() == 3 && stopped.get(2).equals("relay-test"), "stale action stopped a job");

        runOnMainSync(() -> {
            try {
                bridge.getClass().getMethod("begin", Context.class, String.class, String.class)
                        .invoke(bridge, app, "idle-model-test", "model");
            } catch (ReflectiveOperationException error) {
                throw new AssertionError(error);
            }
        });
        Notification idleModel = awaitNotification(manager, 4203, "Local model loaded");
        require(current(manager, 4202) == null, "idle model started a foreground service");
        action(idleModel, "Stop model").actionIntent.send();
        deadline = SystemClock.elapsedRealtime() + 5000;
        while ((current(manager, 4203) != null || stopped.size() < 4)
                && SystemClock.elapsedRealtime() < deadline) SystemClock.sleep(50);
        require(current(manager, 4203) == null && stopped.size() == 4 &&
                stopped.get(3).equals("idle-model-test"), "idle model stop did not reach its owner");
    }

    private static Notification awaitNotification(NotificationManager manager, int id, String title) {
        long deadline = SystemClock.elapsedRealtime() + 5000;
        while (SystemClock.elapsedRealtime() < deadline) {
            Notification notification = current(manager, id);
            if (notification != null && title.contentEquals(notification.extras.getCharSequence(Notification.EXTRA_TITLE))) {
                return notification;
            }
            SystemClock.sleep(50);
        }
        throw new AssertionError("missing notification " + title);
    }

    private static Notification current(NotificationManager manager, int id) {
        for (StatusBarNotification entry : manager.getActiveNotifications()) {
            if (entry.getId() == id) return entry.getNotification();
        }
        return null;
    }

    private static Notification.Action action(Notification notification, String title) {
        for (Notification.Action action : notification.actions) {
            if (title.contentEquals(action.title)) return action;
        }
        throw new AssertionError("missing action " + title);
    }

    private static void require(boolean condition, String message) {
        if (!condition) throw new AssertionError(message);
    }
}
