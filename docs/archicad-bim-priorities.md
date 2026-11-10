# Archicadの基本ツールとSketchUPbuildingToolの実装優先順位

2026年11月10日 · 比較対象はGraphisoft公式ヘルプとSketchUPbuildingTool v1.23.0の実装・検証記録。

v1.31.0時点の状態は、[Archicad・Revitとの実装差分](bim-gap-audit.md)を参照。

## 比較から採用する設計

Archicadでは、壁や梁が持つ形状・材質・所属階をモデル側に保存し、縮尺・表示レイヤー・モデル表示設定をビュー側に保存する。ビューをレイアウトに配置し、発行セットで出力対象をまとめる。同じ階のモデルから、一般平面と構造部材を見る図面を別々の表示設定で作れる。SketchUPbuildingToolでも、部材の属性と図面の表示設定を分け、図面の用途を選ぶだけで必要な設定がそろうようにする。 [Graphisoftのビュー設定](https://help.graphisoft.com/AC/30/INT/Topics/140_UserInterfaceDialogBoxes/140_UserInterfaceDialogBoxes-68.html) · [レイアウトへの配置](https://help.graphisoft.com/AC/30/INT/Topics/070_Documentation/070_Documentation-88.html) · [Publisher](https://help.graphisoft.com/AC/30/INT/Topics/070_Documentation/070_Documentation-117.html)

| 基本ツール | Archicadの動作 | SketchUPbuildingToolの現在地と差分 |
| --- | --- | --- |
| 階・通り芯・配置設定 | 部材に所属階を持たせ、壁上端を上階へリンクできる。頻用設定はFavoritesから呼び出す。 [壁](https://help.graphisoft.com/AC/30/INT/Topics/040_ElementsVB/040_ElementsVB-6.html) · [Favorites](https://help.graphisoft.com/AC/30/INT/Topics/020_Configuration/020_Configuration-56.html) | 階、通り芯、仮シーン、部材の階・芯への関連付け、パレットとボタン間の設定共有がある。配置時に所属階と実際の高さ基準を見分けられるようにする余地がある。 |
| 壁・床・柱・梁・基礎 | 壁などを部材として配置し、複合層や材料を持たせる。材料の優先度と実際の交差で取り合いを処理する。 [部材の配置](https://help.graphisoft.com/AC/30/INT/Topics/040_ElementsVB/040_ElementsVB-3.html) · [交差の原則](https://help.graphisoft.com/AC/26/INT/_AC26_Help/040_ElementsVB/040_ElementsVB-270.htm) | 壁・床の層、壁上端の一部追従、木造・鉄骨・RCの柱梁、布基礎・独立基礎がある。角形鋼管内に見える壁線と、断面で重なる線の整理を優先する。 |
| 窓・扉・一般開口 | 窓・扉は壁に属し、記号と実体の表示を分けられる。一般開口は床などにも作れる。 [建具の表示](https://help.graphisoft.com/AC/30/INT/Topics/140_UserInterfaceDialogBoxes/140_UserInterfaceDialogBoxes-39.html) · [一般開口](https://help.graphisoft.com/AC/30/INT/Topics/040_ElementsVB/040_ElementsVB-268.html) | 壁の窓・扉は配置、開き勝手、記号、寸法、一覧に連動する。階段や吹抜けを表す床開口を追加する。 |
| 屋根 | 単一面と複数面の屋根を作り、接続した壁などを屋根に合わせて切り揃えられる。 [屋根](https://help.graphisoft.com/AC/25/INT/_AC25_Help/040_ElementsVB/040_ElementsVB-70.htm) | v1.21.0で矩形の片流れ・切妻に壁上端を関連付けられる。屋根が1件の場合は立面に高さを自動表示する。複数の屋根をまたぐ壁や複雑な屋根は今後の範囲。 |
| 階段・手すり | 階段の形状に加え、階別の平面記号に上り線や切断記号を設定できる。 [階段の平面表示](https://help.graphisoft.com/AC/29/INT/_AC29_Help/040_ElementsVB/040_ElementsVB-202.htm) | 矩形の床開口と直階段が連動する。両階の平面と縦断面に表示する。手すりや複雑な階段は今後の工程。 |
| 室・面積・表 | ゾーンは壁の内面や基準線、手動入力から作り、室名や面積を表示できる。モデルから要素・構成材・表面の一覧を作れる。 [ゾーンの作成](https://help.graphisoft.com/AC/27/INT/_AC27_Help/040_ElementsVB/040_ElementsVB-137.htm) · [Interactive Schedule](https://help.graphisoft.com/AC/30/INT/Topics/055_InteractiveSchedule/055_InteractiveSchedule-1.html) | 閉じた壁内法から室名・面積を作り、一覧・CSVに反映できる。図面に載せられる建具表・室一覧は今後の工程。 |
| 平面・立面・断面 | 平面の切断高さ、階への表示範囲、切断・下方投影・上方投影を設定できる。断面マーカーから元のビューや図面を参照できる。 [平面表示](https://help.graphisoft.com/AC/30/INT/Topics/050_ViewsVB/050_ViewsVB-14.html) · [階への表示](https://help.graphisoft.com/AC/30/INT/Topics/050_ViewsVB/050_ViewsVB-13.html) · [断面参照](https://help.graphisoft.com/AC/30/INT/Topics/050_ViewsVB/050_ViewsVB-40.html) | 階別平面、4立面、縦断面、断面参照線、切断ハッチ、梁下寸法がある。平面表示の判断が部材ごとに分かれ、同じ階の用途別ビューや線の優先順がそろっていない。 |
| 図枠・配置・発行 | 共通の図枠を複数シートに適用し、ビューやシートを発行セットに登録できる。 [マスターレイアウト](https://help.graphisoft.com/AC/30/INT/Topics/070_Documentation/070_Documentation-86.html) · [Publisher](https://help.graphisoft.com/AC/30/INT/Topics/070_Documentation/070_Documentation-117.html) | 共通図枠付きA3、1ページ1ビュー、1:50・1:100と既存LayOutの参照更新を実機で確認済み。複数配置や発行セットは後段で扱う。 |

## 実装順と合格条件

1. **P0　平面図の表示を先に固める — v1.19.0で実機確認済み**
   - まず鉄骨平面で鋼管の中空部に現れる壁線の出どころを切り分け、実断面と壁の投影を整理する。一般平面は、切断した形状と床面から切断面までの投影を読み分けられるようにする。頭上の梁は用途別の図面表示で扱う。最初の変更は現行の平面表示に絞る。
   - **合格条件**　木造・RC・鉄骨の1:50・1:100で柱・壁・開口が判読でき、鋼管の中空部に壁線が残らない。頭上の梁が一般平面に出ず、縦断面では切った梁型が見える。赤い通り芯、断面参照線、平面での建具配置・編集を保つ。
2. **P1　立面・断面に必要な屋根を作れるようにする**
   - 外周を拾い、屋根の基準高さ・勾配・軒の出を指定する。片流れと切妻から始め、屋根に合わせる壁を選べるようにする。RC・鉄骨の陸屋根は床スラブで表現する経路を整理する。
   - **合格条件**　勾配か軒の出を一度変更すると、屋根の形と壁上端、立面の外形、断面、軒高・棟高が同じ形状に基づいて更新される。
3. **P1　床開口と階段を一組で作る — v1.22.0で実機確認済み**
   - 床開口は親床の属性に保存し、矩形から始める。直階段は下階・上階を選んで平面上で始点と上り方向を決める。下階平面に上り方向と切断記号、上階平面に開口を出す。
   - **合格条件**　床開口の形状・床面積・両階の平面・縦断面が一致する。階高や開口寸法の変更後も同じ階段と床から更新できる。
4. **P1　一般図に必要な注記と既存LayOutの更新を通す**
   - 室名・面積は閉じた壁内面をクリックして置く。断面はGL・FL・梁下に加え、参照を選んだ階高と主要高さを入れる。既存の建具一覧と平面記号を同じ建具IDで照合する。
   - **合格条件**　2階建て1棟の平面2枚・立面4枚・断面2枚が、同じSKPからA3に出る。階高・開口・屋根の変更後も既存LayOutの図番・縮尺・配置を保ち、モデルと図面の形状・寸法が一致する。
5. **P2　図面の用途と出力先を選びやすくする**
   - 「一般平面」「梁伏図」のような用途を選ぶと、保存済みの表示と縮尺を呼び出す。次に、建具表・室一覧のシート配置、複数ビュー配置、発行セット、部材プリセットを進める。
   - **合格条件**　同じ階の一般平面と梁伏図を保存し、片方の設定変更で他方やモデル本体が変わらない。表と図面に同じ部材ID・寸法が出る。

操作は現行の建築パレットを入口とし、作図ボタン、階、主要寸法、配置中のプレビューを優先する。木造・鉄骨・RCの形状は既存カタログを使う。土台は1FLを基準に据付高さを指定し、2階床を受ける梁は2FLを基準に梁天端のオフセットを指定する運用を候補とする。どちらも所属階と実際のZを表示し、図面に出る階は表示設定で決める。

構造計算・接合部の性能判定・設備・カーテンウォール・地形・高度な改訂管理は別工程に置く。今回の比較は公式資料と現行版のコード・検証記録に基づく。Archicadの操作時間や使い勝手は実機で比較していない。
