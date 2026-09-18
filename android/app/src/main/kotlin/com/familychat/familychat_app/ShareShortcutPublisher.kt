package com.familychat.familychat_app

import android.content.Context
import android.content.Intent
import android.util.Log
import androidx.core.app.Person
import androidx.core.content.pm.ShortcutInfoCompat
import androidx.core.content.pm.ShortcutManagerCompat
import androidx.core.graphics.drawable.IconCompat

/**
 * Direct Share targets for the system share sheet.
 *
 * Requires [android.app.shortcuts] meta-data on [MainActivity] (not application)
 * so [share-target] categories bind to SEND intent-filters.
 *
 * [ShortcutManagerCompat.pushDynamicShortcut] also reports usage — needed for
 * Samsung/Android ranking in the top people row.
 */
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

    fun shortcutIdForThread(threadId: Int): String = "$SHORTCUT_PREFIX$threadId"

    fun sync(context: Context, chats: List<ChatShortcut>) {
        val existingShareIds = ShortcutManagerCompat.getDynamicShortcuts(context)
            .map { it.id }
            .filter { it.startsWith(SHORTCUT_PREFIX) }
        if (existingShareIds.isNotEmpty()) {
            ShortcutManagerCompat.removeDynamicShortcuts(context, existingShareIds)
        }

        if (chats.isEmpty()) {
            Log.i(TAG, "synced 0 direct share shortcuts (cleared)")
            return
        }

        val icon = IconCompat.createWithResource(context, R.mipmap.ic_launcher)
        val max = ShortcutManagerCompat.getMaxShortcutCountPerActivity(context)
            .coerceAtMost(4)
            .coerceAtLeast(1)
        var published = 0
        chats.take(max).forEachIndexed { index, chat ->
            if (chat.threadId <= 0) return@forEachIndexed
            val label = chat.title.trim().ifEmpty { "Чат" }
            // Launcher intent only — share sheet builds ACTION_SEND + EXTRA_SHORTCUT_ID.
            val intent = Intent(context, MainActivity::class.java).apply {
                action = Intent.ACTION_VIEW
                addCategory(Intent.CATEGORY_DEFAULT)
                putExtra(EXTRA_THREAD_ID, chat.threadId)
                putExtra(EXTRA_THREAD_TITLE, label)
            }
            val person = Person.Builder()
                .setName(label)
                .setKey("thread_${chat.threadId}")
                .setImportant(true)
                .build()
            val shortcut = ShortcutInfoCompat.Builder(context, shortcutIdForThread(chat.threadId))
                .setShortLabel(label.take(25))
                .setLongLabel(label.take(100))
                .setCategories(setOf(CATEGORY))
                .setIcon(icon)
                .setRank(index)
                .setIntent(intent)
                .setPerson(person)
                .setLongLived(true)
                .setIsConversation()
                .build()
            try {
                // pushDynamicShortcut reports usage → helps OEM share ranking.
                val ok = ShortcutManagerCompat.pushDynamicShortcut(context, shortcut)
                if (ok) published++
                else Log.w(TAG, "pushDynamicShortcut rejected id=${shortcut.id}")
            } catch (e: Throwable) {
                Log.w(TAG, "pushDynamicShortcut failed id=${shortcut.id}", e)
            }
        }
        Log.i(
            TAG,
            "synced $published/${chats.take(max).size} direct share shortcuts " +
                "ids=${chats.take(max).map { shortcutIdForThread(it.threadId) }}",
        )
    }

    fun reportUsed(context: Context, threadId: Int) {
        if (threadId <= 0) return
        try {
            ShortcutManagerCompat.reportShortcutUsed(context, shortcutIdForThread(threadId))
            Log.i(TAG, "reportShortcutUsed thread=$threadId")
        } catch (e: Throwable) {
            Log.w(TAG, "reportShortcutUsed failed thread=$threadId", e)
        }
    }
}
