package com.familychat.familychat_app

import android.app.Activity
import android.util.Log
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import ru.rustore.sdk.review.RuStoreReviewManagerFactory

/**
 * RuStore In-App Review через MethodChannel.
 * Возвращает Map: ok=true | ok=false + stage/error_code/error_message.
 */
class RustoreReviewPlugin : FlutterPlugin, MethodChannel.MethodCallHandler, ActivityAware {
    private var channel: MethodChannel? = null
    private var activity: Activity? = null

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel = MethodChannel(binding.binaryMessenger, CHANNEL_NAME).also {
            it.setMethodCallHandler(this)
        }
        Log.i(TAG, "RustoreReviewPlugin onAttachedToEngine channel=$CHANNEL_NAME")
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

    private fun failurePayload(stage: String, error: Throwable): HashMap<String, Any?> {
        return hashMapOf(
            "ok" to false,
            "stage" to stage,
            "error_code" to error.javaClass.simpleName,
            "error_message" to (error.message ?: ""),
        )
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        if (call.method != "launchRuStoreReview") {
            result.notImplemented()
            return
        }

        val ctx = activity ?: run {
            Log.e(TAG, "launchRuStoreReview: activity is null")
            result.success(
                hashMapOf(
                    "ok" to false,
                    "stage" to "activity",
                    "error_code" to "no_activity",
                    "error_message" to "Activity not ready",
                ),
            )
            return
        }

        val manager = RuStoreReviewManagerFactory.create(ctx.applicationContext)
        manager.requestReviewFlow()
            .addOnSuccessListener { reviewInfo ->
                manager.launchReviewFlow(reviewInfo)
                    .addOnSuccessListener {
                        ctx.runOnUiThread {
                            result.success(hashMapOf("ok" to true))
                        }
                    }
                    .addOnFailureListener { e ->
                        Log.w(TAG, "launchReviewFlow failure", e)
                        ctx.runOnUiThread {
                            result.success(failurePayload("launchReviewFlow", e))
                        }
                    }
            }
            .addOnFailureListener { e ->
                Log.w(TAG, "requestReviewFlow failure", e)
                ctx.runOnUiThread {
                    result.success(failurePayload("requestReviewFlow", e))
                }
            }
    }

    companion object {
        private const val TAG = "RustoreReview"
        const val CHANNEL_NAME = "com.familychat.familychat_app/rustore_review"
    }
}
