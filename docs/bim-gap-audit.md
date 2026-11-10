# SketchUPbuildingToolの実装差分

2026年11月10日 · v1.31.0。Archicad・Revitの公式資料とSketchUPbuildingToolのコード・検証記録を照合した。範囲は建築一般図の作図、図面化、変更後の再発行。比較先の製品の操作性は実機で比較していない。

## 優先して補う差分

| 順位 | 差分 | v1.31.0の状態 | 最小の実装と合格条件 |
| --- | --- | --- | --- |
| 1 | **更新漏れと参照漏れの検出** | 発行時はSKPの保存状態、仮シーン、縮尺・図番などを検査する。壁や開口を編集してSKPだけ保存した場合、図面注記が古いことを直接判定する仕組みは見当たらない。発行セットが平面の参照先断面を含むかも検査していない。 | 発行対象に「最新・要更新・参照先が発行対象外」を表示する。窓幅を変更してSKPだけ保存すると該当平面・表を特定できる。断面を除いたセットでは参照先が表示され、対象に加える判断ができる。 |
| 2 | **同じ階の複数ビューと表示範囲** | 一般平面と梁伏図は分かれている。一般平面のキーは階ごとに固定。切断高さ、建具寸法、層別ハッチは保存できる。同じ階に複数の一般平面を登録する仕組み、上下の投影範囲、共用テンプレートが残る。 | 同じ1FLの一般平面と部分平面を別の名前・縮尺で登録する。上限、切断面、下限、見える奥行きを保存する。頭上の梁・庇を用途に応じて破線・実線・非表示に切り替えられる。 |
| 3 | **任意寸法・タグとモデルの関連** | 通り芯、外形、建具、階高、梁下などの自動注記はある。任意の面や部材に関連付ける寸法・タグを、拡張が図面更新後も管理する仕組みは見当たらない。 | 壁の内法、柱芯から外壁仕上面まで、建具の寄りなどを図面上でクリックして追加する。偏芯や開口幅の変更に値と参照先が追従し、参照要素の削除時は更新不能が分かる。 |
| 4 | **掲載シートへの参照と図面目録** | A-07などの図面番号はシーンに保持する。複数配置のM-01などは出力順に割り当てる。断面記号は元のA番号を指すため、複数配置後は掲載先M番号を照合する必要がある。 | 用紙の番号と各ビューの番号を分けて保持し、どのシートの何番目に載ったかを発行対象から解決する。並べ替えや別セットでも断面記号と図面目録の掲載先が一致する。 |
| 5 | **仕上げ層を含む取り合いの一貫性** | 壁・床の層、壁上端の梁・床・屋根への追従、鋼管と壁の平面投影整理はある。別々に作った部材の交差を材料層の優先度で統一処理する仕組みは見当たらない。 | 外壁と間仕切りのT字、外壁と2階梁・床から始める。平面・断面と数量で取り合いが一致する。部材を動かした場合は、再処理の結果か確認箇所が分かる。 |

コード上の根拠は、図面キー・表示・再生成の [drawings.rb](../extension/sbr_architecture/drawings.rb)、発行時の検査と配置の [layout_sheets.rb](../extension/sbr_architecture/layout_sheets.rb)、断面参照の [drawing_datums.rb](../extension/sbr_architecture/drawing_datums.rb)、既存LayOutで表だけを更新する [layout_schedule_update.rb](../extension/sbr_architecture/layout_schedule_update.rb)。

## 項目別の照合

| 項目 | Archicad・Revitでの参照 | v1.31.0の対応と差分 |
| --- | --- | --- |
| 図面の更新状態 | ArchicadのDrawing Managerは参照元・掲載先・更新状態を一覧化する。[Graphisoft公式](https://help.graphisoft.com/AC/22/INT/_AC22_Help/130_UserInterfaceDialogBoxes/130_UserInterfaceDialogBoxes-74.htm) | **一部対応。** シーン全更新、LayOut参照更新、表の差し替えは個別にできる。要更新一覧と発行前の整合確認が残る。 |
| 表示設定とビュー範囲 | Archicadは縮尺・レイヤー・ペンセット・モデル表示をビューに保存する。Revitはビューテンプレートとビュー範囲を持つ。[Archicadのビュー設定](https://help.graphisoft.com/AC/29/INT/_AC29_Help/140_UserInterfaceDialogBoxes/140_UserInterfaceDialogBoxes-68.htm) · [Revitのビュー範囲](https://help.autodesk.com/cloudhelp/2026/ENU/Revit-DocumentPresent/files/GUID-58711292-AB78-4C8F-BAA1-0855DDB518BF.htm) · [Revitのビューテンプレート](https://help.autodesk.com/cloudhelp/2022/ENU/Revit-Customize/files/GUID-C3B5FB82-3247-48F6-82F0-73011A0F8027.htm) | **一部対応。** 一般平面と梁伏図を個別に保存できる。用途別テンプレート、同じ階の複数平面、同じ向きの複数立面、モデル・注記それぞれのトリミング範囲、見上げ図が残る。 |
| 断面・部分図・室内展開 | Revitは平面・立面・断面から範囲を囲って詳細ビューを作り、元のビューから参照できる。[Autodesk公式](https://help.autodesk.com/cloudhelp/2026/ENU/Revit-DocumentPresent/files/GUID-34B3A4F2-8D79-4475-8AFD-D8C108F30130.htm) | **一部対応。** X・Yの縦断面、見通しの奥行き、平面からの位置指定はある。モデルから作る部分詳細図、室内展開図、斜め・折れ断面は拡張の図面種類・入力にない。 |
| 寸法・タグ・高さ | Revitは寸法の参照点を選べ、タグは要素の属性を図面に表示できる。[寸法の参照線](https://help.autodesk.com/cloudhelp/2022/ENU/Revit-DocumentPresent/files/GUID-3032EF48-3FB7-4602-A1BD-F79ADFFCFDFD.htm) · [タグ](https://help.autodesk.com/cloudhelp/2027/ENU/Revit-DocumentPresent/files/GUID-0BF5C1C2-445E-43E6-9680-40C2818A8BAF.htm) | **一部対応。** 既定の寸法・建具記号・室名は生成する。任意の連動寸法と属性タグ、天井高などの追加注記、注記の手動位置調整を再生成時に保持する仕組みが残る。 |
| 図番・目録・改訂 | Revitにシート一覧、Archicadにレイアウトと変更の管理がある。[Revitのシート一覧](https://help.autodesk.com/cloudhelp/2026/ENU/Revit-DocumentPresent/files/GUID-9E7032E7-62D7-4A72-AE0A-2E665A0E249F.htm) · [Archicadの変更項目](https://help.graphisoft.com/AC/30/INT/Topics/070_Documentation/070_Documentation-105.html) | **一部対応。** 図番、共有図枠、案件名・日付、複数配置、発行セットがある。実掲載先、目録、改訂番号と変更箇所・発行履歴、既存LayOutへの図面追加・差し替えの管理が残る。 |
| PDF・用紙・図枠 | ArchicadはPublisherでPDFをまとめて発行できる。[Graphisoft公式](https://helpcenter.graphisoft.com/user-guide-chapter/86912/) | **一部対応。** セットからLayOutに出力できる。PDF直接出力は未実装。自動配置はA3横が固定で、A2・A1や事務所図枠のプリセットは残る。 |
| 壁・梁・床の取り合い | Archicadは建材の優先度に基づき、交差する部材を材料層単位で処理する。[Graphisoft公式](https://help.graphisoft.com/AC/29/INT/_AC29_Help/040_ElementsVB/040_ElementsVB-271.htm) | **一部対応。** 偏芯、複合層、個別の壁上端ルール、平面の柱・壁線整理がある。個別部材をまたぐT字・十字と層優先度、図面と数量を同じ交差処理から算出する機能が残る。 |
| 作図プリセット・所属階 | ArchicadのFavoritesは部材設定を名前付きで再利用できる。[Graphisoft公式](https://help.graphisoft.com/AC/29/INT/_AC29_Help/020_Configuration/020_Configuration-56.htm) | **一部対応。** 規格断面とパレット設定、芯・階への関連付けがある。パレットの既定値は現行モデル用のメモリ保持。外壁仕様などの名前付き保存・別モデルでの呼び出しと、所属階・高さ基準を別々に扱う一般的な部材設定が残る。 |
| 室境界・仕上げ | Revitは室境界を持つ要素と室分離線を使える。[Autodesk公式](https://help.autodesk.com/cloudhelp/2026/ENU/Revit-GetStarted/files/GUID-D5E8ECD8-3F58-456F-B4DB-6366491A78DB.htm) | **一部対応。** 壁内法と床開口で室面積を出し、室一覧に載せる。開放されたLDKの室分割線、室番号、床・壁・天井の仕上げ属性と仕上表、天井のモデル化が残る。 |
| 建具表・数量・属性 | Archicadは要素・構成材・表面の集計と、対話的な表からの属性編集に対応する。[Graphisoft公式](https://help.graphisoft.com/AC/30/INT/Topics/055_InteractiveSchedule/055_InteractiveSchedule-1.html) | **一部対応。** 建具表・室一覧・CSVと表更新がある。建具姿図、部材記号や断面を使う構造部材表、仕上げ数量、列・集計条件の自由設定、表から元モデルへの属性反映が残る。 |
| モデル化の範囲 | 基本ツールの対応範囲として別管理する。 | **一部対応。** 矩形の片流れ・切妻、直階段、矩形床開口、壁付け引戸を実装済み。複数の屋根面をまたぐ壁、折返し階段・手すり、非矩形開口、壁内戸袋、敷地・地盤線を使う配置図の専用手順が残る。 |
| 改修 | Archicadは既存・撤去・新設の状態と図面ごとの表示を管理する。[Graphisoft公式](https://help.graphisoft.com/AC/29/INT/_AC29_Help/050_ViewsVB/050_ViewsVB-110.htm) | **開発対象外。** 現況・撤去・新設の状態管理は新築一般図の実装計画から外した。 |
| IFCの受け渡し | 拡張で作った部材と出力対象を照合する。 | **一部対応。** IFC4出力は既存。屋根・階段・室はエクスポートする部材一覧にない。[対象部材](../extension/sbr_architecture/ifc_export.rb) |

## 実装と受入の順番

1. **発行前の更新・参照チェック。** 発行セットをLayOutへ出力する。木造2階建てで窓、柱芯、階高、外壁偏芯を変更し、選択したシーン・表と掲載先を確認する。1:50・1:100のA3で、LayOutから出したPDFの用紙と実寸を照合し、既存LayOutの配置・追記を保って参照更新する。
2. **用途別ビュー、任意寸法、図面目録。** 同じ階から一般平面と部分平面を別々に保存し、注記と掲載先を変更後も追跡できるようにする。小規模案件では既定の表示を選ぶだけで作図に入れるようにする。
3. **作図範囲の拡張。** 外壁の取り合い、室分割と仕上表、折返し階段、詳細図、部材プリセットを案件に必要な順に進める。

偏芯、平面クリックの断面指定、通り芯丸囲み、梁伏図、表更新、複数配置、発行セットは実装済み。自動テストやSDKでの個別確認と、同じ現行版でのSketchUpからLayOutまでの通し確認を分けて管理する。構造計算と接合部の性能判定は別工程。
