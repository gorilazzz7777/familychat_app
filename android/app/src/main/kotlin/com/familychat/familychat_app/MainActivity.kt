package com.familychat.familychat_app

import android.Manifest
import android.hardware.Sensor
import android.hardware.SensorEvent
import android.hardware.SensorEventListener
import android.hardware.SensorManager
import android.media.AudioAttributes
import android.media.AudioManager
import android.media.RingtoneManager
import android.app.NotificationChannel
import android.app.NotificationManager
import android.content.ClipData
import android.content.Intent
import android.content.pm.PackageManager
import android.database.ContentObserver
import android.net.Uri
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.PowerManager
import android.provider.Settings
import android.provider.MediaStore
import android.util.Log
import android.view.WindowManager
import androidx.core.content.ContextCompat
import com.ryanheise.audioservice.AudioServiceFragmentActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel

class MainActivity : AudioServiceFragmentActivity() {
    companion object {
        private const val TAG = "FamilyChatShare"
        private const val VOICE_TAG = "FamilyChatVoice"
        private const val PUSH_REPLY_TAG = "FamilyChatPushReply"
        private const val FOREGROUND_NOTIFICATION_ACTION = "SELECT_FOREGROUND_NOTIFICATION"
        private const val SELECT_NOTIFICATION = "SELECT_NOTIFICATION"
        private var pendingShareUris: List<Uri> = emptyList()

        /** Used by FCM service: strip system notification only while app is visible. */
        @JvmField
        var isAppInForeground: Boolean = false
    }

    private var proximityWakeLock: PowerManager.WakeLock? = null
    private var voiceProximityListener: SensorEventListener? = null
    private var voiceProximityEventSink: EventChannel.EventSink? = null
    private var voiceProximityNear: Boolean? = null
    private var voiceProximityMaxRange: Float = 5f
    private var voiceProximityDist: Float? = null
    private var voiceVolumeObserver: ContentObserver? = null
    private val rustoreReviewPlugin = RustoreReviewPlugin()
    private val playReviewPlugin = PlayReviewPlugin()
    private val videoNotePrepPlugin = VideoNotePrepPlugin()

    override fun onCreate(savedInstanceState: android.os.Bundle?) {
        super.onCreate(savedInstanceState)
        createNotificationChannels()
        captureShareUris(intent)
        captureDirectShareTarget(intent)
    }

    override fun onNewIntent(intent: Intent) {
        val wasNotificationLaunch = isNotificationLaunchIntent(intent)
        super.onNewIntent(intent)
        setIntent(intent)
        captureShareUris(intent)
        captureDirectShareTarget(intent)
        if (wasNotificationLaunch) {
            clearNotificationLaunchIntent()
        }
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        flutterEngine.plugins.add(rustoreReviewPlugin)
        flutterEngine.plugins.add(playReviewPlugin)
        flutterEngine.plugins.add(videoNotePrepPlugin)
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "com.familychat/ssaid",
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "getAndroidId" -> {
                    try {
                        val id = Settings.Secure.getString(
                            contentResolver,
                            Settings.Secure.ANDROID_ID,
                        )
                        result.success(id)
                    } catch (e: Exception) {
                        Log.w(TAG, "getAndroidId failed", e)
                        result.success(null)
                    }
                }
                else -> result.notImplemented()
            }
        }
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
        EventChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "com.familychat/voice_proximity_events",
        ).setStreamHandler(object : EventChannel.StreamHandler {
            override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                voiceProximityEventSink = events
                if (voiceProximityListener != null) {
                    events?.success(
                        voiceAudioSnapshot(reason = "sink_listen").also {
                            it["near"] = voiceProximityNear ?: false
                        },
                    )
                }
            }

            override fun onCancel(arguments: Any?) {
                voiceProximityEventSink = null
            }
        })
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "com.familychat/voice_proximity",
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "start" -> result.success(startVoiceProximity())
                "stop" -> {
                    stopVoiceProximity()
                    result.success(null)
                }
                "setEarpiece" -> {
                    setVoiceAudioRoute(earpiece = true)
                    result.success(null)
                }
                "setSpeaker" -> {
                    setVoiceAudioRoute(earpiece = false)
                    result.success(null)
                }
                "getSnapshot" -> result.success(voiceAudioSnapshot(reason = "getSnapshot"))
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
            "com.familychat/share_targets",
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "syncShareShortcuts" -> {
                    @Suppress("UNCHECKED_CAST")
                    val raw = call.argument<List<Map<String, Any>>>("chats") ?: emptyList()
                    val chats = raw.mapNotNull { map ->
                        val threadId = (map["thread_id"] as? Number)?.toInt()
                            ?: (map["thread_id"]?.toString()?.toIntOrNull())
                        val title = map["title"]?.toString() ?: "Чат"
                        if (threadId == null || threadId <= 0) null
                        else ShareShortcutPublisher.ChatShortcut(threadId, title)
                    }
                    ShareShortcutPublisher.sync(this, chats)
                    result.success(null)
                }

                "reportShareShortcutUsed" -> {
                    val threadId = call.argument<Int>("thread_id")
                        ?: (call.argument<Number>("thread_id")?.toInt())
                        ?: 0
                    ShareShortcutPublisher.reportUsed(this, threadId)
                    result.success(null)
                }

                "takePendingDirectShare" -> {
                    val prefs = getSharedPreferences("familychat_share_targets", MODE_PRIVATE)
                    val threadId = prefs.getInt("pending_thread_id", 0)
                    val title = prefs.getString("pending_thread_title", null)
                    prefs.edit()
                        .remove("pending_thread_id")
                        .remove("pending_thread_title")
                        .apply()
                    if (threadId > 0) {
                        result.success(
                            mapOf(
                                "thread_id" to threadId,
                                "thread_title" to title,
                            ),
                        )
                    } else {
                        result.success(null)
                    }
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

    private fun captureDirectShareTarget(intent: Intent?) {
        if (intent == null) return
        val action = intent.action ?: return
        if (action != Intent.ACTION_SEND && action != Intent.ACTION_SEND_MULTIPLE) return

        var threadId = intent.getIntExtra(ShareShortcutPublisher.EXTRA_THREAD_ID, 0)
            .takeIf { it > 0 }
            ?: intent.getStringExtra(ShareShortcutPublisher.EXTRA_THREAD_ID)?.toIntOrNull()
            ?: 0
        if (threadId <= 0) {
            val shortcutId = intent.getStringExtra("android.intent.extra.shortcut.ID")
            if (shortcutId != null && shortcutId.startsWith("share_chat_")) {
                threadId = shortcutId.removePrefix("share_chat_").toIntOrNull() ?: 0
            }
        }
        if (threadId <= 0) return
        val title = intent.getStringExtra(ShareShortcutPublisher.EXTRA_THREAD_TITLE)

        getSharedPreferences("familychat_share_targets", MODE_PRIVATE)
            .edit()
            .putInt("pending_thread_id", threadId)
            .apply {
                if (!title.isNullOrBlank()) {
                    putString("pending_thread_title", title)
                }
            }
            .apply()
        ShareShortcutPublisher.reportUsed(this, threadId)
        Log.i(TAG, "direct share target thread_id=$threadId title=$title")
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
            "familychat_calls_v2",
            "Звонки",
            NotificationManager.IMPORTANCE_MAX,
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

        val uploads = NotificationChannel(
            "familychat_uploads",
            "Отправка медиа",
            NotificationManager.IMPORTANCE_LOW,
        ).apply {
            description =
                "Показывается, пока медиа (чат, лента, альбомы) отправляются в фоне"
            enableVibration(false)
            setSound(null, null)
        }

        manager.createNotificationChannel(messages)
        manager.createNotificationChannel(calls)
        manager.createNotificationChannel(uploads)
    }

    override fun onResume() {
        super.onResume()
        isAppInForeground = true
        Log.i(VOICE_TAG, "activity onResume")
        if (voiceProximityListener != null) {
            voiceProximityEventSink?.success(
                voiceAudioSnapshot(reason = "activity_onResume").also {
                    it["near"] = voiceProximityNear ?: false
                },
            )
        }
    }

    override fun onPause() {
        isAppInForeground = false
        Log.i(VOICE_TAG, "activity onPause callProxHeld=${proximityWakeLock?.isHeld == true}")
        // Do NOT stop voice proximity here — cheek/near blanks screen and
        // pauses the activity; Dart owns stop when playback ends.
        disableCallProximity()
        voiceProximityEventSink?.success(
            voiceAudioSnapshot(reason = "activity_onPause").also {
                it["near"] = voiceProximityNear ?: false
            },
        )
        super.onPause()
    }

    override fun onDestroy() {
        disableCallProximity()
        stopVoiceProximity()
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
        Log.i(VOICE_TAG, "callProximity ENABLE (screen-off wake lock)")
        val pm = getSystemService(POWER_SERVICE) as PowerManager
        @Suppress("DEPRECATION")
        proximityWakeLock = pm.newWakeLock(
            PowerManager.PROXIMITY_SCREEN_OFF_WAKE_LOCK,
            "familychat:call_proximity",
        )
        proximityWakeLock?.acquire()
    }

    private fun disableCallProximity() {
        if (proximityWakeLock == null) return
        Log.i(VOICE_TAG, "callProximity DISABLE")
        proximityWakeLock?.let {
            if (it.isHeld) it.release()
        }
        proximityWakeLock = null
    }

    /** @return true if the device has a proximity sensor. */
    private fun startVoiceProximity(): Boolean {
        stopVoiceProximitySensorOnly()
        val sm = getSystemService(SENSOR_SERVICE) as SensorManager
        val sensor = sm.getDefaultSensor(Sensor.TYPE_PROXIMITY) ?: return false
        voiceProximityMaxRange = sensor.maximumRange
        val maxRange = voiceProximityMaxRange
        Log.i(VOICE_TAG, "startVoiceProximity sensor=${sensor.name} maxRange=$maxRange")
        val listener = object : SensorEventListener {
            override fun onSensorChanged(event: SensorEvent?) {
                if (event == null || event.values.isEmpty()) return
                val dist = event.values[0]
                voiceProximityDist = dist
                // Near when distance is well below max range (typical: 0 vs ~5cm).
                val near = dist < maxRange.coerceAtLeast(0.1f) * 0.9f
                if (voiceProximityNear == near) return
                voiceProximityNear = near
                Log.i(VOICE_TAG, "proximity near=$near dist=$dist max=$maxRange")
                voiceProximityEventSink?.success(
                    voiceAudioSnapshot(reason = "sensor").also {
                        it["near"] = near
                        it["dist"] = dist.toDouble()
                        it["maxRange"] = maxRange.toDouble()
                    },
                )
            }

            override fun onAccuracyChanged(sensor: Sensor?, accuracy: Int) {}
        }
        voiceProximityListener = listener
        sm.registerListener(listener, sensor, SensorManager.SENSOR_DELAY_UI)
        registerVoiceVolumeObserver()
        return true
    }

    private fun stopVoiceProximity() {
        Log.i(VOICE_TAG, "stopVoiceProximity")
        stopVoiceProximitySensorOnly()
        unregisterVoiceVolumeObserver()
        voiceProximityNear = null
        voiceProximityDist = null
        // Leave the communication pipeline; restore phone-normal audio.
        val am = getSystemService(AUDIO_SERVICE) as AudioManager
        @Suppress("DEPRECATION")
        am.isSpeakerphoneOn = false
        am.mode = AudioManager.MODE_NORMAL
    }

    private fun stopVoiceProximitySensorOnly() {
        val listener = voiceProximityListener ?: return
        val sm = getSystemService(SENSOR_SERVICE) as SensorManager
        sm.unregisterListener(listener)
        voiceProximityListener = null
    }

    private fun registerVoiceVolumeObserver() {
        if (voiceVolumeObserver != null) return
        val observer = object : ContentObserver(Handler(Looper.getMainLooper())) {
            override fun onChange(selfChange: Boolean) {
                Log.i(VOICE_TAG, "volume/settings changed selfChange=$selfChange")
                voiceProximityEventSink?.success(
                    voiceAudioSnapshot(reason = "volume_change").also {
                        it["near"] = voiceProximityNear ?: false
                        voiceProximityDist?.let { d -> it["dist"] = d.toDouble() }
                        it["maxRange"] = voiceProximityMaxRange.toDouble()
                    },
                )
            }
        }
        voiceVolumeObserver = observer
        try {
            contentResolver.registerContentObserver(
                Settings.System.CONTENT_URI,
                true,
                observer,
            )
        } catch (e: Exception) {
            Log.w(VOICE_TAG, "volume observer failed: $e")
        }
    }

    private fun unregisterVoiceVolumeObserver() {
        val observer = voiceVolumeObserver ?: return
        try {
            contentResolver.unregisterContentObserver(observer)
        } catch (_: Exception) {
        }
        voiceVolumeObserver = null
    }

    /**
     * Toggle earpiece ↔ loudspeaker without recreating the audio path.
     * Keep [MODE_IN_COMMUNICATION] for both — flipping MODE_NORMAL↔IN_COMM
     * (or AudioTrack usage) mid-play causes ~1–2s mute.
     */
    private fun setVoiceAudioRoute(earpiece: Boolean) {
        val before = voiceAudioSnapshot(reason = "route_before")
        val am = getSystemService(AUDIO_SERVICE) as AudioManager
        @Suppress("DEPRECATION")
        am.mode = AudioManager.MODE_IN_COMMUNICATION
        am.isSpeakerphoneOn = !earpiece
        val after = voiceAudioSnapshot(reason = "route_after")
        Log.i(
            VOICE_TAG,
            "setVoiceAudioRoute earpiece=$earpiece before=$before after=$after",
        )
    }

    private fun voiceAudioSnapshot(reason: String): HashMap<String, Any?> {
        val am = getSystemService(AUDIO_SERVICE) as AudioManager
        @Suppress("DEPRECATION")
        val mode = am.mode
        @Suppress("DEPRECATION")
        val speakerOn = am.isSpeakerphoneOn
        val modeName = when (mode) {
            AudioManager.MODE_NORMAL -> "NORMAL"
            AudioManager.MODE_RINGTONE -> "RINGTONE"
            AudioManager.MODE_IN_CALL -> "IN_CALL"
            AudioManager.MODE_IN_COMMUNICATION -> "IN_COMMUNICATION"
            else -> "mode_$mode"
        }
        return hashMapOf(
            "reason" to reason,
            "mode" to modeName,
            "modeInt" to mode,
            "speakerOn" to speakerOn,
            "musicVol" to am.getStreamVolume(AudioManager.STREAM_MUSIC),
            "musicMax" to am.getStreamMaxVolume(AudioManager.STREAM_MUSIC),
            "voiceVol" to am.getStreamVolume(AudioManager.STREAM_VOICE_CALL),
            "voiceMax" to am.getStreamMaxVolume(AudioManager.STREAM_VOICE_CALL),
            "ringVol" to am.getStreamVolume(AudioManager.STREAM_RING),
            "wiredHeadset" to am.isWiredHeadsetOn,
            "btA2dp" to am.isBluetoothA2dpOn,
            "btSco" to am.isBluetoothScoOn,
            "callProxHeld" to (proximityWakeLock?.isHeld == true),
            "fg" to isAppInForeground,
            "near" to (voiceProximityNear ?: false),
            "dist" to voiceProximityDist?.toDouble(),
            "maxRange" to voiceProximityMaxRange.toDouble(),
        )
    }
}
