package com.example.pixiv_viewer

import android.app.Application
import com.pravera.flutter_foreground_task.FlutterForegroundTaskLifecycleListener
import com.pravera.flutter_foreground_task.FlutterForegroundTaskPlugin
import com.pravera.flutter_foreground_task.FlutterForegroundTaskStarter
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugins.GeneratedPluginRegistrant

/**
 * PixEmber Application。
 *
 * flutter_foreground_task の TaskHandler は実行のたびに新しい
 * FlutterEngine を生成するが、そのエンジンには GeneratedPluginRegistrant が
 * 自動適用されない（BRIEF.md §6-A）。結果として自動要約が背面エンジンで
 * sqflite / shared_preferences / battery_plus / connectivity_plus に
 * 触れられず、さらに native_llm の nativeLibraryDir も解決できない。
 *
 * ここでお気に入りの lifecycle listener を登録し、onEngineCreate で
 *  1. GeneratedPluginRegistrant.registerWith → 主要プラグインを背面エンジンへ
 *  2. NativeLlmChannel.register → nativeLibraryDir MethodChannel を背面エンジンへ
 * を行い、推論スタックを FGS エンジンで動作可能にする。
 * （UI エンジンは FlutterActivity が自動登録するが、MethodChannel は
 *   MainActivity 経由で別途登録する。messenger 単位なので衝突しない。）
 */
class PixEmberApplication : Application() {
    override fun onCreate() {
        super.onCreate()
        FlutterForegroundTaskPlugin.addTaskLifecycleListener(taskLifecycleListener)
    }

    private val taskLifecycleListener =
        object : FlutterForegroundTaskLifecycleListener {
            override fun onEngineCreate(flutterEngine: FlutterEngine?) {
                val engine = flutterEngine ?: return
                GeneratedPluginRegistrant.registerWith(engine)
                NativeLlmChannel.register(engine, applicationContext)
            }

            override fun onTaskStart(starter: FlutterForegroundTaskStarter) {}
            override fun onTaskRepeatEvent() {}
            override fun onTaskDestroy() {}
            override fun onEngineWillDestroy() {}
        }
}
