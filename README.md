# DDDトリレンマをHaskellで扱う

このリポジトリでは「誰がこの作品を読めるか」という身近なルールから、業務判断とDBアクセスをどう分けるかを考えます。

たとえば、有料作品でもVIP会員なら購入履歴を調べずに済みます。一般会員なら、その作品を購入したかどうかで答えが変わります。つまり「次に何を調べるか」も閲覧ルールの一部です。では、そのルールをドメインにまとめたまま、DBへの問い合わせだけを外に任せるには、どう書けばよいでしょうか。

## 次に読むデータは、直前の答えで決まる

作者は自分の作品をいつでも読めます。作者以外がフォロワー限定の有料作品を読むには、まず作者をフォローしている必要があります。そのうえで、VIP会員なら閲覧を許可し、一般会員ならその作品を購入したかを確かめます。

| 初期データの閲覧者 | 作品を取得した後に調べる事実 | 判定 |
|---|---|---|
| `author`（作者本人） | なし | 許可 |
| `guest`（非フォロワー） | フォロー | 拒否（フォローが必要） |
| `vip`（フォロー済みVIP） | フォロー → 会員 | 許可 |
| `buyer`（フォロー済み一般会員） | フォロー → 会員 → 購入 | 許可 |
| `follower`（フォロー済み一般会員） | フォロー → 会員 → 購入 | 拒否（購入が必要） |

最初にすべての事実を読むと、VIPにも購入履歴を問い合わせることになります。HTTPハンドラに「VIPなら購入を調べない」と書けば、閲覧ルールがハンドラとドメインに分かれます。ドメイン自身が必要なときにDBを読めばルールはまとまりますが、判定が外部状態に依存します。この例で両立が難しいのは、取得の効率、業務ルールをドメイン内で表しきる完全性、判断の純粋性の三つです。[DDDトリレンマの原典](https://enterprisecraftsmanship.com/posts/domain-model-purity-completeness/)・[着想元のDecisionパターン](https://zenn.dev/tellernovel_inc/articles/0193eb68cabb6e)・[同じ仕様を扱うC#版（参照コミット）](https://github.com/Mori-Taiki/DddTrilemmaCsharp/tree/d314ea77709142994d6d06d08c5d0ab083d4dbe1)

## 要求と、その答えを待つ継続

ドメインが途中まで判断して、必要な事実と「答えを受け取った後の処理」を一緒に返せば、DBを読む側に閲覧ルールを書く必要はありません。[Story.Decision](src/Story/Decision.hs) では、この後の処理を関数として渡します。この関数が継続です。まず閲覧判定のコードで継続の働きを追い、そこからFree Monadとの関係を見ていきます。

`decide :: Story -> UserId -> Decision` は、すでに分かっていることだけで判定を進めます。作者本人なら `Done Allow` で完了です。外部の事実が必要になったら `Need` を返します。

```haskell
data Fact a where
  Follows :: UserId -> UserId -> Fact Follow
  Member :: UserId -> Fact Membership
  Purchased :: UserId -> StoryId -> Fact Purchase

data Decision where
  Done :: Verdict -> Decision
  Need :: Fact a -> (a -> Decision) -> Decision
```

`Fact a` の `a` は、その要求に対する**回答の型**です。`Member viewer` は「この人の会員資格を知りたい」という要求で、型は `Fact Membership` です。`Need` にこの要求を渡すと、第2引数の型も `Membership -> Decision` に決まります。要求の種類によって回答の型が決まる関係を、HaskellのGADT（一般化代数的データ型）で表しています。

有料作品の会員確認では、この第2引数に `afterMembership` を渡します（`decide` 内の抜粋）。

```haskell
    checkPrice = case price story of
      Free -> Done Allow
      Paid -> Need (Member viewer) afterMembership

    afterMembership Vip = Done Allow
    afterMembership Standard = Need (Purchased viewer (identifier story)) afterPurchase

    afterPurchase Owned = Done Allow
    afterPurchase NotOwned = Done (Deny PurchaseRequired)
```

`Need (Member viewer) afterMembership` を返した時点では、会員資格はまだ分かりません。サービスが `Vip` と答えれば、`afterMembership Vip` はその場で `Done Allow` を返します。`Standard` と答えたときだけ、新しい要求 `Purchased viewer (identifier story)` が現れます。次の購入確認でどの閲覧者と作品を使うかは、関数を定義した場所の `viewer` と `story` から決まります。会員資格を取得する側に、この分岐や作品IDの引き継ぎを書く必要はありません。

## 解釈器は、要求に答えて続きを呼ぶ

```haskell
interpret :: Monad m => (forall a. Fact a -> m a) -> Decision -> m Report
interpret fetch = go []
  where
    go seen (Done result) = pure (Report result (reverse seen))
    go seen (Need fact resume) = do
      answer <- fetch fact
      go (kind fact : seen) (resume answer)
```

`Need` の場合には、`fetch fact` が事実を取得し、`resume answer` が次の判定を返します。`Done` に着くと、最終結果と、実際に通った要求の種類を順番に並べて返します。解釈器には「VIPなら許可」という分岐が一つもありません。その判断はドメインから渡された `resume` の中にあります。

`forall a. Fact a -> m a` は、どの回答型の要求が来ても、それに合う型で回答できる関数を求めています。たとえばSQLiteの実装で `Member` に `Owned` を返そうとすれば型エラーです。`m` を選ぶと、同じ判定を異なる条件で実行できます。

| 事実をどう取得するか | `m` | 実際に確かめられること |
|---|---|---|
| SQLiteに問い合わせる | `IO` | [Store](src/Story/Store.hs) の `fetch db` が、要求に対応するSELECTを1回実行する |
| テストデータから答える | `Identity` | [DomainSpec](test/DomainSpec.hs) の `answer facts` が、DBを使わずに閲覧ルールを検証できるようにする |
| 取得失敗を返す | `Either String` | 同じDomainSpecで取得が `Left "offline"` になると、継続を呼ばずにそのエラーを返す。業務上の拒否は `Verdict` の `Deny` として区別できる |

## この設計はFree Monadとどうつながるか

ここまでの `Decision` は閲覧判定専用です。要求は `Fact`、最終結果は `Verdict` に決まっています。ここで「ある事実を読む処理」を単独で書いて、後から別の処理につなぎたくなったらどうでしょうか。会員資格を読む処理なら、その時点での結果は `Membership` です。次にその結果を使って、最終的に `Verdict` を返す処理をつなげたいわけです。

以下はこの関係を説明するための一般化で、リポジトリの実装は上の `Decision` を使っています。

```haskell
data Program op r where
  Return  :: r -> Program op r
  Request :: op a -> (a -> Program op r) -> Program op r

ask :: op a -> Program op a
ask op = Request op Return

andThen :: Program op r -> (r -> Program op s) -> Program op s
andThen (Return x)    k = k x
andThen (Request q c) k = Request q (\a -> andThen (c a) k)
```

`a` は**今の要求の回答**、`r` は**プログラム全体の結果**です。`Program Fact Verdict` と置けば、`Return` と `Request` はそれぞれ実装の `Done` と `Need` に対応します。一方、`ask (Member viewer)` だけなら型は `Program Fact Membership` です。ここで会員資格を取得する方法はまだ選んでいません。

`andThen` はモナドの `(>>=)` に当たる操作です。最初の処理が `Return x` なら、後続の関数 `k` に結果 `x` を渡せます。`Request q c` なら、今すぐ分かるのは要求 `q` までです。そこで `q` を残し、回答 `a` が届いたら元の続き `c a` を進め、その結果をさらに `k` につなぐ関数を渡します。この合成にもDBは登場しません。

この定義を使うと、先ほどの有料作品の分岐は次のように読めます。

```haskell
paidProgram :: UserId -> StoryId -> Program Fact Verdict
paidProgram viewer key =
  andThen (ask (Member viewer)) $ \membership ->
    case membership of
      Vip      -> Return Allow
      Standard -> andThen (ask (Purchased viewer key)) $ \purchase ->
        case purchase of
          Owned    -> Return Allow
          NotOwned -> Return (Deny PurchaseRequired)
```

ここでFree Monadから得たいのは、**命令をどう実行するかを決める前に、命令とその続きからプログラムを組み立てられること**です。教科書的な定義 `data Free f r = Pure r | Free (f (Free f r))` では、1段分の命令を表す関手 `f` の中に後続の計算を置き、`fmap` でその先に処理をつなぎます。上の `Program` は、命令 `op a` と継続 `a -> Program op r` を別々に持つ **Freer Monad** の表現です。この形なら命令型 `Fact` に `Functor` インスタンスを用意せずに合成できます。[Freer Monads, More Extensible Effects](https://okmij.org/ftp/Haskell/extensible/more.pdf)・[The Operational Monad Tutorial](https://apfelmus.nfshost.com/articles/operational-monad.html)

実装の `Decision` には結果型の引数も `Monad` インスタンスもありません。閲覧ルールの中で `afterMembership` や `afterPurchase` を直接渡せば必要な分岐を書けるからです。`interpret` の `Monad m` は別の役割を持ちます。こちらは、選んだ実行先で「回答を取得し、その回答を使って次に進む」という順序を表すための制約です。

## 型・テスト・トランザクションが担うこと

| 確かめたいこと | この実装での扱い |
|---|---|
| IDや回答の種類は合っているか | IDには `newtype`、要求と回答にはGADTを使う。列挙した業務ケースの処理漏れは `-Werror=incomplete-patterns` でビルドエラーにする。ワイルドカードで残りを受ける箇所は、この検査で追加漏れに気づけない |
| 閲覧の可否と拒否理由は正しいか | [DomainSpec](test/DomainSpec.hs) が作者かどうか、公開範囲、料金、フォロー、会員資格、購入の全64通りを業務ルールと照合する |
| 正しい人・作品の事実だけを読んだか | 作者と閲覧者はともに `UserId`。引数を逆にしたクエリでも型は合う。[StoreSpec](test/StoreSpec.hs) が別の作者や作品のデータを使って確かめる |
| 余分なSQLを発行していないか | `factQueries` は解釈した要求数。StoreSpecではSQLiteのトレースを取り、実際のSELECT数が「作品取得1回＋事実要求数」と一致するかも確かめる |

継続はプロセス内の関数です。キューに判定を保存して別プロセスで再開するには、再開地点と入力を直列化できるデータとして表す必要があります。また、問い合わせを途中で打ち切れるのは単件判定での利点です。作品一覧に適用する場合は、共通の事実を一度に読む方法や、SQLでまとめて判定する方法と往復回数を比較する必要があります。

閲覧では、作品と追加の事実を同じSQLite接続の読み取りトランザクションで取得します。判定中の各問い合わせが同じ時点のデータを参照できるのは、このトランザクションによるものです。SQL障害は例外として呼び出し側に伝わります。[Store](src/Story/Store.hs)・[SQLiteの分離性](https://www.sqlite.org/isolation.html)

公開範囲の変更は `changeVisibility :: UserId -> Visibility -> Story -> Either ChangeError Story` で表します。ドメインは最初に作者を確認し、同じ公開範囲への変更も拒否します。成功時だけ、新しいストーリーの公開範囲をDBに保存します。値が不変でも、二つの要求が同じ旧状態を読む競合は起こりえます。そこで変更時は `BEGIN IMMEDIATE` で書き込み権を得てから作品を読みます。ロック待ちの上限は5秒です。同じ変更が続けて処理されると、後の要求は変更済みの値を読んで409になります。[状態遷移](src/Story/Domain.hs)・[保存処理](src/Story/Store.hs)

## 動かす

### GitHub Codespaces

[GitHub Codespacesで開く](https://codespaces.new/Mori-Taiki/DddTrilemmaHaskell?ref=main) からCodespaceを作成します。初回はGHCとCabalの準備、依存関係の取得、APIとテストのビルドが自動で行われます。準備が終わったらターミナルで実行します。

```sh
cabal test --test-show-details=direct
cabal run story-api
```

ブラウザで作品一覧を見るには、**ポート（Ports）** タブから **5080（Story API）** を開き、URLの末尾に `/stories` を付けます。下のcurl例はCodespace内の別のターミナルで実行できます。既存のCodespaceに設定を適用する場合は、最新の `main` を取得してコマンドパレットから **Codespaces: Rebuild Container** を実行してください。

### ローカル環境

GHC 9.6.6、cabal-install 3.10.3.0で検証しています。リポジトリ直下で実行します。

```sh
cabal update
cabal test --test-show-details=direct
cabal run story-api
```

### APIを試す

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

### テストを変更する

閲覧ルールと拒否理由は [DomainSpec](test/DomainSpec.hs)、実際に発行するSQLと保存データの扱いは [StoreSpec](test/StoreSpec.hs)、ステータスコードとJSONの契約は [HttpSpec](test/HttpSpec.hs) にあります。特定のルールだけを確認するときは、Hspecのテスト名で絞り込めます。

```sh
cabal test --test-show-details=direct --test-options='--match フォロワー限定の有料作品'
```

## HTTPの境界

`GET /stories` は作品をID順に返します。`GET /stories/{id}/view?viewer=...` は許可なら200、業務上の拒否なら403です。`PUT /stories/{id}/visibility` は成功なら200、作者以外は403、同じ公開範囲なら409です。作品が見つからなければ404、不正なIDや変更内容なら400です。公開範囲の入力は「全体公開」「フォロワー限定」を受け付けます。`viewer` と `actor` はデモ用にリクエストから受け取ります。実サービスでは認証済みの利用者IDを渡す必要があります。このサンプルは独自のSQLiteスキーマを使います。[HTTP実装](src/Story/Http.hs) · [HTTPの仕様テスト](test/HttpSpec.hs)
