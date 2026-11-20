# DDDトリレンマをHaskellで扱う

「この作品を読めるか」を題材に、ドメインが業務判断を引き受けながら、必要になった情報だけをSQLiteから読むサンプルです。C#版の閲覧・公開範囲変更の仕様を使い、Haskellで要求と回答を型で結びました。[比較対象のC#版（参照コミット）](https://github.com/Mori-Taiki/DddTrilemmaCsharp/tree/d314ea77709142994d6d06d08c5d0ab083d4dbe1)

## 動かす

GHC 9.6.6、cabal-install 3.10.3.0で検証しています。リポジトリ直下で実行します。

```sh
cabal update
cabal test --test-show-details=direct
cabal run story-api
```

別の端末から次の順に試せます。初回起動時に4作品を投入します。変更は作業ディレクトリの `app.db` に残ります。別ファイルで試す場合は `cabal run story-api -- trial.db` で起動してください。

```sh
curl -s http://localhost:5080/stories
curl -s 'http://localhost:5080/stories/followers-paid/view?viewer=vip'
curl -i -X PUT http://localhost:5080/stories/public-free/visibility \
  -H 'Content-Type: application/json' \
  -d '{"actor":"author","visibility":"フォロワー限定"}'
curl -i 'http://localhost:5080/stories/public-free/view?viewer=guest'
```

2番目の応答では会員確認で止まり、購入履歴への問い合わせを省きます。最後の応答は変更後の公開範囲を反映し、403と「フォローが必要」を返します。

```json
{"allowed":true,"reason":null,"trace":["フォロー確認が必要","会員確認が必要","許可"],"factQueries":2}
```

## なぜ判断の途中を値で表すのか

作品の作者はいつでも読めます。その他の閲覧者には、フォロワー限定ならフォロー、有料ならVIP資格か該当作品の購入が必要です。このルールで初めて、次に必要な事実が決まります。先にすべてを読むと無駄な取得が生じ、HTTPハンドラで取得要否を決めるとルールが分散し、ドメイン自身がDBを読むと判断が外部状態に依存します。これがこの例での性能・完全性・純粋性のトリレンマです。[トリレンマの原典](https://enterprisecraftsmanship.com/posts/domain-model-purity-completeness/) · [C#版が着想を得たGoのDecisionパターン](https://zenn.dev/tellernovel_inc/articles/0193eb68cabb6e)

`decide :: Story -> UserId -> Decision` は、確定した閲覧結果か「この事実を取得したら、ここから判断を続ける」という値を返します。たとえば次の2つの型を組み合わせると、会員確認を再開する関数の引数は必ず `Membership` になります。

```haskell
Member :: UserId -> Fact Membership
Need   :: Fact a -> (a -> Decision) -> Decision
```

C#版では各要求が `結果(bool)` を持ちます。Haskell版ではGADT（一般化代数的データ型）の型引数で、要求ごとに回答の型を指定します。たとえば会員確認に `Owned` を返すSQL解釈器はコンパイルできません。継続は必要な作品や閲覧者を関数の中に保持します。取得側は「VIPなら許可」のようなルールを知る必要がありません。[要求・継続・解釈器](src/Story/Decision.hs)

`interpret` は `forall a. Fact a -> m a` を受け取ります。SQLiteなら `m` は `IO`、メモリ上の仕様検証なら `Identity`、取得失敗を表現するテストなら `Either` を使えます。共通の解釈ループが実際に通った要求を記録します。

| 限定・有料作品の閲覧者 | 追加で読む事実 | 結果 |
|---|---|---|
| 作者 | なし | 許可 |
| 非フォロワー | フォロー | 拒否（フォローが必要） |
| フォロー済みVIP | フォロー → 会員 | 許可 |
| フォロー済み一般会員 | フォロー → 会員 → 購入 | 購入済みなら許可、未購入なら拒否 |

## 変更の保存と読み取りの一貫性

C#版は不変モデルとEF Coreが変更追跡する可変モデルを比較しています。Haskell版では `changeVisibility :: UserId -> Visibility -> Story -> Either ChangeError Story` に一本化しました。作者確認を先に行い、同じ公開範囲への変更も拒否します。呼び出し側が結果をパターンマッチし、成功時だけ新しい値の公開範囲をSQLに渡します。可変オブジェクトの追跡を再現するためのモデルは設けていません。[状態遷移](src/Story/Domain.hs) · [保存処理](src/Story/Store.hs)

値の不変性だけでは、2リクエストが同じ旧状態を読んで両方成功する競合が残ります。変更では `BEGIN IMMEDIATE` を使い、作品を取得する前に書き込み権を確保します。同じ変更が重なれば、後続の要求は更新後の値を読み、409になります。ロックの取得には5秒の待機上限があります。閲覧では同じ接続の読み取りトランザクションで作品とすべての事実を読み、ひとつのスナップショットで判断します。SQL障害は外側の例外経路に伝わります。[SQLiteの分離性](https://www.sqlite.org/isolation.html)

## 保証の範囲

| 問い | 確かめる手段と限界 |
|---|---|
| 種類の違うIDや回答を取り違えたか | `newtype` とGADTが型の不一致を検出する。閲覧者と作者はどちらも `UserId` なので、SQL引数を逆順にした誤りは実DBで調べる。 |
| 新しい業務ケースを扱い忘れたか | ADTの列挙と `-Werror=incomplete-patterns` で未処理のパターンをビルドエラーにする。ワイルドカードで受けると将来の追加を見落とせるため、業務ケースは明示する。 |
| 判断は仕様どおりか | 作者・公開範囲・料金・フォロー・会員・購入の全64通りを独立した閲覧条件と照合する。型が合っても、VIPと一般会員を逆に解釈したり、誤った行を読んだりする可能性は残る。 |
| 不要なSQLを省いたか | `factQueries` は解釈した要求の数。現在の実装では1要求に1本のSELECTを対応させ、SQLiteのトレースで作品取得1本を加えた実数と照合する。 |
| 一覧全体でも効率的か | 短絡の利点は単件判定についてのもの。作品ごとに判定すると照会を繰り返す。多数の作品ではフォロー・会員情報の共有、一括取得、SQLでの集合演算との比較が必要になる。 |
| 途中の判定をプロセスを越えて再開できるか | `a -> Decision` は実行中の関数。キューへの保存・監査後の再実行が必要なら、再開地点と入力を直列化できるデータ型にする設計が必要になる。 |

## HTTPの境界

`GET /stories` は作品をID順に返します。`GET /stories/{id}/view?viewer=...` は許可なら200、業務上の拒否なら403です。`PUT /stories/{id}/visibility` は成功なら200、作者以外は403、同じ公開範囲なら409です。作品が見つからなければ404、不正なIDや変更内容なら400です。公開範囲の入力は「全体公開」「フォロワー限定」を受け付けます。`viewer` と `actor` はデモ用にリクエストから受け取ります。実サービスでは認証済みの利用者IDを渡す必要があります。このサンプルは独自のSQLiteスキーマを使います。[HTTP実装](src/Story/Http.hs) · [実行可能な仕様](test/Spec.hs)
