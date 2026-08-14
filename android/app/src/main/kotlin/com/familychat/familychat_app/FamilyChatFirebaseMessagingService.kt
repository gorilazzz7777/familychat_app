package com.familychat.familychat_app

import android.content.Intent
import android.os.Bundle
import com.google.firebase.messaging.FirebaseMessagingService
import io.flutter.plugins.firebase.messaging.FlutterFirebaseTokenLiveData

/**
 * FCM в фоне сам рисует баннер без кнопки «Ответить».
 * Для чатов снимаем notification-ключи, чтобы сообщение ушло в Dart
 * и мы показали локальный пуш с полем ответа.
 */
class FamilyChatFirebaseMessagingService : FirebaseMessagingService() {
    override fun onNewToken(token: String) {
        FlutterFirebaseTokenLiveData.getInstance().postToken(token)
    }

    override fun handleIntent(intent: Intent) {
        val extras = intent.extras
        if (extras != null && isChatPush(extras)) {
            val clean = Intent(intent)
            clean.replaceExtras(stripNotificationDisplayKeys(extras))
            super.handleIntent(clean)
            return
        }
        super.handleIntent(intent)
    }

    private fun isChatPush(extras: Bundle): Boolean {
        val type = extraString(extras, "type")
        if (type == "familychat_chat") return true
        val deeplink = extraString(extras, "deeplink")
        val threadId = extraString(extras, "thread_id")
        return deeplink == "chat" && threadId.isNotEmpty()
    }

    private fun extraString(extras: Bundle, key: String): String {
        extras.getString(key)?.let { return it }
        extras.get(key)?.toString()?.takeIf { it != "null" }?.let { return it }
        extras.getString("gcm.notification.$key")?.let { return it }
        extras.get("gcm.notification.$key")?.toString()?.let { return it }
        return ""
    }

    private fun stripNotificationDisplayKeys(extras: Bundle): Bundle {
        val bundle = Bundle(extras)
        val keys = bundle.keySet().toList()
        for (key in keys) {
            if (key.startsWith("gcm.n.") ||
                key.startsWith("gcm.notification") ||
                key.startsWith("gcm.n")
            ) {
                bundle.remove(key)
            }
        }
        return bundle
    }
}
