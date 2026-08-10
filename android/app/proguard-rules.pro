# ONNX Runtime (Java/JNI) — JNI が GetMethodID/FindClass で参照するため難読化・削除を禁止
-keep class ai.onnxruntime.** { *; }
-keepclassmembers class ai.onnxruntime.** { *; }
-dontwarn ai.onnxruntime.**
