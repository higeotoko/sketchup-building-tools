# SketchBRep 建築ツール

SketchUpで通り芯・階・壁・床・柱・梁・基礎を作図し、図面シーン・建具表・数量・IFC4にまとめる拡張です。

- `extension/sbr_architecture.rb` と `extension/sbr_architecture/` が拡張本体です。RBZを作る際は、この2つをZIPのルートに置きます。
- 開発状況と実機確認の範囲は [ロードマップ](docs/roadmap.md) に記載しています。
- `ruby test/verify_wall_heads.rb` で壁上端の寸法計算と、開口・平面切断への反映を確認できます。立体生成とIFC出力の確認にはSketchUp本体を使用します。
