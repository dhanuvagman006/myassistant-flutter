package com.myassistant.myassistant

import android.Manifest
import android.app.Activity
import android.content.pm.PackageManager
import android.os.Handler
import android.os.Looper
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleOwner
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel
import java.lang.ref.WeakReference

/**
 * "hari/task_voice" (methods) and "hari/task_voice/events" (events): Dart's
 * line to TaskVoiceService.
 *
 * Owner, 2026-09-25: "start talk while it works". In this build the only
 * caller is the mic test on the Diagnostics screen (the P1 probe in the
 * plan); nothing else starts the service.
 *
 *  - start  -> {"ok": true, "mode": <audio mode>} once the service is in
 *              the foreground; an error when it could not get there. Only
 *              from the resumed MainActivity, because Android lets a
 *              microphone foreground service start only while the app is
 *              in front.
 *  - stop   -> {"stopped": <carried out or deferred>, "mode": <audio mode>}
 *  - status -> {"running", "starting", "mode", "sdk"}
 *  - events -> {"event": "silenced"} and
 *              {"event": "stopped", "reason", "modeStart", "modeEnd"}
 */
object TaskVoiceBridge {

    private val main = Handler(Looper.getMainLooper())
    private var activityRef: WeakReference<Activity>? = null
    private var sink: EventChannel.EventSink? = null

    fun register(messenger: BinaryMessenger, activity: Activity) {
        activityRef = WeakReference(activity)
        MethodChannel(messenger, "hari/task_voice").setMethodCallHandler { call, result ->
            when (call.method) {
                "start" -> start(result)
                "stop" -> {
                    val ctx = activityRef?.get()?.applicationContext
                    val stopped = TaskVoiceService.requestStop(TaskVoiceService.REASON_REQUESTED)
                    result.success(mapOf(
                        "stopped" to stopped,
                        "mode" to (ctx?.let { TaskVoiceService.audioMode(it) }),
                    ))
                }
                "status" -> {
                    val ctx = activityRef?.get()?.applicationContext
                    if (ctx == null) result.success(mapOf("running" to false))
                    else result.success(TaskVoiceService.status(ctx))
                }
                else -> result.notImplemented()
            }
        }
        EventChannel(messenger, "hari/task_voice/events").setStreamHandler(
            object : EventChannel.StreamHandler {
                override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                    sink = events
                }

                override fun onCancel(arguments: Any?) {
                    sink = null
                }
            })
        // Posted, so an event raised inside a service callback reaches Dart
        // on the main thread and after the call that caused it has returned.
        TaskVoiceService.onEvent = { m -> main.post { sink?.success(m) } }
    }

    private fun start(result: MethodChannel.Result) {
        val activity = activityRef?.get()
        val resumed = activity != null && !activity.isFinishing &&
            (activity as? LifecycleOwner)?.lifecycle?.currentState
                ?.isAtLeast(Lifecycle.State.RESUMED) == true
        if (!resumed) {
            result.error("not_resumed", "The app is not on screen.", null)
            return
        }
        if (TaskVoiceService.busy) {
            result.error("busy", "The mic test is already running.", null)
            return
        }
        // Android refuses a microphone foreground service without the
        // permission; asking here gives a clear answer instead of an
        // exception from inside the service.
        if (activity!!.checkSelfPermission(Manifest.permission.RECORD_AUDIO) !=
            PackageManager.PERMISSION_GRANTED) {
            result.error("no_mic_permission", "Microphone permission is needed.", null)
            return
        }
        var answered = false
        TaskVoiceService.start(activity) { ok, why, mode ->
            main.post {
                if (answered) return@post
                answered = true
                if (ok) result.success(mapOf("ok" to true, "mode" to mode))
                else result.error("promote_failed", why ?: "unknown", null)
            }
        }
    }
}
