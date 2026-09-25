package com.myassistant.myassistant

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.ServiceInfo
import android.media.AudioManager
import android.media.AudioRecordingConfiguration
import android.media.MediaRecorder
import android.os.Build
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.util.Log
import androidx.core.app.NotificationCompat
import androidx.core.app.ServiceCompat

/**
 * TASK VOICE: the microphone kept legally alive while another app is on
 * screen. This build carries only the P1 MIC PROBE.
 *
 * Owner, 2026-09-25: "start talk while it works". The plan
 * (Reports/Talk-While-It-Works-Plan-2026-09-25.md, sections 3 and 4) keeps
 * the voice session open while a task runs in Instagram or WhatsApp. Before
 * any of that is built, P1 answers one question on his own phone: does our
 * recorder keep hearing real sound when the app is off screen, with this
 * service holding the microphone? This service does NOT record anything
 * itself. It only holds the microphone "foreground service" slot that
 * Android requires for background capture, shows the notification, and
 * watches for the moments the microphone must be let go. The recorder is
 * the one the voice session already uses, started from Dart
 * (LiveService.probeMic), and its frames go to a counter, nowhere else.
 *
 * THE DOCUMENTED ROUTE, AND ONLY THAT ONE. A microphone foreground service
 * may only start while the app itself is in the foreground (Android's
 * "while-in-use" rule), so TaskVoiceBridge starts it with startService()
 * and only from the resumed MainActivity. Promotion to the foreground
 * (ServiceCompat.startForeground with the MICROPHONE type) is the first
 * thing onStartCommand does, and Dart is told "started" only after it
 * worked. A stop that arrives before promotion is kept and carried out
 * right after it.
 *
 * THE WATCHERS. Each one stops the service and tells Dart why:
 *  - audio mode IN_CALL or IN_COMMUNICATION: a phone call, or a WhatsApp,
 *    Meet or Instagram call. The listener on Android 12+, a 1 s poll below.
 *  - our recording "silenced": another app took the microphone from us
 *    (on Android 10+, when two apps want it the one that started last wins).
 *  - the screen turning off.
 *  - 60 seconds: the probe never runs longer.
 *  - Stop on the notification, the app swiped away (stopWithTask), Android
 *    ending the service.
 *
 * NO CONTENT INTENT on the notification, on purpose: tapping it must not
 * open the app, because in the real feature opening the app ends the task.
 */
class TaskVoiceService : Service() {

    companion object {
        private const val TAG = "hari/taskvoice"
        private const val CHANNEL_ID = "hari_mic_test"
        private const val NOTIFICATION_ID = 7301
        const val ACTION_START = "com.myassistant.myassistant.TASK_VOICE_START"
        const val ACTION_STOP = "com.myassistant.myassistant.TASK_VOICE_STOP"

        /** The probe stops itself after this long, whatever happens. */
        const val PROBE_CAP_MS = 60_000L
        private const val MODE_POLL_MS = 1_000L

        // WHY IT STOPPED. The wire contract with lib/services/task_voice.dart
        // (TaskVoiceStop); test/task_voice_test.dart reads these lines, so a
        // reason renamed on one side only fails the tests.
        const val REASON_REQUESTED = "requested"
        const val REASON_NOTIFICATION = "notification"
        const val REASON_TIME_CAP = "time_cap"
        const val REASON_CALL = "call"
        const val REASON_SILENCED = "silenced"
        const val REASON_SCREEN_OFF = "screen_off"
        const val REASON_TASK_REMOVED = "task_removed"
        const val REASON_DESTROYED = "destroyed"

        private val main = Handler(Looper.getMainLooper())

        // Everything below is touched on the main thread only: channel calls,
        // service callbacks and every watcher are delivered there.

        /** The live service instance, from onCreate to onDestroy. */
        private var current: TaskVoiceService? = null

        /** startService() was sent and promotion has not happened yet. */
        private var starting = false

        /** A stop asked for before promotion. Carried out right after it. */
        private var stopPending: String? = null

        /** Told once: promoted (true, audio mode) or refused (false, why). */
        private var onPromoted: ((Boolean, String?, Int?) -> Unit)? = null

        /** Every event for Dart ("silenced", "stopped"); set by the bridge. */
        var onEvent: ((Map<String, Any?>) -> Unit)? = null

        /** Starting, or running in the foreground. */
        val busy: Boolean
            get() = starting || (current?.let { it.promoted && !it.finished } ?: false)

        /**
         * Starts the service. The caller (TaskVoiceBridge) has already checked
         * that MainActivity is resumed; [promoted] is told the outcome.
         */
        fun start(ctx: Context, promoted: (Boolean, String?, Int?) -> Unit) {
            starting = true
            stopPending = null
            onPromoted = promoted
            try {
                ctx.startService(
                    Intent(ctx, TaskVoiceService::class.java).setAction(ACTION_START))
            } catch (e: Exception) {
                starting = false
                onPromoted = null
                promoted(false, "${e.javaClass.simpleName}: ${e.message}", null)
            }
        }

        /**
         * Stops it for [reason]. Before promotion the stop is deferred, not
         * dropped: it runs the moment promotion finishes. True when a stop
         * was carried out or deferred.
         */
        fun requestStop(reason: String): Boolean {
            val svc = current
            if (svc != null && svc.promoted && !svc.finished) {
                svc.finish(reason)
                return true
            }
            if (starting) {
                stopPending = reason
                return true
            }
            return false
        }

        /** For callers that only need it gone (later: the accessibility dead-man). */
        fun stopIfRunning(): Boolean = requestStop(REASON_REQUESTED)

        fun audioMode(ctx: Context): Int =
            (ctx.getSystemService(Context.AUDIO_SERVICE) as? AudioManager)?.mode ?: -1

        /** A phone call or a VoIP call (WhatsApp, Meet, Instagram) owns audio. */
        fun isCallMode(mode: Int): Boolean =
            mode == AudioManager.MODE_IN_CALL || mode == AudioManager.MODE_IN_COMMUNICATION

        fun status(ctx: Context): Map<String, Any?> = mapOf(
            "running" to (current?.let { it.promoted && !it.finished } ?: false),
            "starting" to starting,
            "mode" to audioMode(ctx),
            "sdk" to Build.VERSION.SDK_INT,
        )
    }

    private var promoted = false
    private var finished = false
    private var modeAtStart: Int? = null
    private lateinit var audio: AudioManager

    // Typed as Any: OnModeChangedListener is API 31 and isClientSilenced is
    // API 29, and minSdk is lower. Each is created only behind its check.
    private var modeListener: Any? = null
    private var recordingCallback: Any? = null
    private var modePoll: Runnable? = null
    private var screenReceiver: BroadcastReceiver? = null
    private val capStop = Runnable { finish(REASON_TIME_CAP) }

    /**
     * Recording sessions that already existed when the service started. Our
     * recorder starts after promotion, so a silenced VOICE_COMMUNICATION
     * session that is not in here is ours. (Android shows other apps'
     * recordings to us without their names, so this is how ours is told
     * apart.)
     */
    private val sessionsBefore = HashSet<Int>()

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onCreate() {
        super.onCreate()
        current = this
        audio = getSystemService(Context.AUDIO_SERVICE) as AudioManager
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when {
            // The notification's Stop. It never promotes anything.
            intent?.action == ACTION_STOP -> {
                if (!requestStop(REASON_NOTIFICATION) && !promoted) stopSelf(startId)
            }
            // Already in the foreground: a second start is refused by the
            // bridge, and promoting twice would only risk the running one.
            promoted -> Unit
            else -> promoteThenWatch()
        }
        // Never restarted by Android after a kill: a microphone must not
        // come back on by itself.
        return START_NOT_STICKY
    }

    /** PROMOTE FIRST. Nothing else happens before the startForeground call. */
    private fun promoteThenWatch() {
        val failure = try {
            ServiceCompat.startForeground(
                this, NOTIFICATION_ID, notification(),
                ServiceInfo.FOREGROUND_SERVICE_TYPE_MICROPHONE,
            )
            null
        } catch (e: Exception) {
            // SecurityException (no mic permission) or
            // ForegroundServiceStartNotAllowedException (not in the foreground).
            "${e.javaClass.simpleName}: ${e.message}"
        }
        starting = false
        val told = onPromoted
        onPromoted = null
        if (failure != null) {
            Log.w(TAG, "promotion refused: $failure")
            stopPending = null
            told?.invoke(false, failure, null)
            stopSelf()
            return
        }
        promoted = true
        modeAtStart = audio.mode
        Log.i(TAG, "promoted; audio mode $modeAtStart")
        told?.invoke(true, null, modeAtStart)
        val deferred = stopPending
        stopPending = null
        if (deferred != null) {
            finish(deferred)
            return
        }
        startWatchers()
    }

    private fun startWatchers() {
        // 1. CALLS. Already in one: let go at once.
        if (isCallMode(audio.mode)) {
            finish(REASON_CALL)
            return
        }
        if (Build.VERSION.SDK_INT >= 31) {
            val l = AudioManager.OnModeChangedListener { mode ->
                if (isCallMode(mode)) finish(REASON_CALL)
            }
            audio.addOnModeChangedListener(mainExecutor, l)
            modeListener = l
        } else {
            val poll = object : Runnable {
                override fun run() {
                    if (finished) return
                    if (isCallMode(audio.mode)) finish(REASON_CALL)
                    else main.postDelayed(this, MODE_POLL_MS)
                }
            }
            modePoll = poll
            main.postDelayed(poll, MODE_POLL_MS)
        }

        // 2. SILENCED: another app took the microphone from us.
        if (Build.VERSION.SDK_INT >= 29) {
            try {
                audio.activeRecordingConfigurations.forEach {
                    sessionsBefore.add(it.clientAudioSessionId)
                }
                val cb = object : AudioManager.AudioRecordingCallback() {
                    override fun onRecordingConfigChanged(
                        configs: MutableList<AudioRecordingConfiguration>?,
                    ) = checkSilenced(configs)
                }
                audio.registerAudioRecordingCallback(cb, main)
                recordingCallback = cb
            } catch (e: Exception) {
                Log.w(TAG, "recording callback unavailable: ${e.javaClass.simpleName}")
            }
        }

        // 3. SCREEN OFF. Only the system can send this broadcast (it is a
        // protected one), so an exported registration lets no app in; the
        // same convention as InstallWatch and AutomationBridge.
        val r = object : BroadcastReceiver() {
            override fun onReceive(c: Context, i: Intent) {
                if (i.action == Intent.ACTION_SCREEN_OFF) finish(REASON_SCREEN_OFF)
            }
        }
        try {
            val f = IntentFilter(Intent.ACTION_SCREEN_OFF)
            if (Build.VERSION.SDK_INT >= 33) {
                registerReceiver(r, f, Context.RECEIVER_EXPORTED)
            } else {
                registerReceiver(r, f)
            }
            screenReceiver = r
        } catch (e: Exception) {
            Log.w(TAG, "screen-off watch unavailable: ${e.javaClass.simpleName}")
        }

        // 4. THE PROBE'S CAP.
        main.postDelayed(capStop, PROBE_CAP_MS)
    }

    private fun checkSilenced(configs: List<AudioRecordingConfiguration>?) {
        if (finished || configs == null || Build.VERSION.SDK_INT < 29) return
        val oursSilenced = configs.any {
            it.clientAudioSource == MediaRecorder.AudioSource.VOICE_COMMUNICATION &&
                it.clientAudioSessionId !in sessionsBefore &&
                it.isClientSilenced
        }
        if (!oursSilenced) return
        emit(mapOf("event" to "silenced"))
        finish(REASON_SILENCED)
    }

    private fun stopWatchers() {
        main.removeCallbacks(capStop)
        modePoll?.let { main.removeCallbacks(it) }
        modePoll = null
        if (Build.VERSION.SDK_INT >= 31) {
            (modeListener as? AudioManager.OnModeChangedListener)?.let {
                try { audio.removeOnModeChangedListener(it) } catch (_: Exception) {}
            }
        }
        modeListener = null
        (recordingCallback as? AudioManager.AudioRecordingCallback)?.let {
            try { audio.unregisterAudioRecordingCallback(it) } catch (_: Exception) {}
        }
        recordingCallback = null
        screenReceiver?.let { try { unregisterReceiver(it) } catch (_: Exception) {} }
        screenReceiver = null
    }

    /** Stops for [reason], once, and tells Dart why and the audio mode. */
    private fun finish(reason: String) {
        if (finished) return
        finished = true
        stopWatchers()
        val modeEnd = audio.mode
        Log.i(TAG, "stopped: $reason; audio mode $modeAtStart -> $modeEnd")
        emit(mapOf(
            "event" to "stopped",
            "reason" to reason,
            "modeStart" to modeAtStart,
            "modeEnd" to modeEnd,
        ))
        try {
            ServiceCompat.stopForeground(this, ServiceCompat.STOP_FOREGROUND_REMOVE)
        } catch (_: Exception) {}
        stopSelf()
    }

    private fun emit(m: Map<String, Any?>) {
        try { onEvent?.invoke(m) } catch (e: Exception) {
            Log.w(TAG, "event not delivered: ${e.javaClass.simpleName}")
        }
    }

    override fun onTaskRemoved(rootIntent: Intent?) {
        // stopWithTask normally ends us without this call; kept so a swipe
        // away always lets the microphone go.
        if (promoted) finish(REASON_TASK_REMOVED)
        super.onTaskRemoved(rootIntent)
    }

    override fun onDestroy() {
        if (promoted) {
            finish(REASON_DESTROYED)
        } else {
            stopWatchers()
            if (starting) {
                // Ended before promotion: Dart must not wait for an answer.
                starting = false
                stopPending = null
                onPromoted?.invoke(false, "destroyed before promotion", null)
                onPromoted = null
            }
        }
        if (current === this) current = null
        super.onDestroy()
    }

    /**
     * Silent, ongoing, low importance, one Stop action, and NO content intent
     * (see the class comment).
     */
    private fun notification(): Notification {
        val nm = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        if (Build.VERSION.SDK_INT >= 26 && nm.getNotificationChannel(CHANNEL_ID) == null) {
            nm.createNotificationChannel(
                NotificationChannel(CHANNEL_ID, "Mic test", NotificationManager.IMPORTANCE_LOW)
                    .apply {
                        description = "Shown while the mic test in Diagnostics runs."
                        setSound(null, null)
                        enableVibration(false)
                        setShowBadge(false)
                    })
        }
        val stop = PendingIntent.getService(
            this, 1,
            Intent(this, TaskVoiceService::class.java).setAction(ACTION_STOP),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
        )
        return NotificationCompat.Builder(this, CHANNEL_ID)
            .setSmallIcon(R.drawable.ic_stat_hari)
            .setContentTitle("Mic test running")
            .setContentText("Counting sound levels for up to a minute. Nothing is recorded or sent.")
            .setOngoing(true)
            .setSilent(true)
            .setOnlyAlertOnce(true)
            .setPriority(NotificationCompat.PRIORITY_LOW)
            .setCategory(NotificationCompat.CATEGORY_SERVICE)
            // Shown at once: Android 12+ may otherwise hold a service's
            // notification back for up to 10 seconds.
            .setForegroundServiceBehavior(NotificationCompat.FOREGROUND_SERVICE_IMMEDIATE)
            .addAction(0, "Stop", stop)
            .build()
    }
}
