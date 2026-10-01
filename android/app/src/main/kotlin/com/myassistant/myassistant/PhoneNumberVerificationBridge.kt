package com.myassistant.myassistant

import android.app.Activity
import android.os.Build
import android.util.Log
import com.google.firebase.pnv.FirebasePhoneNumberVerification
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel
import java.lang.ref.WeakReference

/**
 * "hari/phone_number" — Firebase Phone Number Verification.
 *
 * Owner, 2026-09-29: remove the SMS code "completely and implement Firebase
 * Phone Number Verification". Google reads the number of the SIM in this
 * phone from its carrier, after Android's own consent sheet (Credential
 * Manager), and returns a token signed for our Firebase project. The token,
 * never the digits, goes to POST /phone/verify, which checks it (backend
 * src/services/pnv.js). No code is sent or typed.
 *
 *  - support -> {"supported": Boolean, "sims": Int, "reason"?: String}.
 *               True when at least one SIM's carrier takes part. In
 *               September 2026 that is 12 countries, and no Indian carrier.
 *  - verify  -> {"ok": true, "token": String, "phone": String} or
 *               {"ok": false, "code": "cancelled" | "unsupported" |
 *               "not_enabled" | "network" | "failed", "message": String}.
 *
 * Neither ever throws to Dart. Android 8 (API 26) is the documented minimum.
 */
object PhoneNumberVerificationBridge {

    private const val TAG = "hari/pnv"
    private var activityRef: WeakReference<Activity>? = null

    fun register(messenger: BinaryMessenger, activity: Activity) {
        activityRef = WeakReference(activity)
        MethodChannel(messenger, "hari/phone_number").setMethodCallHandler { call, result ->
            when (call.method) {
                "support" -> support(result)
                "verify" -> verify(result)
                else -> result.notImplemented()
            }
        }
    }

    private fun unsupported(reason: String) =
        mapOf("supported" to false, "sims" to 0, "reason" to reason)

    private fun support(result: MethodChannel.Result) {
        if (Build.VERSION.SDK_INT < 26) {
            result.success(unsupported("android_version"))
            return
        }
        try {
            FirebasePhoneNumberVerification.getInstance().getVerificationSupportInfo()
                .addOnSuccessListener { sims ->
                    result.success(mapOf(
                        "supported" to sims.any { it.isSupported() },
                        "sims" to sims.size))
                }
                .addOnFailureListener { e ->
                    Log.w(TAG, "support check failed: ${e.javaClass.name}: ${e.message}")
                    result.success(unsupported(codeOf(e)))
                }
        } catch (e: Exception) {
            Log.w(TAG, "support check threw: ${e.javaClass.name}: ${e.message}")
            result.success(unsupported(codeOf(e)))
        }
    }

    private fun failed(code: String, message: String?) =
        mapOf("ok" to false, "code" to code, "message" to (message ?: ""))

    private fun verify(result: MethodChannel.Result) {
        val activity = activityRef?.get()
        if (activity == null || activity.isFinishing) {
            result.success(failed("failed", "The app is not on screen."))
            return
        }
        if (Build.VERSION.SDK_INT < 26) {
            result.success(failed("unsupported", "Needs Android 8 or newer."))
            return
        }
        try {
            // One call does it all: Android's consent sheet, Google's request
            // to the carrier, and the signed token.
            FirebasePhoneNumberVerification.getInstance().getVerifiedPhoneNumber(activity)
                .addOnSuccessListener { r ->
                    val token = r.getToken()
                    if (token.isNullOrBlank()) {
                        result.success(failed("failed", "No token came back."))
                    } else {
                        result.success(mapOf("ok" to true, "token" to token, "phone" to (r.getPhoneNumber() ?: "")))
                    }
                }
                .addOnFailureListener { e ->
                    Log.w(TAG, "verify failed: ${e.javaClass.name}: ${e.message}")
                    result.success(failed(codeOf(e), e.message))
                }
        } catch (e: Exception) {
            Log.w(TAG, "verify threw: ${e.javaClass.name}: ${e.message}")
            result.success(failed(codeOf(e), e.message))
        }
    }

    /**
     * Sorted by class NAME and message: the SDK does not document its
     * exception types yet, and Credential Manager's (a cancelled sheet, an
     * unsupported SIM) arrive wrapped. Checked newest-first down the causes.
     */
    internal fun codeOf(e: Throwable): String {
        val chain = generateSequence(e) { it.cause }.take(6).toList()
        val names = chain.joinToString(" ") { it.javaClass.name }
        val text = chain.joinToString(" ") { it.message ?: "" }
        return when {
            names.contains("Cancellation") || text.contains("cancel", ignoreCase = true) -> "cancelled"
            names.contains("Unsupported") || names.contains("NoCredential") ||
                text.contains("not supported", ignoreCase = true) ||
                text.contains("unsupported", ignoreCase = true) -> "unsupported"
            text.contains("PERMISSION_DENIED") || text.contains("has not been used") ||
                text.contains("brand", ignoreCase = true) ||
                text.contains("billing", ignoreCase = true) -> "not_enabled"
            names.contains("IOException") || names.contains("Network") ||
                text.contains("network", ignoreCase = true) || text.contains("UNAVAILABLE") -> "network"
            else -> "failed"
        }
    }
}
