package com.myassistant.myassistant

import android.Manifest
import android.app.Activity
import android.content.Context
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.provider.CallLog
import android.provider.ContactsContract
import android.util.Log
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel
import java.lang.ref.WeakReference
import java.util.concurrent.Executors

/**
 * "hari/calls" — the phone's own call history, read ON the phone.
 *
 * Owner, 2026-09-24: "the calls should be connected — it should report
 * when we have any missed calls, or any info if user asks about calls".
 * The assistant used to guess ("you haven't missed any calls") because
 * nothing could read the log. This channel reads it; Dart turns the rows
 * into ONE short line for the assistant (at most five entries), so the
 * full list never leaves the handset.
 *
 * READ_CALL_LOG is asked HERE, not through permission_handler. Declaring
 * it in the manifest folds it into that plugin's "phone" group, whose
 * status is the strictest of the group — Permission.phone would then read
 * "denied" for everyone who allowed calls but not call history, the
 * incoming-call guard would switch itself off and the server would stop
 * offering calls at all. So the checks that used Permission.phone ask
 * this channel for the exact permission instead ("permissions").
 *
 * The same fold made Permission.phone.request() ask for call history
 * too, so the setup screen's "Phone" row would have shown the call-log
 * dialog at onboarding. The phone itself (READ_PHONE_STATE + CALL_PHONE,
 * one dialog) is asked here as well ("requestPhone"); call history is
 * asked only the first time the owner asks about his calls.
 */
object CallLogBridge {

    private const val TAG = "hari/calls"

    /** Ours alone; permission_handler ignores codes it did not send. */
    const val REQUEST_CODE = 7306
    const val REQUEST_CODE_PHONE = 7307

    /** Placing calls and hearing the phone ring — never call history. */
    private val PHONE_PERMISSIONS = arrayOf(
        Manifest.permission.READ_PHONE_STATE, Manifest.permission.CALL_PHONE)

    // Call-log types newer than the minimum SDK, as their fixed values.
    private const val TYPE_REJECTED = 5 // CallLog.Calls.REJECTED_TYPE (API 24)
    private const val TYPE_BLOCKED = 6 // CallLog.Calls.BLOCKED_TYPE (API 24)
    private const val TYPE_ANSWERED_ELSEWHERE = 7 // ANSWERED_EXTERNALLY_TYPE (API 25)

    /** A long history is a binder call per row — never scan it all. */
    private const val MAX_SCAN = 1500

    private val worker = Executors.newSingleThreadExecutor()
    private val main = Handler(Looper.getMainLooper())
    private var activityRef: WeakReference<Activity>? = null
    private var pending: MethodChannel.Result? = null
    private var pendingPhone: MethodChannel.Result? = null

    fun register(messenger: BinaryMessenger, activity: Activity) {
        activityRef = WeakReference(activity)
        MethodChannel(messenger, "hari/calls").setMethodCallHandler { call, result ->
            val ctx = activity.applicationContext
            when (call.method) {
                // Exact runtime permissions, one by one (see the note above).
                "permissions" -> result.success(mapOf(
                    "callLog" to granted(ctx, Manifest.permission.READ_CALL_LOG),
                    "phoneState" to granted(ctx, Manifest.permission.READ_PHONE_STATE),
                    "callPhone" to granted(ctx, Manifest.permission.CALL_PHONE),
                ))
                // The system dialog, asked only when the owner wanted their
                // calls. "granted" | "denied" | "blocked" (don't ask again).
                "requestCallLog" -> request(result)
                // The setup screen's "Phone" row: the phone permissions
                // alone, so onboarding never shows the call-history dialog.
                "requestPhone" -> requestPhone(result)
                "recent" -> {
                    if (!granted(ctx, Manifest.permission.READ_CALL_LOG)) {
                        result.error("no_permission", "call history permission is off", null)
                        return@setMethodCallHandler
                    }
                    val filter = call.argument<String>("filter") ?: "all"
                    val person = call.argument<String>("person") ?: ""
                    val sinceMs = call.argument<Number>("sinceMs")?.toLong() ?: 0L
                    val limit = (call.argument<Number>("limit")?.toInt() ?: 50).coerceIn(1, 200)
                    // Off the UI thread: a contacts lookup per unknown name
                    // is a binder round trip each.
                    worker.execute {
                        val out = try {
                            recent(ctx, filter, person, sinceMs, limit)
                        } catch (e: Throwable) {
                            Log.w(TAG, "call log read failed: ${e.javaClass.simpleName}")
                            null
                        }
                        main.post {
                            if (out == null) result.error("failed", "the call history could not be read", null)
                            else result.success(out)
                        }
                    }
                }
                else -> result.notImplemented()
            }
        }
    }

    private fun granted(ctx: Context, permission: String): Boolean =
        Build.VERSION.SDK_INT < 23 ||
            ctx.checkSelfPermission(permission) == PackageManager.PERMISSION_GRANTED

    private fun request(result: MethodChannel.Result) {
        val act = activityRef?.get()
        if (act == null) {
            result.success("denied")
            return
        }
        if (granted(act, Manifest.permission.READ_CALL_LOG)) {
            result.success("granted")
            return
        }
        if (pending != null) {
            // One dialog at a time; the second asker hears the first answer
            // by asking again after it.
            result.success("busy")
            return
        }
        pending = result
        try {
            act.requestPermissions(arrayOf(Manifest.permission.READ_CALL_LOG), REQUEST_CODE)
        } catch (e: Throwable) {
            pending = null
            Log.w(TAG, "permission request failed: ${e.javaClass.simpleName}")
            result.success("denied")
        }
    }

    private fun requestPhone(result: MethodChannel.Result) {
        val act = activityRef?.get()
        if (act == null) {
            result.success("denied")
            return
        }
        val missing = PHONE_PERMISSIONS.filter { !granted(act, it) }
        if (missing.isEmpty()) {
            result.success("granted")
            return
        }
        if (pendingPhone != null) {
            result.success("busy")
            return
        }
        pendingPhone = result
        try {
            // Both are in Android's phone group: one dialog.
            act.requestPermissions(missing.toTypedArray(), REQUEST_CODE_PHONE)
        } catch (e: Throwable) {
            pendingPhone = null
            Log.w(TAG, "phone permission request failed: ${e.javaClass.simpleName}")
            result.success("denied")
        }
    }

    /** MainActivity forwards every permission result; ours is ours. */
    fun onPermissionResult(activity: Activity, requestCode: Int, grantResults: IntArray): Boolean {
        if (requestCode == REQUEST_CODE_PHONE) {
            val r = pendingPhone ?: return true
            pendingPhone = null
            val status = when {
                PHONE_PERMISSIONS.all { granted(activity, it) } -> "granted"
                // An interrupted dialog answers with nothing: not a refusal.
                grantResults.isEmpty() -> "denied"
                Build.VERSION.SDK_INT >= 23 && PHONE_PERMISSIONS.any {
                    !granted(activity, it) && !activity.shouldShowRequestPermissionRationale(it)
                } -> "blocked"
                else -> "denied"
            }
            r.success(status)
            return true
        }
        if (requestCode != REQUEST_CODE) return false
        val r = pending ?: return true
        pending = null
        val ok = grantResults.isNotEmpty() && grantResults[0] == PackageManager.PERMISSION_GRANTED
        val status = when {
            ok -> "granted"
            // After a refusal, "no rationale" means Android will not show
            // the dialog again: only the settings screen can turn it on.
            Build.VERSION.SDK_INT >= 23 &&
                !activity.shouldShowRequestPermissionRationale(Manifest.permission.READ_CALL_LOG) -> "blocked"
            else -> "denied"
        }
        r.success(status)
        return true
    }

    /** The owner's words map onto Android's call types. */
    private fun typesFor(filter: String): Set<Int>? = when (filter) {
        // Voicemail is a call nobody picked up.
        "missed" -> setOf(CallLog.Calls.MISSED_TYPE, CallLog.Calls.VOICEMAIL_TYPE)
        "outgoing" -> setOf(CallLog.Calls.OUTGOING_TYPE)
        // Everything someone else placed to this phone, answered or not.
        "incoming" -> setOf(
            CallLog.Calls.INCOMING_TYPE, CallLog.Calls.MISSED_TYPE,
            CallLog.Calls.VOICEMAIL_TYPE, TYPE_REJECTED, TYPE_BLOCKED,
            TYPE_ANSWERED_ELSEWHERE)
        else -> null
    }

    private fun typeName(t: Int): String? = when (t) {
        CallLog.Calls.MISSED_TYPE, CallLog.Calls.VOICEMAIL_TYPE -> "missed"
        CallLog.Calls.INCOMING_TYPE, TYPE_ANSWERED_ELSEWHERE -> "incoming"
        CallLog.Calls.OUTGOING_TYPE -> "outgoing"
        TYPE_REJECTED -> "rejected"
        TYPE_BLOCKED -> "blocked"
        else -> null
    }

    private fun digits(s: String) = s.filter { it.isDigit() }

    /**
     * Newest first. [person] matches the name (case-insensitive, contains)
     * or the last ten digits of the number.
     */
    private fun recent(
        ctx: Context, filter: String, person: String, sinceMs: Long, limit: Int,
    ): List<Map<String, Any>> {
        val types = typesFor(filter)
        val sel = StringBuilder("${CallLog.Calls.DATE} >= ?")
        val args = arrayListOf(sinceMs.toString())
        if (types != null) {
            sel.append(" AND ${CallLog.Calls.TYPE} IN (${types.joinToString(",") { "?" }})")
            types.forEach { args.add(it.toString()) }
        }
        val want = person.trim().lowercase()
        val wantDigits = digits(person).takeLast(10)
        val canLookup = granted(ctx, Manifest.permission.READ_CONTACTS)
        val names = HashMap<String, String>() // number -> contact name, per read
        // Last ten digits -> name, read only after PhoneLookup misses once.
        var byDigits: Map<String, String>? = null
        val out = ArrayList<Map<String, Any>>()
        val proj = arrayOf(
            CallLog.Calls.CACHED_NAME, CallLog.Calls.NUMBER, CallLog.Calls.TYPE,
            CallLog.Calls.DATE, CallLog.Calls.DURATION)
        ctx.contentResolver.query(
            CallLog.Calls.CONTENT_URI, proj, sel.toString(), args.toTypedArray(),
            "${CallLog.Calls.DATE} DESC",
        )?.use { c ->
            var scanned = 0
            while (c.moveToNext() && out.size < limit && scanned < MAX_SCAN) {
                scanned++
                val type = typeName(c.getInt(2)) ?: continue
                val number = c.getString(1)?.trim().orEmpty()
                var name = c.getString(0)?.trim().orEmpty()
                if (name.isEmpty() && number.isNotEmpty() && canLookup) {
                    name = names.getOrPut(number) {
                        lookupName(ctx, number)
                            ?: (byDigits ?: contactsByDigits(ctx).also { byDigits = it })[
                                digits(number).takeLast(10)]
                            ?: ""
                    }
                }
                if (want.isNotEmpty()) {
                    val byName = name.isNotEmpty() && name.lowercase().contains(want)
                    val byNumber = wantDigits.length >= 4 &&
                        digits(number).takeLast(10).endsWith(wantDigits)
                    if (!byName && !byNumber) continue
                }
                out.add(mapOf(
                    "name" to name,
                    // Withheld numbers come back as "", "-1" or "-2".
                    "number" to (if (digits(number).length < 3) "" else number),
                    "type" to type,
                    "at" to c.getLong(3),
                    "durationSec" to c.getLong(4).toInt(),
                ))
            }
        }
        return out
    }

    /**
     * EVERY SAVED NUMBER, BY ITS LAST TEN DIGITS (2026-09-26). Owner: "check
     * users contact list if name is present". PhoneLookup matches a number
     * the way the dialler does, and a contact saved in another form
     * ("+91 63601 39965" against a logged "06360139965") can slip past it,
     * leaving a saved caller announced as a stranger. Read at most once per
     * call-log read, and only after such a miss.
     */
    private fun contactsByDigits(ctx: Context): Map<String, String> {
        val out = HashMap<String, String>()
        try {
            ctx.contentResolver.query(
                ContactsContract.CommonDataKinds.Phone.CONTENT_URI,
                arrayOf(
                    ContactsContract.CommonDataKinds.Phone.DISPLAY_NAME,
                    ContactsContract.CommonDataKinds.Phone.NUMBER),
                null, null, null,
            )?.use { c ->
                while (c.moveToNext()) {
                    val name = c.getString(0)?.trim().orEmpty()
                    val key = digits(c.getString(1).orEmpty()).takeLast(10)
                    if (name.isNotEmpty() && key.length >= 7) out.putIfAbsent(key, name)
                }
            }
        } catch (_: Throwable) {
            // No contacts to read: the number stays unnamed, as before.
        }
        return out
    }

    private fun lookupName(ctx: Context, number: String): String? = try {
        val uri = Uri.withAppendedPath(
            ContactsContract.PhoneLookup.CONTENT_FILTER_URI, Uri.encode(number))
        ctx.contentResolver.query(
            uri, arrayOf(ContactsContract.PhoneLookup.DISPLAY_NAME), null, null, null,
        )?.use { if (it.moveToFirst()) it.getString(0) else null }
    } catch (_: Throwable) {
        null
    }
}
