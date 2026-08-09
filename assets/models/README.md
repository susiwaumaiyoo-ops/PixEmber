# ONNX Models Directory

このディレクトリに日本語対応の軽量Embeddingモデル（ONNX形式）を配置してください。

## 推奨モデル

- **paraphrase-multilingual-MiniLM-L12-v2** (ONNX変換版)
  - サイズ: 約50MB
  - 次元数: 384次元
  - 日本語対応: 〇
  - ライセンス: Apache 2.0

## 入手方法

1. Hugging Face からモデルをダウンロード
2. `optimum` ライブラリで ONNX 形式に変換:
   ```bash
   pip install optimum[onnxruntime]
   optimum-cli export onnx --model sentence-transformers/paraphrase-multilingual-MiniLM-L12-v2 ./onnx_model
   ```
3. 生成された `model.onnx` をこのディレクトリに配置し、以下のファイル名にリネーム:
   - `embedding_model.onnx`

## ファイル構成

```
assets/models/
├── embedding_model.onnx      # メインモデル (必須)
├── tokenizer.json           # トークナイザー (必須)
├── special_tokens_map.json  # 特殊トークンマップ (必須)
└── tokenizer_config.json    # トークナイザー設定 (必須)
```

**注意**: 実際のモデルファイルはGitに含めず、ビルド時に手動で配置してください。`.gitignore` に `assets/models/*.onnx` 等を追加推奨。