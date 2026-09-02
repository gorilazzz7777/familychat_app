package com.familychat.familychat_app

import android.Manifest
import android.media.AudioAttributes
import android.media.RingtoneManager
import android.app.NotificationChannel
import android.app.NotificationManager
import android.content.ClipData
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.os.PowerManager
import android.provider.MediaStore
import android.util.Log
import android.view.WindowManager
import androidx.core.content.ContextCompat
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    companion object {
        private const val TAG = "FamilyChatShare"
        private const val PUSH_REPLY_TAG = "FamilyChatPushReply"
        private const val FOREGROUND_NOTIFICATION_ACTION = "SELECT_FOREGROUND_NOTIFICATION"
        private const val SELECT_NOTIFICATION = "SELECT_NOTIFICATION"
        private var pendingShareUris: List<Uri> = emptyList()

        /** Used by FCM service: strip system notification only while app is visible. */
        @JvmField
        var isAppInForeground: Boolean = false
    }

    private var proximityWakeLock: PowerManager.WakeLock? = null
    private val rustoreReviewPlugin = RustoreReviewPlugin()

    override fun onCreate(savedInstanceState: android.os.Bundle?) {
        super.onCreate(savedInstanceState)
        createNotificationChannels()
        captureShareUris(intent)
    }

    override fun onNewIntent(intent: Intent) {
        val wasNotificationLaunch = isNotificationLaunchIntent(intent)
        super.onNewIntent(intent)
        setIntent(intent)
        captureShareUris(intent)
        if (wasNotificationLaunch) {
            clearNotificationLaunchIntent()
        }
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        flutterEngine.plugins.add(rustoreReviewPlugin)
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "com.familychat/lifecycle",
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "bringToForeground" -> {
                    val forCall = call.argument<Boolean>("forCall") == true
                    if (forCall) {
                        setShowOnLockScreen(true)
                    }
                    val intent = Intent(this, MainActivity::class.java).apply {
                        addFlags(
                            Intent.FLAG_ACTIVITY_NEW_TASK or
                                Intent.FLAG_ACTIVITY_REORDER_TO_FRONT or
                                Intent.FLAG_ACTIVITY_SINGLE_TOP,
                        )
                    }
                    startActivity(intent)
                    result.success(null)
                }

                "setShowOnLockScreen" -> {
                    val enabled = call.arguments == true
                    setShowOnLockScreen(enabled)
                    result.success(null)
                }

                else -> result.notImplemented()
            }
        }
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "com.familychat.familychat_app/install_source",
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "getInstallerPackageName" -> {
                    try {
                        val pkg = packageName
                        val installer = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
                            packageManager.getInstallSourceInfo(pkg).installingPackageName
                        } else {
                            @Suppress("DEPRECATION")
                            packageManager.getInstallerPackageName(pkg)
                        }
                        result.success(installer)
                    } catch (_: Throwable) {
                        result.success(null)
                    }
                }
                else -> result.notImplemented()
            }
        }
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "com.familychat/call_proximity",
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "enable" -> {
                    enableCallProximity()
                    result.success(null)
                }

                "disable" -> {
                    disableCallProximity()
                    result.success(null)
                }

                else -> result.notImplemented()
            }
        }
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "com.familychat/push_reply",
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "takePending" -> result.success(FamilyChatPushReplyStore.takePending(this))
                "clearLaunchNotificationIntent" -> {
                    clearNotificationLaunchIntent()
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "com.familychat/share_intent",
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "readPendingImageBytes" -> {
                    val index = call.argument<Int>("index") ?: 0
                    val uri = pendingShareUris.getOrNull(index)
                    if (uri == null) {
                        Log.w(TAG, "readPendingImageBytes: no uri for index=$index count=${pendingShareUris.size}")
                        result.success(null)
                        return@setMethodCallHandler
                    }
                    try {
                        val bytes = readUriBytesWithOriginal(uri)
                        Log.i(
                            TAG,
                            "readPendingImageBytes: uri=$uri bytes=${bytes?.size ?: 0}",
                        )
                        result.success(if (bytes == null || bytes.isEmpty()) null else bytes)
                    } catch (e: Exception) {
                        Log.w(TAG, "readPendingImageBytes failed, dart will use cache", e)
                        result.success(null)
                    }
                }

                "clearPendingShareUris" -> {
                    pendingShareUris = emptyList()
                    result.success(null)
                }

                else -> result.notImplemented()
            }
        }
    }

    private fun isNotificationLaunchIntent(intent: Intent?): Boolean {
        if (intent == null) return false
        return intent.action == FOREGROUND_NOTIFICATION_ACTION ||
            intent.action == SELECT_NOTIFICATION
    }

    private fun clearNotificationLaunchIntent() {
        if (!isNotificationLaunchIntent(intent)) return
        setIntent(
            Intent(this, MainActivity::class.java).apply {
                addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP)
            },
        )
        Log.i(PUSH_REPLY_TAG, "cleared notification launch intent")
    }

    private fun captureShareUris(intent: Intent?) {
        pendingShareUris = when (intent?.action) {
            Intent.ACTION_SEND -> {
                val fromExtra = readStreamUri(intent)
                if (fromExtra != null) {
                    listOf(fromExtra)
                } else {
                    readClipUris(intent)
                }
            }

            Intent.ACTION_SEND_MULTIPLE -> {
                val fromExtra =
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                        intent.getParcelableArrayListExtra(Intent.EXTRA_STREAM, Uri::class.java)
                    } else {
                        @Suppress("DEPRECATION")
                        intent.getParcelableArrayListExtra(Intent.EXTRA_STREAM)
                    }
                if (!fromExtra.isNullOrEmpty()) fromExtra else readClipUris(intent)
            }

            else -> emptyList()
        }
        Log.i(TAG, "captureShareUris action=${intent?.action} count=${pendingShareUris.size} uris=$pendingShareUris")
    }

    private fun readStreamUri(intent: Intent): Uri? {
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            intent.getParcelableExtra(Intent.EXTRA_STREAM, Uri::class.java)
        } else {
            @Suppress("DEPRECATION")
            intent.getParcelableExtra(Intent.EXTRA_STREAM)
        }
    }

    private fun readClipUris(intent: Intent): List<Uri> {
        val clip: ClipData = intent.clipData ?: return emptyList()
        val uris = ArrayList<Uri>(clip.itemCount)
        for (i in 0 until clip.itemCount) {
            clip.getItemAt(i).uri?.let { uris.add(it) }
        }
        return uris
    }

    private fun readUriBytesWithOriginal(uri: Uri): ByteArray? {
        val resolver = applicationContext.contentResolver
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q && hasMediaLocationAccess()) {
            try {
                val originalUri = MediaStore.setRequireOriginal(uri)
                return resolver.openInputStream(originalUri)?.use { input -> input.readBytes() }
            } catch (e: SecurityException) {
                Log.w(TAG, "requireOriginal denied for $uri, fallback to plain uri", e)
            } catch (e: Exception) {
                Log.w(TAG, "requireOriginal read failed for $uri, fallback to plain uri", e)
            }
        } else if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            Log.i(TAG, "readUriBytes: ACCESS_MEDIA_LOCATION not granted, reading without requireOriginal")
        }
        return resolver.openInputStream(uri)?.use { input -> input.readBytes() }
    }

    private fun hasMediaLocationAccess(): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) return true
        return ContextCompat.checkSelfPermission(
            this,
            Manifest.permission.ACCESS_MEDIA_LOCATION,
        ) == PackageManager.PERMISSION_GRANTED
    }

    private fun createNotificationChannels() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val manager = getSystemService(NotificationManager::class.java) ?: return

        val messageSound = RingtoneManager.getDefaultUri(RingtoneManager.TYPE_NOTIFICATION)
        val messages = NotificationChannel(
            "familychat_messages",
            "Сообщения",
            NotificationManager.IMPORTANCE_HIGH,
        ).apply {
            description = "Новые сообщения в чатах"
            enableVibration(true)
            setSound(
                messageSound,
                AudioAttributes.Builder()
                    .setUsage(AudioAttributes.USAGE_NOTIFICATION)
                    .setContentType(AudioAttributes.CONTENT_TYPE_SONIFICATION)
                    .build(),
            )
        }

        val ringtone = RingtoneManager.getDefaultUri(RingtoneManager.TYPE_RINGTONE)
        val calls = NotificationChannel(
            "familychat_calls",
            "Звонки",
            NotificationManager.IMPORTANCE_HIGH,
        ).apply {
            description = "Входящие звонки"
            enableVibration(true)
            setSound(
                ringtone,
                AudioAttributes.Builder()
                    .setUsage(AudioAttributes.USAGE_NOTIFICATION_RINGTONE)
                    .setContentType(AudioAttributes.CONTENT_TYPE_SONIFICATION)
                    .build(),
            )
        }

        manager.createNotificationChannel(messages)
        manager.createNotificationChannel(calls)
    }

    override fun onResume() {
        super.onResume()
        isAppInForeground = true
    }

    override fun onPause() {
        isAppInForeground = false
        disableCallProximity()
        super.onPause()
    }

    override fun onDestroy() {
        disableCallProximity()
        setShowOnLockScreen(false)
        super.onDestroy()
    }

    @Suppress("DEPRECATION")
    private fun setShowOnLockScreen(enabled: Boolean) {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O_MR1) {
            setShowWhenLocked(enabled)
            setTurnScreenOn(enabled)
        }
        val flags = WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON or
            WindowManager.LayoutParams.FLAG_SHOW_WHEN_LOCKED or
            WindowManager.LayoutParams.FLAG_TURN_SCREEN_ON
        if (enabled) {
            window.addFlags(flags)
        } else {
            window.clearFlags(flags)
        }
    }

    private fun enableCallProximity() {
        if (proximityWakeLock?.isHeld == true) return
        val pm = getSystemService(POWER_SERVICE) as PowerManager
        @Suppress("DEPRECATION")
        proximityWakeLock = pm.newWakeLock(
            PowerManager.PROXIMITY_SCREEN_OFF_WAKE_LOCK,
            "familychat:call_proximity",
        )
        proximityWakeLock?.acquire()
    }

    private fun disableCallProximity() {
        proximityWakeLock?.let {
            if (it.isHeld) it.release()
        }
        proximityWakeLock = null
    }
}
