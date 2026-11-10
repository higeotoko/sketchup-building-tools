# SketchUPbuildingTool

SketchUp向けの建築モデリング・図面作成拡張です。v1.20.0から拡張機能マネージャー、ツールバー、パレットの表示名をSketchUPbuildingToolに統一しました。旧版と同じRBZの読み込み先とモデル属性を使用します。上書きインストール後、SketchUpを再起動してください。

SketchUpで通り芯・階・壁・床・柱・梁・基礎を作図し、図面シーン・建具表・数量・IFC4にまとめる拡張です。

- `extension/sbr_architecture.rb` と `extension/sbr_architecture/` が拡張本体です。RBZを作る際は、この2つをZIPのルートに置きます。
- 開発状況と実機確認の範囲は [ロードマップ](docs/roadmap.md) に記載しています。
- [図面の完成条件とBIM比較](docs/drawing-readiness.md) に、平面・立面・断面で確認する項目をまとめています。
- [Archicad・Revitとの実装差分](docs/bim-gap-audit.md) に、発行前の確認や図面の作り分けで残る項目をまとめています。
- [平面での作業ガイド](docs/plan-workflow.md) に、通り芯から仮シーンを作り、平面で窓・扉を置いて編集する手順をまとめています。
- `ruby test/verify_wall_heads.rb` で壁上端の寸法計算と、開口・平面切断への反映を確認できます。立体生成とIFC出力の確認にはSketchUp本体を使用します。
