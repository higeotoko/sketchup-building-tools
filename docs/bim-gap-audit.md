# SketchUPbuildingToolの実装差分

2026年11月10日 · v1.40.0。Archicad・Revitの公式資料とSketchUPbuildingToolのコード・検証記録を照合した。範囲は建築一般図の作図、図面化、変更後の再発行。比較先の製品の操作性は実機で比較していない。

## 優先して補う差分

| 順位 | 差分 | v1.40.0の状態 | 最小の実装と合格条件 |
| --- | --- | --- | --- |
| 1 | **更新漏れと参照漏れの検出** | 発行時にSKPの保存状態、図面・室一覧の更新状態、発行セット外の断面参照を検査する。 | 発行操作の前に各図面の状態を一覧で確認できるようにする。設計変更後に要更新の図面と、セットに足す断面が分かる。 |
| 2 | **同じ階の複数ビューと表示範囲** | 同じ階の一般平面を別の名前・縮尺で登録できる。切断高さ・表示下限、頭上梁の表示上限、LayOutに配置する部分平面の矩形範囲を保存する。 | モデルと注記の範囲を個別に制御する。頭上の庇や設備を含む見上げ表現と、表示設定の共用テンプレートが残る。 |
| 3 | **任意寸法・タグとモデルの関連** | 壁仕上面と柱芯を参照する連動寸法と、柱・梁の構造種別と断面を示す引出線付きタグに対応する。図面更新で追従し、部材削除や範囲外への移動を発行前に検出する。 | 建具の寄りと通り芯を寸法の参照に追加する。部材符号やタグに表示する属性の組み合わせを指定できるようにする。 |
| 4 | **掲載シートへの参照と図面目録** | 断面・部分平面の参照図番に対応する掲載シートと位置を、発行時の目録に出す。発行セットや配置が変わると、新しいLayOutではその配置から目録を生成する。 | 既存LayOut上でシートの配置を変更したときに目録も更新できるようにする。 |
| 5 | **仕上げ層を含む取り合いの一貫性** | 壁・床の層、壁上端の梁・床・屋根への追従、鋼管と壁の平面投影整理はある。別々に作った部材の交差を材料層の優先度で統一処理する仕組みは見当たらない。 | 外壁と間仕切りのT字、外壁と2階梁・床から始める。平面・断面と数量で取り合いが一致する。部材を動かした場合は、再処理の結果か確認箇所が分かる。 |

コード上の根拠は、図面キー・表示・再生成の [drawings.rb](../extension/sbr_architecture/drawings.rb)、発行時の検査と配置の [layout_sheets.rb](../extension/sbr_architecture/layout_sheets.rb)、断面参照の [drawing_datums.rb](../extension/sbr_architecture/drawing_datums.rb)、既存LayOutで表だけを更新する [layout_schedule_update.rb](../extension/sbr_architecture/layout_schedule_update.rb)。

## 項目別の照合

| 項目 | Archicad・Revitでの参照 | v1.40.0の対応と差分 |
| --- | --- | --- |
| 図面の更新状態 | ArchicadのDrawing Managerは参照元・掲載先・更新状態を一覧化する。[Graphisoft公式](https://help.graphisoft.com/AC/22/INT/_AC22_Help/130_UserInterfaceDialogBoxes/130_UserInterfaceDialogBoxes-74.htm) | **一部対応。** 発行時に更新状態と断面参照を検査する。シーン全更新、LayOut参照更新、表の差し替えは個別に行う。図面一覧での状態表示と、掲載先を含めた管理が残る。 |
| 表示設定とビュー範囲 | Archicadは縮尺・レイヤー・ペンセット・モデル表示をビューに保存する。Revitはビューテンプレートとビュー範囲を持つ。[Archicadのビュー設定](https://help.graphisoft.com/AC/29/INT/_AC29_Help/140_UserInterfaceDialogBoxes/140_UserInterfaceDialogBoxes-68.htm) · [Revitのビュー範囲](https://help.autodesk.com/cloudhelp/2026/ENU/Revit-DocumentPresent/files/GUID-58711292-AB78-4C8F-BAA1-0855DDB518BF.htm) · [Revitのビューテンプレート](https://help.autodesk.com/cloudhelp/2022/ENU/Revit-Customize/files/GUID-C3B5FB82-3247-48F6-82F0-73011A0F8027.htm) | **一部対応。** 名前付き平面に下限・切断高さ・頭上梁の上限を保存し、LayOutでモデルと注記を同じ矩形に切り出せる。用途別テンプレート、同じ向きの複数立面、モデルと注記の個別トリミング、見上げ図が残る。 |
| 断面・部分図・室内展開 | Revitは平面・立面・断面から範囲を囲って詳細ビューを作り、元のビューから参照できる。[Autodesk公式](https://help.autodesk.com/cloudhelp/2026/ENU/Revit-DocumentPresent/files/GUID-34B3A4F2-8D79-4475-8AFD-D8C108F30130.htm) | **一部対応。** X・Yの縦断面、見通しの奥行き、平面からの位置指定はある。モデルから作る部分詳細図、室内展開図、斜め・折れ断面は拡張の図面種類・入力にない。 |
| 寸法・タグ・高さ | Revitは寸法の参照点を選べ、タグは要素の属性を図面に表示できる。[寸法の参照線](https://help.autodesk.com/cloudhelp/2022/ENU/Revit-DocumentPresent/files/GUID-3032EF48-3FB7-4602-A1BD-F79ADFFCFDFD.htm) · [タグ](https://help.autodesk.com/cloudhelp/2027/ENU/Revit-DocumentPresent/files/GUID-0BF5C1C2-445E-43E6-9680-40C2818A8BAF.htm) | **一部対応。** 平面の連動寸法に加え、柱・梁の断面タグを一般平面・梁伏図に配置できる。開口や通り芯の寸法参照、タグの書式・属性選択、天井高などの追加注記が残る。 |
| 図番・目録・改訂 | Revitにシート一覧、Archicadにレイアウトと変更の管理がある。[Revitのシート一覧](https://help.autodesk.com/cloudhelp/2026/ENU/Revit-DocumentPresent/files/GUID-9E7032E7-62D7-4A72-AE0A-2E665A0E249F.htm) · [Archicadの変更項目](https://help.graphisoft.com/AC/30/INT/Topics/070_Documentation/070_Documentation-105.html) | **一部対応。** 図番、共通図枠、複数配置、発行セットに加え、掲載シートとページを示す目録を出力できる。既存LayOutでの目録更新と図面の追加・差し替え、改訂番号と発行履歴の管理が残る。 |
| PDF・用紙・図枠 | ArchicadはPublisherでPDFをまとめて発行できる。[Graphisoft公式](https://helpcenter.graphisoft.com/user-guide-chapter/86912/) | **一部対応。** セットからLayOutに出力できる。PDF直接出力は未実装。自動配置はA3横が固定で、A2・A1や事務所図枠のプリセットは残る。 |
| 壁・梁・床の取り合い | Archicadは建材の優先度に基づき、交差する部材を材料層単位で処理する。[Graphisoft公式](https://help.graphisoft.com/AC/29/INT/_AC29_Help/040_ElementsVB/040_ElementsVB-271.htm) | **一部対応。** 偏芯、複合層、個別の壁上端ルール、平面の柱・壁線整理がある。個別部材をまたぐT字・十字と層優先度、図面と数量を同じ交差処理から算出する機能が残る。 |
| 作図プリセット・所属階 | ArchicadのFavoritesは部材設定を名前付きで再利用できる。[Graphisoft公式](https://help.graphisoft.com/AC/29/INT/_AC29_Help/020_Configuration/020_Configuration-56.htm) | **一部対応。** 規格断面とパレット設定、芯・階への関連付けがある。パレットの既定値は現行モデル用のメモリ保持。外壁仕様などの名前付き保存・別モデルでの呼び出しと、所属階・高さ基準を別々に扱う一般的な部材設定が残る。 |
| 室境界・仕上げ | Revitは室境界を持つ要素と室分離線を使える。[Autodesk公式](https://help.autodesk.com/cloudhelp/2026/ENU/Revit-GetStarted/files/GUID-D5E8ECD8-3F58-456F-B4DB-6366491A78DB.htm) | **一部対応。** 壁内法と床開口で室面積を出し、室一覧に載せる。開放されたLDKの室分割線、室番号、床・壁・天井の仕上げ属性と仕上表、天井のモデル化が残る。 |
| 建具表・数量・属性 | Archicadは要素・構成材・表面の集計と、対話的な表からの属性編集に対応する。[Graphisoft公式](https://help.graphisoft.com/AC/30/INT/Topics/055_InteractiveSchedule/055_InteractiveSchedule-1.html) | **一部対応。** 建具表・室一覧・CSVと表更新がある。建具姿図、部材記号や断面を使う構造部材表、仕上げ数量、列・集計条件の自由設定、表から元モデルへの属性反映が残る。 |
| モデル化の範囲 | 基本ツールの対応範囲として別管理する。 | **一部対応。** 矩形の片流れ・切妻、直階段と端部の回り段、矩形床開口、壁付け引戸を実装済み。複数の屋根面をまたぐ壁、踊り場付き階段・手すり、非矩形開口、壁内戸袋、敷地・地盤線を使う配置図の専用手順が残る。 |
| 改修 | Archicadは既存・撤去・新設の状態と図面ごとの表示を管理する。[Graphisoft公式](https://help.graphisoft.com/AC/29/INT/_AC29_Help/050_ViewsVB/050_ViewsVB-110.htm) | **開発対象外。** 現況・撤去・新設の状態管理は新築一般図の実装計画から外した。 |
| IFCの受け渡し | 拡張で作った部材と出力対象を照合する。 | **一部対応。** IFC4出力は既存。屋根・階段・室はエクスポートする部材一覧にない。[対象部材](../extension/sbr_architecture/ifc_export.rb) |

## 実装と受入の順番

1. **発行前の更新・参照チェック。** 発行セットをLayOutへ出力する。木造2階建てで窓、柱芯、階高、外壁偏芯を変更し、選択したシーン・表と掲載先を確認する。1:50・1:100のA3で、LayOutから出したPDFの用紙と実寸を照合し、既存LayOutの配置・追記を保って参照更新する。
2. **用途別ビュー、任意寸法、図面目録。** 同じ階から一般平面と部分平面を別々に保存し、注記と掲載先を変更後も追跡できるようにする。小規模案件では既定の表示を選ぶだけで作図に入れるようにする。
3. **作図範囲の拡張。** 外壁の取り合い、室分割と仕上表、折返し階段、詳細図、部材プリセットを案件に必要な順に進める。

偏芯、平面クリックの断面指定、通り芯丸囲み、梁伏図、表更新、複数配置、発行セットは実装済み。自動テストやSDKでの個別確認と、同じ現行版でのSketchUpからLayOutまでの通し確認を分けて管理する。構造計算と接合部の性能判定は別工程。
