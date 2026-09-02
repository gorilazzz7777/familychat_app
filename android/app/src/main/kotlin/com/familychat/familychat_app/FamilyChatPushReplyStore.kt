package com.familychat.familychat_app

import android.content.Context
import android.util.Log
import org.json.JSONObject

/** Pending inline reply when Dart is not ready yet (mirror iOS UserDefaults store). */
object FamilyChatPushReplyStore {
    private const val TAG = "FamilyChatPushReply"
    private const val PREFS = "familychat_push_reply"
    private const val KEY_TEXT = "text"
    private const val KEY_THREAD_ID = "thread_id"
    private const val KEY_PAYLOAD = "payload_json"

    fun save(context: Context, text: String, payloadJson: String?) {
        val trimmed = text.trim()
        if (trimmed.isEmpty()) return
        val threadId = parseThreadId(payloadJson)
        context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
            .edit()
            .putString(KEY_TEXT, trimmed)
            .putString(KEY_THREAD_ID, threadId)
            .putString(KEY_PAYLOAD, payloadJson)
            .apply()
        Log.i(TAG, "saved pending reply thread=$threadId len=${trimmed.length}")
    }

    fun takePending(context: Context): Map<String, String>? {
        val prefs = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
        val text = prefs.getString(KEY_TEXT, null)?.trim().orEmpty()
        if (text.isEmpty()) return null
        val threadId = prefs.getString(KEY_THREAD_ID, null)
        val payload = prefs.getString(KEY_PAYLOAD, null)
        prefs.edit().clear().apply()
        val out = linkedMapOf("text" to text)
        if (!threadId.isNullOrEmpty()) out["thread_id"] = threadId
        if (!payload.isNullOrEmpty()) out["payload"] = payload
        Log.i(TAG, "takePending thread=$threadId len=${text.length}")
        return out
    }

    private fun parseThreadId(payloadJson: String?): String? {
        if (payloadJson.isNullOrBlank()) return null
        return try {
            JSONObject(payloadJson).optString("thread_id").takeIf { it.isNotEmpty() }
        } catch (_: Exception) {
            null
        }
    }
}
