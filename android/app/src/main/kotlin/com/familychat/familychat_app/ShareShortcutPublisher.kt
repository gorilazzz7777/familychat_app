package com.familychat.familychat_app

import android.content.Context
import android.content.Intent
import android.content.pm.ShortcutInfo
import android.content.pm.ShortcutManager
import android.graphics.drawable.Icon
import android.os.Build
import android.util.Log

object ShareShortcutPublisher {
    private const val TAG = "FamilyChatShareShortcut"
    const val CATEGORY = "com.familychat.familychat_app.category.SHARE_TARGET"
    const val EXTRA_THREAD_ID = "familychat_share_thread_id"
    const val EXTRA_THREAD_TITLE = "familychat_share_thread_title"
    private const val SHORTCUT_PREFIX = "share_chat_"

    data class ChatShortcut(
        val threadId: Int,
        val title: String,
    )

    fun sync(context: Context, chats: List<ChatShortcut>) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.N_MR1) return
        val manager = context.getSystemService(ShortcutManager::class.java) ?: return

        val existingShareIds = manager.dynamicShortcuts
            .map { it.id }
            .filter { it.startsWith(SHORTCUT_PREFIX) }
        if (existingShareIds.isNotEmpty()) {
            manager.removeDynamicShortcuts(existingShareIds)
        }

        if (chats.isEmpty()) return

        val icon = Icon.createWithResource(context, R.mipmap.ic_launcher)
        val shortcuts = chats.take(4).mapNotNull { chat ->
            if (chat.threadId <= 0) return@mapNotNull null
            val label = chat.title.trim().ifEmpty { "Чат" }
            val intent = Intent(context, MainActivity::class.java).apply {
                action = Intent.ACTION_VIEW
                addCategory(Intent.CATEGORY_DEFAULT)
                putExtra(EXTRA_THREAD_ID, chat.threadId)
                putExtra(EXTRA_THREAD_TITLE, label)
            }
            ShortcutInfo.Builder(context, "$SHORTCUT_PREFIX${chat.threadId}")
                .setShortLabel(label.take(25))
                .setLongLabel(label.take(100))
                .setCategories(setOf(CATEGORY))
                .setIcon(icon)
                .setIntent(intent)
                .apply {
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                        setLongLived(true)
                    }
                }
                .build()
        }

        if (shortcuts.isEmpty()) return
        try {
            manager.addDynamicShortcuts(shortcuts)
            Log.i(TAG, "synced ${shortcuts.size} direct share shortcuts")
        } catch (e: Throwable) {
            Log.w(TAG, "addDynamicShortcuts failed", e)
        }
    }
}
