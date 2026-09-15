package com.familychat.familychat_app

import android.app.Activity
import android.app.Application
import android.content.pm.PackageManager
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.util.Log
import android.view.ViewTreeObserver
import com.google.android.play.core.review.ReviewManagerFactory
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.PrintWriter
import java.io.StringWriter
import java.util.concurrent.atomic.AtomicBoolean

/**
 * Google Play In-App Review через MethodChannel.
 *
 * Зеркало [RustoreReviewPlugin]: те же стадии, таймауты и поля ответа,
 * чтобы Dart-слой мог одинаково обрабатывать Play и RuStore.
 *
 * Возвращает Map: ok, stage, error_code, error_message, fallback_allowed,
 * ui_appeared, diagnostics.
 *
 * Каноничный патч Remont — копировать в другие приложения вместе с
 * RuStoreReviewPlugin и общим Dart-сервисом оценки.
 */
class PlayReviewPlugin : FlutterPlugin, MethodChannel.MethodCallHandler, ActivityAware {
    private var channel: MethodChannel? = null
    private var activity: Activity? = null
    private val mainHandler = Handler(Looper.getMainLooper())

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel = MethodChannel(binding.binaryMessenger, CHANNEL_NAME).also {
            it.setMethodCallHandler(this)
        }
        Log.i(TAG, "PlayReviewPlugin onAttachedToEngine channel=$CHANNEL_NAME")
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel?.setMethodCallHandler(null)
        channel = null
    }

    override fun onAttachedToActivity(binding: ActivityPluginBinding) {
        activity = binding.activity
    }

    override fun onDetachedFromActivityForConfigChanges() {
        activity = null
    }

    override fun onReattachedToActivityForConfigChanges(binding: ActivityPluginBinding) {
        activity = binding.activity
    }

    override fun onDetachedFromActivity() {
        activity = null
    }

    private fun stackTraceText(error: Throwable, maxLen: Int = 2000): String {
        val sw = StringWriter()
        error.printStackTrace(PrintWriter(sw))
        val text = sw.toString()
        return if (text.length <= maxLen) text else text.take(maxLen - 1) + "…"
    }

    private fun throwableFields(error: Throwable): HashMap<String, Any?> {
        val cause = error.cause
        return hashMapOf(
            "error_class" to error.javaClass.name,
            "error_simple" to error.javaClass.simpleName,
            "error_message" to (error.message ?: ""),
            "error_to_string" to error.toString(),
            "cause_class" to cause?.javaClass?.name,
            "cause_message" to cause?.message,
            "stack_trace" to stackTraceText(error),
        )
    }

    private fun packageVersion(pm: PackageManager, packageName: String): HashMap<String, Any?> {
        return try {
            val info = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                pm.getPackageInfo(packageName, PackageManager.PackageInfoFlags.of(0))
            } else {
                @Suppress("DEPRECATION")
                pm.getPackageInfo(packageName, 0)
            }
            val versionCode = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
                info.longVersionCode
            } else {
                @Suppress("DEPRECATION")
                info.versionCode.toLong()
            }
            hashMapOf(
                "installed" to true,
                "version_name" to (info.versionName ?: ""),
                "version_code" to versionCode,
            )
        } catch (_: PackageManager.NameNotFoundException) {
            hashMapOf(
                "installed" to false,
                "version_name" to null,
                "version_code" to null,
            )
        } catch (e: Throwable) {
            hashMapOf(
                "installed" to null,
                "error" to e.toString(),
            )
        }
    }

    private fun installerPackage(activity: Activity): String? {
        return try {
            val pm = activity.packageManager
            val pkg = activity.packageName
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
                pm.getInstallSourceInfo(pkg).installingPackageName
            } else {
                @Suppress("DEPRECATION")
                pm.getInstallerPackageName(pkg)
            }
        } catch (_: Throwable) {
            null
        }
    }

    private fun deviceDiagnostics(activity: Activity): HashMap<String, Any?> {
        val pm = activity.packageManager
        val appInfo = packageVersion(pm, activity.packageName)
        val playInfo = packageVersion(pm, PLAY_PACKAGE)
        val rustoreInfo = packageVersion(pm, RUSTORE_PACKAGE)
        return hashMapOf(
            "android_sdk" to Build.VERSION.SDK_INT,
            "android_release" to Build.VERSION.RELEASE,
            "manufacturer" to Build.MANUFACTURER,
            "brand" to Build.BRAND,
            "model" to Build.MODEL,
            "device" to Build.DEVICE,
            "product" to Build.PRODUCT,
            "installer_package" to installerPackage(activity),
            "app_package" to activity.packageName,
            "app_version_name" to appInfo["version_name"],
            "app_version_code" to appInfo["version_code"],
            "play_package" to PLAY_PACKAGE,
            "play_installed" to playInfo["installed"],
            "play_version_name" to playInfo["version_name"],
            "play_version_code" to playInfo["version_code"],
            "rustore_package" to RUSTORE_PACKAGE,
            "rustore_installed" to rustoreInfo["installed"],
            "rustore_version_name" to rustoreInfo["version_name"],
            "rustore_version_code" to rustoreInfo["version_code"],
            "activity" to activity.javaClass.name,
            "activity_finishing" to activity.isFinishing,
            "activity_destroyed" to
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.JELLY_BEAN_MR1) {
                    activity.isDestroyed
                } else {
                    null
                },
        )
    }

    private fun basePayload(
        activity: Activity,
        startedAt: Long,
        requestDoneAt: Long? = null,
        launchStartedAt: Long? = null,
    ): HashMap<String, Any?> {
        val now = SystemClock.elapsedRealtime()
        val payload = hashMapOf<String, Any?>(
            "elapsed_ms" to (now - startedAt),
            "request_timeout_ms" to REQUEST_TIMEOUT_MS,
            "launch_no_ui_timeout_ms" to LAUNCH_NO_UI_TIMEOUT_MS,
            "launch_safety_timeout_ms" to LAUNCH_SAFETY_TIMEOUT_MS,
            "diagnostics" to deviceDiagnostics(activity),
        )
        if (requestDoneAt != null) {
            payload["request_elapsed_ms"] = requestDoneAt - startedAt
        }
        if (launchStartedAt != null) {
            payload["launch_elapsed_ms"] = now - launchStartedAt
        }
        return payload
    }

    private fun failurePayload(
        activity: Activity,
        stage: String,
        error: Throwable,
        startedAt: Long,
        requestDoneAt: Long? = null,
        launchStartedAt: Long? = null,
        extra: Map<String, Any?> = emptyMap(),
    ): HashMap<String, Any?> {
        val payload = basePayload(activity, startedAt, requestDoneAt, launchStartedAt)
        payload["ok"] = false
        payload["stage"] = stage
        payload["error_code"] = error.javaClass.simpleName
        payload["error_message"] = error.message ?: ""
        payload.putAll(throwableFields(error))
        payload.putAll(extra)
        return payload
    }

    private fun failurePayload(
        activity: Activity,
        stage: String,
        code: String,
        message: String,
        startedAt: Long,
        requestDoneAt: Long? = null,
        launchStartedAt: Long? = null,
        extra: Map<String, Any?> = emptyMap(),
    ): HashMap<String, Any?> {
        val payload = basePayload(activity, startedAt, requestDoneAt, launchStartedAt)
        payload["ok"] = false
        payload["stage"] = stage
        payload["error_code"] = code
        payload["error_message"] = message
        payload.putAll(extra)
        return payload
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "launchPlayReview" -> launchReview(result)
            "getReviewDiagnostics" -> {
                val ctx = activity
                if (ctx == null) {
                    result.success(
                        hashMapOf(
                            "ok" to false,
                            "error_code" to "no_activity",
                            "error_message" to "Activity not ready",
                        ),
                    )
                } else {
                    result.success(
                        hashMapOf(
                            "ok" to true,
                            "diagnostics" to deviceDiagnostics(ctx),
                        ),
                    )
                }
            }
            "getInstallerPackageName" -> {
                val ctx = activity
                if (ctx == null) {
                    result.success(null)
                } else {
                    result.success(installerPackage(ctx))
                }
            }
            else -> result.notImplemented()
        }
    }

    private fun launchReview(result: MethodChannel.Result) {
        val ctx = activity ?: run {
            Log.e(TAG, "launchPlayReview: activity is null")
            result.success(
                hashMapOf(
                    "ok" to false,
                    "stage" to "activity",
                    "error_code" to "no_activity",
                    "error_message" to "Activity not ready",
                    "elapsed_ms" to 0,
                    "fallback_allowed" to true,
                    "ui_appeared" to false,
                ),
            )
            return
        }

        val startedAt = SystemClock.elapsedRealtime()
        val replied = AtomicBoolean(false)
        val uiAppeared = AtomicBoolean(false)
        var focusListener: ViewTreeObserver.OnWindowFocusChangeListener? = null
        var lifecycleCallbacks: Application.ActivityLifecycleCallbacks? = null
        var requestTimeout: Runnable? = null
        var noUiTimeout: Runnable? = null
        var safetyTimeout: Runnable? = null

        fun cleanupWatchers() {
            requestTimeout?.let { mainHandler.removeCallbacks(it) }
            noUiTimeout?.let { mainHandler.removeCallbacks(it) }
            safetyTimeout?.let { mainHandler.removeCallbacks(it) }
            try {
                focusListener?.let { listener ->
                    ctx.window.decorView.viewTreeObserver
                        .removeOnWindowFocusChangeListener(listener)
                }
            } catch (_: Throwable) {
            }
            try {
                lifecycleCallbacks?.let { callbacks ->
                    ctx.application.unregisterActivityLifecycleCallbacks(callbacks)
                }
            } catch (_: Throwable) {
            }
        }

        fun markUiAppeared() {
            if (uiAppeared.compareAndSet(false, true)) {
                Log.i(TAG, "launchPlayReview: review UI likely appeared")
                noUiTimeout?.let { mainHandler.removeCallbacks(it) }
            }
        }

        fun replyOnce(payload: HashMap<String, Any?>) {
            if (!replied.compareAndSet(false, true)) {
                Log.w(TAG, "launchPlayReview: duplicate reply ignored stage=${payload["stage"]}")
                return
            }
            cleanupWatchers()
            payload["ui_appeared"] = uiAppeared.get()
            if (!payload.containsKey("fallback_allowed")) {
                val ok = payload["ok"] == true
                payload["fallback_allowed"] = !ok && !uiAppeared.get()
            }
            ctx.runOnUiThread {
                result.success(payload)
            }
        }

        fun attachUiWatchers() {
            focusListener = ViewTreeObserver.OnWindowFocusChangeListener { hasFocus ->
                if (!hasFocus) markUiAppeared()
            }
            try {
                ctx.window.decorView.viewTreeObserver
                    .addOnWindowFocusChangeListener(focusListener)
                if (!ctx.hasWindowFocus()) markUiAppeared()
            } catch (e: Throwable) {
                Log.w(TAG, "launchPlayReview: cannot attach focus listener", e)
            }

            lifecycleCallbacks = object : Application.ActivityLifecycleCallbacks {
                override fun onActivityCreated(activity: Activity, savedInstanceState: Bundle?) {}
                override fun onActivityStarted(activity: Activity) {}
                override fun onActivityResumed(activity: Activity) {}
                override fun onActivityPaused(activity: Activity) {
                    if (activity === ctx) markUiAppeared()
                }
                override fun onActivityStopped(activity: Activity) {}
                override fun onActivitySaveInstanceState(activity: Activity, outState: Bundle) {}
                override fun onActivityDestroyed(activity: Activity) {}
            }
            ctx.application.registerActivityLifecycleCallbacks(lifecycleCallbacks)
        }

        requestTimeout = Runnable {
            Log.w(TAG, "requestReviewFlow timeout ${REQUEST_TIMEOUT_MS}ms")
            replyOnce(
                failurePayload(
                    ctx,
                    "requestReviewFlow",
                    "timeout",
                    "requestReviewFlow did not respond within ${REQUEST_TIMEOUT_MS}ms",
                    startedAt,
                    extra = mapOf("fallback_allowed" to true),
                ),
            )
        }
        mainHandler.postDelayed(requestTimeout!!, REQUEST_TIMEOUT_MS)

        try {
            val manager = ReviewManagerFactory.create(ctx)
            manager.requestReviewFlow()
                .addOnCompleteListener { requestTask ->
                    val requestDoneAt = SystemClock.elapsedRealtime()
                    requestTimeout?.let { mainHandler.removeCallbacks(it) }
                    if (replied.get()) {
                        Log.w(TAG, "requestReviewFlow complete after reply — skip launch")
                        return@addOnCompleteListener
                    }
                    if (!requestTask.isSuccessful) {
                        val e = requestTask.exception
                            ?: Exception("requestReviewFlow unsuccessful")
                        Log.w(TAG, "requestReviewFlow failure", e)
                        replyOnce(
                            failurePayload(
                                ctx,
                                "requestReviewFlow",
                                e,
                                startedAt,
                                requestDoneAt,
                                extra = mapOf("fallback_allowed" to true),
                            ),
                        )
                        return@addOnCompleteListener
                    }

                    val reviewInfo = requestTask.result
                    attachUiWatchers()
                    val launchStartedAt = SystemClock.elapsedRealtime()

                    noUiTimeout = Runnable {
                        if (replied.get() || uiAppeared.get()) return@Runnable
                        Log.w(TAG, "launchReviewFlow no UI within ${LAUNCH_NO_UI_TIMEOUT_MS}ms")
                        replyOnce(
                            failurePayload(
                                ctx,
                                "launchReviewFlow",
                                "launch_no_ui",
                                "launchReviewFlow did not complete and no review UI was detected within ${LAUNCH_NO_UI_TIMEOUT_MS}ms",
                                startedAt,
                                requestDoneAt,
                                launchStartedAt,
                                extra = mapOf(
                                    "fallback_allowed" to true,
                                    "ui_appeared" to false,
                                ),
                            ),
                        )
                    }
                    mainHandler.postDelayed(noUiTimeout!!, LAUNCH_NO_UI_TIMEOUT_MS)

                    safetyTimeout = Runnable {
                        if (replied.get()) return@Runnable
                        Log.w(
                            TAG,
                            "launchReviewFlow safety timeout ${LAUNCH_SAFETY_TIMEOUT_MS}ms uiAppeared=${uiAppeared.get()}",
                        )
                        replyOnce(
                            failurePayload(
                                ctx,
                                "launchReviewFlow",
                                "launch_safety_timeout",
                                "launchReviewFlow did not complete within ${LAUNCH_SAFETY_TIMEOUT_MS}ms",
                                startedAt,
                                requestDoneAt,
                                launchStartedAt,
                                extra = mapOf(
                                    "fallback_allowed" to !uiAppeared.get(),
                                    "ui_appeared" to uiAppeared.get(),
                                ),
                            ),
                        )
                    }
                    mainHandler.postDelayed(safetyTimeout!!, LAUNCH_SAFETY_TIMEOUT_MS)

                    // Play API всегда завершает Task, даже если UI не показали.
                    manager.launchReviewFlow(ctx, reviewInfo)
                        .addOnCompleteListener { launchTask ->
                            if (!launchTask.isSuccessful) {
                                val e = launchTask.exception
                                    ?: Exception("launchReviewFlow unsuccessful")
                                Log.w(TAG, "launchReviewFlow failure", e)
                                replyOnce(
                                    failurePayload(
                                        ctx,
                                        "launchReviewFlow",
                                        e,
                                        startedAt,
                                        requestDoneAt,
                                        launchStartedAt,
                                        extra = mapOf("fallback_allowed" to !uiAppeared.get()),
                                    ),
                                )
                                return@addOnCompleteListener
                            }
                            val payload = basePayload(
                                ctx,
                                startedAt,
                                requestDoneAt,
                                launchStartedAt,
                            )
                            payload["ok"] = true
                            payload["stage"] = "launchReviewFlow"
                            payload["review_info"] = reviewInfo.toString()
                            payload["fallback_allowed"] = false
                            replyOnce(payload)
                        }
                }
        } catch (e: Throwable) {
            requestTimeout?.let { mainHandler.removeCallbacks(it) }
            Log.e(TAG, "launchPlayReview unexpected", e)
            replyOnce(
                failurePayload(
                    ctx,
                    "create_or_request",
                    e,
                    startedAt,
                    extra = mapOf("fallback_allowed" to true),
                ),
            )
        }
    }

    companion object {
        private const val TAG = "PlayReview"
        const val CHANNEL_NAME = "com.familychat.familychat_app/play_review"
        private const val PLAY_PACKAGE = "com.android.vending"
        private const val RUSTORE_PACKAGE = "ru.vk.store"
        private const val REQUEST_TIMEOUT_MS = 12_000L
        private const val LAUNCH_NO_UI_TIMEOUT_MS = 8_000L
        private const val LAUNCH_SAFETY_TIMEOUT_MS = 10 * 60 * 1000L
    }
}
