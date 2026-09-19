package com.example.pixiv_viewer

import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine

/**
 * PixEmber MainActivity。
 *
 * ネイティブLLMレイヤー（libnative_llm.so / HTP skel）は
 * `extractNativeLibs=true` で実ファイル展開される nativeLibraryDir から
 * dlopen / FastRPC Discovery される。Dart 側はこの絶対パスを
 * MethodChannel で取得し、`nllm_set_lib_dir` 経由で
 * ADSP_LIBRARY_PATH に設定するため、ディレクトリパスを提供する。
 */
class MainActivity : FlutterActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        // UI(主)エンジン向けの native_llm 登録。
        // 背面(TaskHandler)エンジン向けは PixEmberApplication.onEngineCreate で登録。
        NativeLlmChannel.register(flutterEngine, applicationContext)
    }
}
