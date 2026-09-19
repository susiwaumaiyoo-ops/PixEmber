package com.example.pixiv_viewer

import android.content.Context
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

/**
 * native_llm 用 MethodChannel を全 FlutterEngine で共通登録する。
 *
 * ローカルLLM推論（[NativeLlmEngine]）は dlopen 先として
 * `applicationInfo.nativeLibraryDir` を MethodChannel で取得する。
 * flutter_foreground_task は TaskHandler 用の背面 FlutterEngine を毎回
 * 新規生成するため、MainActivity の configureFlutterEngine だけだと
 * そのエンジンではチャンネル未登録で失敗する（§6-A）。
 * UI(主)エンジンと背面エンジンの双方で同じ登録を行う。
 */
object NativeLlmChannel {
    const val CHANNEL = "com.example.pixiv_viewer/native_llm"

    fun register(engine: FlutterEngine, context: Context) {
        MethodChannel(
            engine.dartExecutor.binaryMessenger,
            CHANNEL,
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "getNativeLibraryDir" ->
                    result.success(context.applicationInfo.nativeLibraryDir)
                else -> result.notImplemented()
            }
        }
    }
}
