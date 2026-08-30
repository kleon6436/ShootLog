# ShootLog RAW現像機能ブラッシュアップ調査

- 対象読者: ShootLogの設計・実装を判断する開発者
- 調査日: 2026-08-30
- 対象: Capture One Pro / Lightroom Classic の現像・補助ワークフロー
- 前提: 公式サポート資料で確認できる機能を比較し、ShootLogのmacOS 14+ / Swift 6 / SwiftUI / Core Image / SwiftData構成へ適用可能かを評価する
- 除外: カタログ管理、クラウド同期、テザー撮影、印刷管理そのものなど、現行の「選択フォルダを閲覧して非破壊現像する」主目的から外れる機能

## 結論

最優先で追加すべきなのは、AI機能ではなく「局所調整の土台」である。具体的には、非破壊レイヤー、ブラシ／線形／円形／輝度範囲／色範囲マスク、マスクの加算・減算・交差、レイヤー単位の調整と不透明度である。Capture OneとLightroomの主要な差別化機能は、グローバルスライダーの数ではなく、画像の一部分だけを安全に調整できることに集約されている。

その次に、現行の基本調整を実用的な現像へ引き上げる「Clarity/Texture/Dehaze」「シャドウ・中間調・ハイライトの3-wayカラーグレーディング」「B&Wミックス」「プロファイル／カメラキャリブレーション」「出力レシピ＋ソフトプルーフ」を追加する。AI被写体マスク、AIノイズ除去、HDR表示、修復・生成削除は価値が高いが、処理時間・モデル配布・色管理・ネットワーク依存が増すため、局所マスクの後段に置く。

## 現行ShootLogの到達点

実装済みとして確認できるものは、露出、コントラスト、ハイライト、シャドウ、白レベル、黒レベル、明るさ、色温度、色かぶり、自然な彩度、彩度、RGB／R／G／Bトーンカーブ、8帯域HSL、シャープ、輝度／色ノイズ低減、RAWプロファイルレンズ補正、手動レンズ補正、回転・トリミング、ヒストグラム、プリセット、相対プリセット適用、コピー＆ペースト、JPEG/TIFF書き出し、sRGB/Display P3選択、現像→超解像チェーンである。

したがって、単純な「露出や色のスライダー追加」は優先度が低い。現行の大きな不足は、調整の適用範囲、色の表現力、RAW入力プロファイル、ディテール制御、出力検証、複数写真への一貫した適用である。

### ホワイトバランスについての補足

現行実装にはホワイトバランスの**内部処理**は存在する。UIの「色温度」と「色かぶり補正」が`DevelopParameters.temperature` / `tint`に接続され、RAWでは`CIRAWFilter`の`neutralTemperature` / `neutralTint`へ、非RAWでは`CITemperatureAndTint`へ渡される。RAWの露出・WBスライダーはドラッグ中に近似表示し、操作終了後にRAWフィルターで再デコードする設計である。

ただし、ユーザー向けの「ホワイトバランス」機能としては不足している。現状は2本の抽象的なスライダーだけで、Capture OneやLightroomにある次の要素がない。

- 「ホワイトバランス」という明示的な見出し／モード名
- As Shot／撮影時設定へ戻す操作
- Auto WB
- Daylight、Cloudy、Shade、TungstenなどのRAW用プリセット
- 画像上のニュートラルグレー／白をクリックするスポイト
- 実際のKelvin値とTint値の表示
- WB設定のコピー、複数写真への同期

Capture OneはShot、光源プリセット、Kelvin/Tint、スポイト、Autoを提供する。[Capture One: White Balance modes](https://support.captureone.com/hc/en-us/articles/360002590757-Adjusting-by-mode-in-the-White-Balance-tool) [Capture One: White Balance picker](https://support.captureone.com/hc/en-us/articles/360002596138-Selecting-a-neutral-area-with-the-picker) Lightroom ClassicもAs Shot、Auto、光源プリセット、スポイト、Temp/Tint調整を提供する。[Lightroom Classic: Set the white balance](https://helpx.adobe.com/ca/lightroom-classic/help/image-tone-color.html)

従って、ホワイトバランスは「未実装」ではなく、**P0のUI／操作性不足**として扱うのが正確である。最初に`WhiteBalance`セクションを独立させ、`As Shot`ボタン、`Auto`ボタン、スポイト、Kelvin表示を追加するのがよい。現在の内部パラメータは相対オフセットなので、プリセットやスポイトを追加する際は、カメラのas-shot値とユーザーが設定した絶対Kelvin値を区別して保存する必要がある。

## 製品比較から得られる機能差分

### 1. 局所調整・マスク

Capture Oneは、レイヤーごとに複数の画像調整をまとめ、ブラシ、線形／円形グラデーション、Luma Range、Heal、Cloneなどを非破壊で適用する。最大16レイヤー、マスクの加算・減算・交差、AIのSubject／Background／People／Clothes／AI Select／AI Eraserまで提供する。[Capture One: Overview of Layers and Masks](https://support.captureone.com/hc/en-us/articles/360002601658-Overview-of-Layers-and-Masks) [Capture One: AI Masking](https://support.captureone.com/hc/en-us/articles/14055231933853-AI-Masking)

Lightroom Classicは、Subject、Sky、Background、Landscape、Objects、Peopleの自動マスクと、Brush、Linear Gradient、Radial Gradient、Color Range、Luminance Range、Depth Rangeを提供する。マスクの表示、範囲の滑らかさ、複数マスクの追加／減算がワークフローの中心である。[Lightroom Classic: Masking tool](https://helpx.adobe.com/lightroom-classic/help/masking.html) [Lightroom Classic: local adjustments by range](https://helpx.adobe.com/lightroom-classic/desktop/process-and-develop-photos/apply-local-adjustments.html)

**ShootLogへの推奨**: `DevelopLayer` と `DevelopMask` を導入する。最初は手動ブラシ、線形／円形、輝度範囲、色範囲に限定し、マスクをグレースケールの `CIImage` として生成する。各レイヤーは既存の `DevelopParameters` を持ち、`CIBlendWithMask` またはMetal/CIFilterチェーンで合成する。マスクの追加・減算・交差と反転、フェザー、表示オーバーレイは必須。AIマスクは同じマスク契約へ接続できるように後から追加する。

優先度: **P0**。難度: **高**。局所調整がない限り、Capture One/Lightroomとの差は埋まらない。

### 2. 基本トーンとローカルコントラスト

Capture OneはHDRツールのHighlight、Shadow、White、Blackに加えて、ClarityとStructureを持つ。Clarityは中間調の大きな遷移、Structureは細部の小さな遷移を扱い、方式としてNatural、Punch、Neutral、Classicを持つ。[Capture One: Clarity](https://support.captureone.com/hc/en-us/articles/360002605157-The-Clarity-tool-overview) [Capture One: HDR details](https://support.captureone.com/hc/en-us/articles/360002602737-Recovering-details-in-the-highlights-and-shadows)

Capture OneとLightroomの双方がDehazeを備える。Capture Oneでは霞の影色を自動検出またはユーザー指定し、レイヤー上でも再計算できる。[Capture One: Dehaze](https://support.captureone.com/hc/en-us/articles/360015551837-The-Dehaze-tool-overview) Lightroom ClassicのDevelopパネルにも、テクスチャ、クラリティ、かすみの除去、周辺光量、粒子などが含まれる。[Lightroom Classic: Develop tools](https://helpx.adobe.com/sg/lightroom-classic/help/develop-module-tools.html)

**ShootLogへの推奨**: `clarity`、`texture/structure`、`dehaze`、`vignette`、`grain` を追加する。Clarity/Structureは既存のシャープとは役割が違うため、シャープの代替にしない。Dehazeは色かぶりや黒つぶれを生みやすいので、適用順・強度・ヒストグラム警告をテスト画像で固定する。

優先度: **P0**。難度: **中**。Core Imageの既存フィルターまたはMetalカーネルで段階導入できる。

### 3. カラーグレーディングと色選択

Capture OneのColor Balanceは、Masterに加えてShadow、Mid-tone、Highlightを別々の色相・彩度・明度で調整する3-way構成である。[Capture One: Color Balance](https://support.captureone.com/hc/en-us/articles/360002594857-The-Color-Balance-tool-overview) Color EditorはBasic/Advanced/Skin Toneを持ち、Skin Toneでは色の均一化ができ、色選択からマスクを作って他の調整へ利用できる。[Capture One: local Color Editor](https://support.captureone.com/hc/en-us/articles/360007944857-Making-local-adjustments-with-the-Color-Editor) [Capture One: skin tones](https://support.captureone.com/hc/en-us/articles/360002596077)

Lightroom Classicは、カメラプロファイル、Mixer、Point Color、B&W、Calibrationを持つ。Point Colorは選択色の色相・彩度・輝度を対象にし、既存の8帯域HSLより狭い色域を狙える。[Lightroom Classic: tone and color](https://helpx.adobe.com/lightroom-classic/desktop/process-and-develop-photos/image-tone-color.html)

**ShootLogへの推奨**:

- `colorBalance`（master/shadows/midtones/highlightsの色相・彩度・明度）
- `blackAndWhite` と6色程度のB&Wミックス
- Point Color（ピッカー、色域幅、滑らかさ、H/S/L）
- Skin Toneの色相・彩度・明度の均一化

Point Colorは、既存HSLの置き換えではなく追加モードにする。既存の`HSLColorCube`を拡張し、選択色の中心・幅・フェザーを永続化する設計がよい。

優先度: Color Balance **P0**、B&W **P1**、Point Color/Skin Tone **P1**。難度: 中〜高。

### 4. RAWプロファイル、カメラ表現、プロセス互換性

Lightroom ClassicはAdobe Raw、Camera Matching、Adaptive、Creativeなどのプロファイルを選び、DCP/LCPプロファイルもインポートできる。カメラモデル別、シリアル番号別のRAWデフォルト、ISO適応プリセットも提供する。[Lightroom Classic: tone and color](https://helpx.adobe.com/lightroom-classic/desktop/process-and-develop-photos/image-tone-color.html) [Lightroom Classic: raw defaults](https://helpx.adobe.com/lightroom-classic/desktop/help/raw-defaults.html)

**ShootLogへの推奨**: RAWを一律に`CIRAWFilter`の既定デコードへ渡すのではなく、入力プロファイルを明示できる層を設ける。最低限、カメラモデルごとの「標準／ニュートラル／鮮やか」相当のプロファイル、ユーザーが選ぶカメラプロファイル、プロセスバージョン、ISO別初期値を追加する。DCP/LCPの完全互換は規模が大きいため、まずはプロファイル識別・適用経路・バージョン固定・旧画像の再現性を優先する。

優先度: **P0**（RAW色の一貫性）、難度: **高**。実機RAWサンプルをカメラ別に収集し、現行の「RAW実ファイル経路は検証継続中」という制限を先に解消する。

### 5. ディテール、ノイズ、レンズ、修復

Capture OneのDetails系は、シャープ、ノイズ低減、フィルムグレイン、モアレ、Spot Removalを含む。シャープはAmount、Radius、Threshold、Halo、ノイズ低減はLuminance、Details、Color、Single Pixelのように、現行ShootLogより分解されている。[Capture One: Details tools](https://support.captureone.com/hc/en-us/article_attachments/4406091520785) Lightroom Classicは、Denoise、Raw Details、Super ResolutionをEnhanceとして提供し、レンズ補正、色収差、Transform/Upright、Lens Blurも備える。[Lightroom Classic: Enhance](https://helpx.adobe.com/lightroom-classic/desktop/process-and-develop-photos/enhance-details.html) [Lightroom Classic: Develop tools](https://helpx.adobe.com/sg/lightroom-classic/help/develop-module-tools.html)

**ShootLogへの推奨**:

- シャープのRadius、Threshold、Masking、Halo
- ノイズ低減のDetail、色ノイズの滑らかさ、単一画素除去
- モアレ低減
- センサーゴミ・肌・小物向けの非破壊Heal/Clone
- 自動／手動のレンズプロファイル、色収差のフリンジ制御
- Transform/Keystone（建築・水平垂直補正）

修復はAI生成削除より先に、オフラインで再現可能なHeal/Cloneを実装する。Capture OneのHealは周辺の色・明るさとブレンドし、Cloneはサンプル画素をそのままコピーする。[Capture One: repair layers](https://support.captureone.com/hc/en-us/articles/360002625677-Repairing-Layers) LightroomのRemoveもClone/Healをオフラインで利用でき、生成削除のみインターネット依存である。[Lightroom Classic: Generative Remove](https://helpx.adobe.com/ca/lightroom-classic/desktop/process-and-develop-photos/remove-tool.html)

優先度: シャープ/NR拡張 **P1**、Heal/Clone **P1**、Transform **P1**、AI Denoise/生成削除 **P2**。難度: 中〜非常に高。

### 6. 自動化、比較、複数写真への一貫適用

Capture OneのMatch Lookは、参照画像のExposure/WB、Light & Contrast、Color Adjust、Color ToneをAIで別々に選択して適用し、複数参照の重み付けやImpactを扱える。[Capture One: Match Look](https://support.captureone.com/hc/en-us/articles/22188770298269-Match-Look-Tool) AIマスクやStylesは複数画像へ適用する際に画像ごと再計算される。[Capture One: AI Masking](https://support.captureone.com/hc/en-us/articles/14055231933853-AI-Masking)

**ShootLogへの推奨**: まずAIではなく、調整の選択的コピー、複数選択への同期、Before/After、調整前後の分割表示、仮想コピー、カメラ／レンズ／ISO条件別の初期プリセットを追加する。これらは既存のプリセットと`DevelopParameters`を活かせる。Match LookはP2の実験機能とし、生成値を通常のパラメータとして保存してユーザーが検査できるようにする。

優先度: **P1**。難度: 低〜中（Match Lookのみ高）。

### 7. HDR、合成、HDR表示

Capture OneとLightroom Classicは、複数露出からHDRを生成し、Lightroom ClassicはAuto Align、Auto Tone、複数段階のDeghostingを提供する。[Capture One: HDR Merge](https://support.captureone.com/hc/en-us/articles/4413050020113-HDR-Merging-Best-Practice) [Lightroom Classic: HDR merge](https://helpx.adobe.com/lightroom-classic/desktop/process-and-develop-photos/hdr-photo-merge.html)

Lightroom Classicはパノラマ、HDRパノラマ、投影方式、Boundary Warp、Fill Edges、Auto Cropも提供する。[Lightroom Classic: panorama and HDR panorama](https://helpx.adobe.com/lightroom-classic/desktop/process-and-develop-photos/panorama.html)

**ShootLogへの推奨**: まず単一RAWのHDR表示・ハイライト警告・SDRプレビューを整備し、その後にHDR mergeを別機能として検討する。HDR merge/パノラマは、合成結果をDNGまたは独自の派生PhotoとしてSwiftDataに登録し、元画像をスタックするデータモデルが必要になる。macOS 14対応ではHDR表示・AVIF/JPEG XL/TIFFの色管理検証が必要であり、優先度はP2。

### 8. 出力、色管理、検証

Capture OneのExport Recipesは、同一画像を複数の形式・サイズ・色空間へ一括処理し、ICCプロファイル、出力シャープ、メタデータ、リネーム、透かしを指定できる。レシピプルーフでは形式、縮小、品質、ICC、シャープ、透かしまで画面上で確認できる。[Capture One: Export Recipes](https://support.captureone.com/hc/en-us/articles/360021057158-Export-Recipes) [Capture One: Export overview](https://support.captureone.com/hc/en-us/articles/4403021653649-Export-overview) [Capture One: proofing profiles](https://support.captureone.com/hc/en-us/articles/360002645918-Proofing-profiles)

Lightroom ClassicもSoft Proofingで印刷プロファイルをプレビューし、出力時にプロファイル／色空間を選択する。[Lightroom Classic: color management](https://helpx.adobe.com/ie/lightroom-classic/help/color-management.html)

**ShootLogへの推奨**: 現行の単発JPEG/TIFF書き出しを、`DevelopExportRecipe`（形式、サイズ、ICC、品質、出力シャープ、メタデータ、透かし）へ拡張する。Display P3対応済みなので、次は任意ICCのソフトプルーフと「出力シャープを縮小後に適用する」順序を追加する。書き出し失敗時はレシピ単位で再試行できるジョブ化を検討する。

優先度: **P1**。難度: 中〜高。写真管理アプリとしての完成度に直結する。

## 推奨ロードマップ

### Phase A: 現像の信頼性と使い勝手（P0）

1. 現行RAWデコードの実機検証、カメラ別サンプル、プロセスバージョン／プロファイルの固定。
2. Clarity、Structure、Dehaze、周辺光量、B&Wミックス。
3. 3-way Color Balance。
4. レベル警告（ハイライト／シャドウのクリッピング、RGB別警告）とBefore/After。
5. `DevelopParameters`のschemaVersionを更新し、旧blobは中立値へ安全にフォールバック。

### Phase B: ShootLogの中核差別化になる局所現像（P0/P1）

1. `DevelopLayer` / `DevelopMask` のSwiftDataモデル。
2. ブラシ、線形、円形、輝度範囲、色範囲。
3. 加算・減算・交差・反転・フェザー・オーバーレイ表示。
4. レイヤー単位の既存調整適用、Opacity、複製、オン／オフ、コピー。
5. 選択的コピー、複数写真同期、仮想コピー。

### Phase C: 仕上げと出力品質（P1）

1. シャープのRadius/Threshold/Masking/Halo、NRのDetail/Smoothness。
2. Heal/Clone、モアレ、Transform/Keystone。
3. 任意ICCソフトプルーフ、出力レシピ、出力シャープ、透かし、メタデータ設定。
4. Point ColorとSkin Tone。

### Phase D: 高コスト機能（P2）

1. Vision/Core MLによるSubject/Sky/PeopleのローカルAIマスク。
2. AI DenoiseとRaw Details相当の高品質デモザイク／ノイズ除去。
3. Lens Blur、HDR表示、HDR merge、パノラマ。
4. Match Look、生成削除。生成系は外部送信・ネットワーク・プライバシー・再現性の扱いを先に決める。

## 実装上の注意

- すべての局所調整は既存のグローバル`DevelopParameters`を再利用できる値型として設計し、レイヤーは「パラメータ＋マスク＋opacity＋順序」を保持する。
- `CIRAWFilter`への露出/WB委譲と、レイヤー内の露出/WBを混在させる場合、RAW再デコードが必要なグローバル段と、ベース画像後のローカル段を明確に分離する。
- HSL/Point Color/Color Balanceは、現行のlinearSRGB作業空間とsRGB知覚ブラケットの規則を壊さない。色域外クリップとP3プレビューを別々に検証する。
- マスクは画像サイズに依存するため、サムネイル用・プレビュー用・書き出し用の座標変換と再サンプリングを一つの型へ閉じ込める。
- AIマスク、AI Denoise、生成削除は、モデルのバージョンと処理結果の保存方針を定義しない限り正式機能にしない。まず非AIの再現可能な処理を完成させる。
- 現行規約にある「元ファイルを上書きしない」「非破壊」「キャンセル可能な非同期処理」「アクセシビリティ」「ローカライズ」を新機能にも適用する。

## 主要な限界・未確定事項

- Capture One / Lightroomの内部アルゴリズム、RAWデモザイク品質、AIモデル精度は公式の機能説明だけでは再現できない。ここでの難度評価は機能境界とShootLogの既存コードからの推定である。
- 「くまなく」は両製品の全モジュールではなく、現像パネルおよび現像に隣接する選別・出力機能を対象とした。カタログ、クラウド、テザー、印刷管理は今回のスコープ外である。
- 各製品は更新が速く、資料の更新日・対象エディションが混在する。実装着手時には対象バージョンを固定し、公式リリースノートを再確認する。

## Claim-to-source ledger

| 主張 | 根拠 | 確度 |
|---|---|---|
| C1: Capture Oneはレイヤー、複数マスク、AIマスク、マスク合成を提供 | Overview of Layers and Masks; AI Masking | 高 |
| C2: Lightroom Classicは被写体・空・背景・人物・物体・輝度・色・深度マスクを提供 | Masking tool; local adjustments by range | 高 |
| C3: Capture OneはClarity/Structure/Dehaze/3-way Color Balanceを提供 | Clarity; Dehaze; Color Balance | 高 |
| C4: Lightroom Classicはプロファイル、Point Color、Calibration、Enhanceを提供 | tone and color; Enhance details | 高 |
| C5: 両製品はHDR合成／パノラマまたはHDRパノラマを提供 | Capture One HDR; Lightroom HDR merge; Lightroom panorama | 高 |
| C6: 両製品は出力プロファイル／ソフトプルーフ／出力シャープに対応 | Capture One export/proofing; Lightroom color management | 高 |
| C7: Heal/Cloneは生成AIなしでも成立し、生成削除はネットワーク依存になり得る | Capture One repair; Lightroom Generative Remove | 高 |
| C8: 推奨優先度・難度・アーキテクチャ | 現行リポジトリ実装と上記機能差分からの推定 | 中 |

## 調査停止理由

両製品の現像機能の共通核、製品固有の差分、ShootLogの主要な欠落領域、優先度判断に必要な一次資料を確認した。追加の検索は、同じ機能を別ページで反復する割合が高く、今回のロードマップ判断を変える可能性が低いため停止した。実装着手時は、選択したPhaseに対応するAPI／Core Image／Vision／Core MLの一次資料を別途調査する。
