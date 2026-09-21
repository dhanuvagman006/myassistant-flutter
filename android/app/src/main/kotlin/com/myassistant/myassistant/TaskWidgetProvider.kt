package com.myassistant.myassistant

import android.app.PendingIntent
import android.appwidget.AppWidgetManager
import android.appwidget.AppWidgetProvider
import android.content.Context
import android.content.Intent
import android.widget.RemoteViews

/**
 * THE HOME-SCREEN ORB.
 *
 * His ask, 2026-09-21: "add a feature to add a widget that I can save to
 * my phone's home screen where it's not like a realtime communication —
 * I will click on that mic orb and assign tasks that the agent should
 * properly analyse and do completely."
 *
 * So this is a SHORTCUT, not a second assistant. It holds no state, runs
 * no service, and asks for no updates (updatePeriodMillis is 0): one tap
 * opens the app straight onto the quick-task capture. Everything real
 * happens on the server, and the answer comes back as a notification.
 *
 * Why not capture the voice in the widget itself: a RemoteViews layout
 * cannot record audio, and a background service that could would be a
 * microphone the user cannot see running. The app opening for three
 * seconds is the honest version.
 */
class TaskWidgetProvider : AppWidgetProvider() {

    override fun onUpdate(
        context: Context,
        manager: AppWidgetManager,
        ids: IntArray
    ) {
        for (id in ids) {
            val views = RemoteViews(context.packageName, R.layout.widget_task)

            val intent = Intent(context, MainActivity::class.java).apply {
                action = ACTION_QUICK_TASK
                // A widget tap must land on the capture even when the app
                // is already open behind it — without CLEAR_TOP the
                // existing task comes forward on whatever screen it was
                // last on and the tap appears to do nothing.
                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP)
                putExtra(EXTRA_QUICK_TASK, true)
            }
            val pending = PendingIntent.getActivity(
                context,
                REQUEST_CODE,
                intent,
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
            )
            views.setOnClickPendingIntent(R.id.widget_root, pending)
            manager.updateAppWidget(id, views)
        }
    }

    companion object {
        const val ACTION_QUICK_TASK = "com.myassistant.myassistant.QUICK_TASK"
        const val EXTRA_QUICK_TASK = "quick_task"
        private const val REQUEST_CODE = 9310
    }
}
