# 同梱バイナリ

このアプリに同梱する外部バイナリの記録。**バージョンを上げるときは、FL-R2GUI-DD-001 §14.1 の検証を再実施すること。**

## rclone

| 項目 | 値 |
|---|---|
| バージョン | **v1.75.0** |
| プラットフォーム | darwin-arm64 |
| SHA-256（展開後バイナリ） | `f52ccc22e6fe61ea5791f0e186db323155ad1cc1b6dfe547f4bc665bea57a2dd` |
| 取得元 | https://downloads.rclone.org/rclone-current-osx-arm64.zip |
| go/version | go1.26.5 |
| go/linking | **dynamic**（静的リンクではない。U-03 は解決済み → **library validation の無効化は不要**） |
| go/tags | cmount |
| ライセンス | **MIT**。`SkyFolder/Resources/rclone-LICENSE.txt` として `.app` に同梱する（下記） |
| 検証日 | 2026-08-30 |
| 検証環境 | macOS 26.6.2 (25G83) / arm64 |

### ライセンス（再配布の要件）

rclone は **MIT ライセンス**。バイナリを `.app` に入れて再配布する以上、
**著作権表示と許諾文を同梱する義務がある**（「copies or substantial portions」に含めること）。

**公式の配布 zip に LICENSE ファイルは入っていない。** 中身は
`git-log.txt` / `rclone` / `rclone.1` / `README.html` / `README.txt` の 5 点で、
ライセンス本文は **README.txt の「License」節**にある。

`fetch-rclone.sh` がそこから抽出して `SkyFolder/Resources/rclone-LICENSE.txt` に置き、
`project.yml` が `.app` のリソースとして同梱する。
**別途 GitHub から取らない** — 同梱するバイナリのバージョンとずれうるため。

抽出の注意（実測）:

- 終端は `OTHER DEALINGS IN` で折り返され、**次の行が `    THE SOFTWARE.`** になる。
  1 行に `DEALINGS IN THE SOFTWARE` は現れないので、その語で範囲を閉じようとすると
  **awk がファイル末尾まで出し続ける**（実際に 23 行のはずが 52KB 出た）
- したがって抽出後に本文の検査だけでなく **行数の上限（40 行）** も見る。
  取りすぎはエラーにならないので、内容の検査だけでは通ってしまう
- 正しく抽出できたときは **23 行 / 1345 バイト**

### このバージョンで確認済みの挙動

設計が依存している事実。**バージョンを上げたら再確認する。**

| 項目 | 実測値 |
|---|---|
| `mount/types` の応答 | `["cmount", "nfsmount"]` — **`mount`(FUSE) は含まれない** |
| rcd の待受ポートの出力先 | ~~**stderr**~~ → **`--log-file` を付けると stdout も stderr も空になり、ログファイルに出る**。下の「実装時に追加で確認した挙動」を参照（M-12） |
| `vfsOpt` の Duration / SizeSuffix | ナノ秒 / バイトの**整数**で受理 |
| `vfsOpt.ReadOnly` | **マウント単位**で有効（同一 rcd 内で ro/rw を混在できる） |
| read-only マウントの OS 属性 | `mount` 出力に `read-only` フラグは**付かない**（VFS 層で拒否） |
| read-only 時のエラー | 書込み `permission denied` / 削除 `Input/output error`（**クライアント側の errno。ログには出ない**。上書きは `EBADRPC` で 3 種類ある → M-17） |
| `mount/mount` の応答時間 | 0.030〜0.036 秒（同期呼び出しで可） |
| `_filter.ExcludeRule` | 長命な VFS に**持続適用される** |
| `nfs.HandleLimit` の既定値 | **1000000**（DD-001 §6.3 の指定値と一致 → 明示不要） |
| `_config.UploadHeaders` の形式 | `[{"Key":"...","Value":"..."}]` の配列で**受理される**。ただし `type=local` にはヘッダ概念がなく、**実際に付与されるかは未確認**（U-04・G1-9 ⑤ で確認） |
| 認証なしの rc アクセス | HTTP **401** |
| 起動ログ | `Using --user {rc-user} --pass XXXX` — **ユーザー名は平文**、パスワードはマスク |

### 実装時（2026-08-31）に追加で確認した挙動

設計書 v1.3 を実装した過程で判明した事実（本文への反映は設計書 v1.4）。詳細は `IMPLEMENTATION-NOTES.md` を参照。

| 項目 | 実測値 |
|---|---|
| **`--log-file` 指定時のポート出力先** | **ログファイル**。stdout も stderr も **0 バイト**。§6.1 が `--log-file` を必須としているため、**stderr を読む実装も永久に待つ**（M-12） |
| `operations/uploadfile` の形式 | multipart/form-data。**`_async` を form field で渡しても jobid を返さず同期実行**（応答は `{}`）。進捗ポーリングができない（M-13） |
| `operations/copyfile` + `_async` | `{"executeId": "...", "jobid": N}` を返す。`job/status` で完了を待てる。`_config.UploadHeaders` も受理 → **アップロードはこちらを使う** |
| `operations/deletefile`（存在しないキー） | **HTTP 404 / `object not found`**（G1-9 ⑧ を local で先取り） |
| `operations/stat`（存在しないキー） | `{"item": null}`。エラーではない |
| **`operations/movefile`（移動先が存在）** | **エラーにならず黙って上書きする**（M-14）。§8.6.3 の想定と逆で、二度押しすると先の退避を失う |
| read-only 拒否時の errno | 新規作成 `EACCES`(13) / **既存上書き `EBADRPC`(72)** / 削除・リネーム `EIO`(5) / mkdir `EACCES`(13)（M-17） |
| read-only 拒否時の**ログ** | INFO で出るのは `ERROR : nfs: Error Creating: Read only file system` のみ。**削除・リネームは 1 行も出ない**。errno の文言はログに現れない（M-17） |
| マウントパスの表現 | `mount/mount` と `listmounts` は**渡した表現のまま**返す。OS のマウント表は **symlink 解決済み**を返す（M-18） |
| Hardened Runtime 下の子プロセス実行 | **`com.apple.security.cs.disable-library-validation` は不要**。ad-hoc + `flags=0x10002(adhoc,runtime)` で成功（U-03 解決・Developer ID では未確認） |
| 署名後のバイナリの SHA-256 | `dcb481860f6597451e9a535023287ef8c0ba049368034784521401ace6fb3c76`。**個別署名すると必ず変わる**ため、BUNDLED.md と照合できるのは配布物のハッシュのほう（T-G30 の是正） |

### 冪等性（v1.2 実測）

| 操作 | 冪等 | 実測 |
|---|---|---|
| `mount/mount`（同一 mountPoint 2回） | **状態✅ / 応答❌** | `failed to mount FUSE fs: ... already mounted ...: exit status 78`。ただし `listmounts` は 1 件のまま |
| `mount/unmount`（2回目・存在しないパス） | **❌** | `"mount not found"` / HTTP 500 |
| `mount/unmountall`（2回） | **✅** | 両方 `{}` |
| `options/set`（同値2回） | **✅** | 両方 `{}` |
| rcd 二重起動（ポート固定） | ⚠️ | 2本目が `bind: address already in use` |
| **rcd 二重起動（`:0`＝本アプリの既定）** | **❌** | **別ポートで両方起動**（61987 と 62097 が同時稼働）。**rclone は重複を防がない → アプリの責任** |

> `mount/mount` のエラーは **nfsmount でも「FUSE」と表示される**。macFUSE の問題と誤診断しないこと。判定は末尾の `exit status 78` で行う。

### 孤児 rcd の回収（CRIT-03 の対策・通しで実証済み）

| 手順 | 実測結果 |
|---|---|
| 旧 rcd がマウント保持 → 新 rcd を起動 | **破綻を再現**: 新 rcd の `listmounts` は **0 件**、OS 上には **1 件**存在 |
| `ps -p {pid} -o comm=` で実行パス照合 | 同梱バイナリと一致 → 自分が起動したものと断定できる（PID 使い回し対策） |
| `SIGTERM` を送出 | **1 秒で終了**。**OS 上のマウントも 0 件になった**（自動解除） |
| 回収後 | **rcd 0 本 / マウント 0 件** |

> **`SIGTERM` だけで完結する**ため、孤児に RC API を呼ぶ必要がない。
> これは重要で、孤児の rc-user/rc-pass は失われており **RC API は 401 になる**（認証情報を永続化しない SEC-G01 のため）。

### S3（R2）バックエンドで確認済み

| 項目 | 実測 |
|---|---|
| s3 の設定キー名 | `provider` / `access_key_id` / `secret_access_key` / `endpoint` / `acl` / `no_check_bucket` / `chunk_size` / `upload_cutoff` が**すべて実在** |
| `provider` の選択肢 | **`Cloudflare` が有効値として存在** |
| 環境変数での S3 リモート定義 | **成立**。ダミー値で `operations/list` を呼ぶと `operation error S3: ListObjectsV2 ... Get "https://{指定した endpoint}/testbucket?list-type=2"` となり、**S3 として解決され指定 endpoint に HTTPS を送るところまで到達**する |
| `config/dump` の応答 | 環境変数由来のリモートは**現れない**（空）。異常ではない。**Access Key も Secret も出ないため診断表示に使っても安全** |
| エラー本文 | **endpoint（= accountId）が含まれる**。診断ログ共有時にマスクすること |

| `operations/publiclink` の引数 | `fs` / `remote` / `unlink` / `expire`。**`expire` は文字列**（`"1d"` 形式）。`vfsOpt` の Duration が数値なのとは扱いが違う |

> `type=local` は public link 非対応（`doesn't support public links`）のため、**この API は一度も成功させていない**（U-13）。

### `operations/publiclink` の落とし穴（ソース `backend/s3/s3.go` で確認）

| 事実 | 根拠 |
|---|---|
| **`unlink` 引数は S3 で完全に無視される** | `func (f *Fs) PublicLink(ctx, remote string, expire fs.Duration, unlink bool)` の**本体での出現回数が 0**。エラーも返らないため「失効させられた」と誤認する導線になる |
| **期限の上限超過はエラーではなく黙って丸められる** | `maxExpireDuration = fs.Duration(7 * 24 * time.Hour)`。超過時は `fs.Logf` でログに出したうえで `expire = maxExpireDuration`。**呼び出し側にエラーは返らない** → アプリ側のバリデーションが必須 |
| **ディレクトリは共有できない** | 末尾 `/` の remote に `fs.ErrorCantShareDirectories` |
| presigned の生成方法 | `s3.NewPresignClient(f.c).PresignGetObject(...)` — 署名はローカル計算で完結し、**サーバ側に状態を持たない**（＝原理的に取り消せない） |

### 未確認

- ~~**U-03**: Hardened Runtime 下での子プロセス実行に `disable-library-validation` が必要か~~
  → **解決（2026-08-31）**: 不要。ad-hoc + Hardened Runtime で成功。entitlement は削除済み。
  ただし **Developer ID 署名での再確認は残る**（証明書が無いため未実測）
- **実 R2 アカウントでの疎通（G1-9）**: 以下はすべて一度も成功させていない
  → 検証手段は実装済み: `./scripts/verify-r2.sh`（認証情報を環境変数で渡す）
  - SigV4 署名の成立・実バケットへの読み書き・マルチパート（128MB 超）・`no_check_bucket` の効果・バケットスコープトークンの権限境界
  - **U-13**: `operations/publiclink` による presigned URL の実発行
  - **U-04**: `Cache-Control` が実際にオブジェクトへ付与されるか
  - **M-03 の裏取り**: `vfs/stats` の `uploadsQueued` が実際に増減するか（local ではキューが発生しない）
