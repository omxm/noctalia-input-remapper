# Input Remapper for Noctalia v5

バーのウィジェットから input-remapper のプリセットを直接切り替えるプラグイン。
パスワード入力なし、ウィンドウの行き来なし、右クリック一発で全停止。

対象: Noctalia v5.0.0 以降 (`plugin_api = 15`) / input-remapper 2.x

---

## 導入は2段階

**先に runit サービスを入れること。** ここを飛ばすとパネルを作ってもパスワードを聞かれる。

### 1. デーモンを root 常駐させる (Artix / runit)

パスワードを求められる原因は、`input-remapper-service` が常駐しておらず、
GUI が毎回 pkexec で root 起動しているから。runit のシステムサービスとして
ブート時から立ち上げておけば、この経路ごと消える。

```sh
# 実行ファイルの場所を先に確認（Arch/Artix では /usr/sbin は /usr/bin への symlink）
command -v input-remapper-service

sudo mkdir -p /etc/runit/sv/input-remapper/log
sudo cp runit/input-remapper/run     /etc/runit/sv/input-remapper/run
sudo cp runit/input-remapper/log/run /etc/runit/sv/input-remapper/log/run
sudo chmod +x /etc/runit/sv/input-remapper/run /etc/runit/sv/input-remapper/log/run
sudo mkdir -p /var/log/input-remapper

# 有効化
sudo ln -s /etc/runit/sv/input-remapper /run/runit/service/

# 確認
sudo sv status input-remapper
input-remapper-control --command hello     # -> Daemon answered with "hello"
```

`run` は `sv check dbus` でシステムバスの起動を待ってから exec する。
input-remapper は `inputremapper.Control` をシステムバス上に publish するので、
dbus より先に起動すると失敗するため。

うまくいかないときは `sudo tail -f /var/log/input-remapper/current` を見る。

> **GUI について**: マッピングを新規記録するときだけは `input-remapper-reader-service`
> が別途 root 権限を要求するので、GUI でキーを録音する場面ではまだ認証が出る。
> プリセットの適用・停止（このプラグインがやること）には一切出ない。

### 2. プラグインを置く

```sh
mkdir -p ~/.local/share/noctalia/plugins
rm -rf ~/.local/share/noctalia/plugins/input-remapper
cp -r input-remapper ~/.local/share/noctalia/plugins/
```

`rm -rf` を先に打つのは、コピー先に同名ディレクトリがあると `cp -r` が中身を
上書きせず入れ子を作ってしまうため。

Noctalia の Settings → Plugins で **Input Remapper** を有効化し、
Bar の設定でウィジェット `haru/input-remapper:indicator` を好きな位置に追加する。

`.luau` を編集すると自動でホットリロードされるが、`plugin.toml` は次のコンフィグ
リロードまで反映されない。**バージョンを入れ替えたときは Noctalia を完全に再起動
すること。** ホットリロードだけだとスクリプトと マニフェストの世代が食い違った
状態で動くことがある。

---

## 使い方

| 操作 | 動作 |
|---|---|
| ウィジェットを左クリック | パネルを開閉 |
| ウィジェットを右クリック | 動作中の注入をすべて停止 |
| ウィジェットを中クリック | ウィジェット設定（Noctalia 標準の挙動） |
| プリセット行をクリック | そのプリセットに切り替え。既に動作中ならトグルで停止 |
| デバイス行の Start / Stop | 最後に選んだ（なければ先頭の）プリセットで開始 / 停止 |
| Reload | プリセットの再スキャンとデーモン疎通確認 |
| Stop all | 動作中の注入をすべて停止 |

`setted` バッジ = そのプリセットが**今まさに注入中**。

IPC からも叩ける:

```sh
noctalia msg panel-toggle haru/input-remapper:panel
noctalia msg plugin haru/input-remapper:service all reload
noctalia msg plugin haru/input-remapper:service all stop-all
```

---

## 設定項目

Settings → Plugins → この行の歯車。

| キー | 既定 | 説明 |
|---|---|---|
| `config_dir` | `~/.config/input-remapper-2` | `presets/` と `config.json` のある場所 |
| `control_cmd` | `input-remapper-control` | デーモンと話す実行ファイル。クォートせず展開されるのでラッパーも書ける |
| `poll_seconds` | `5` | 再スキャンと疎通確認の間隔 |
| `hide_empty_devices` | `true` | `.json` が一つもないフォルダを隠す |
| `detect_connected` | `true` | 接続中かどうかで Connected / Saved に振り分ける |
| `scroll_height` | `0` | 一覧の高さ。0 = 自動。フッターが押し出されるときだけ指定 |
| `debug_log` | `false` | `<pluginDataDir>/debug.log` に診断ログを書く。トラブル時のみ有効化 |
| `on_startup` | `restore` | Noctalia 起動時に前回の注入状態をどう扱うか |

ウィジェット側（バーのウィジェット設定）:

| キー | 既定 | 説明 |
|---|---|---|
| `show_label` | `true` | 注入が1つのときプリセット名をバーに出す |
| `max_label_chars` | `18` | それより長い名前は省略 |

---

## 設計メモ

**デバイスとプリセットの取得**
`--list-devices`（root 必須）は使わず、`presets/` 以下のディレクトリツリーを直接読む。
フォルダ名がそのまま `--device` に渡す名前と一致するため、root も D-Bus も不要で速い。

**接続判定**
`/proc/bus/input/devices` の `N: Name="..."` 行を読んでフォルダ名と突き合わせる。
world-readable かつカーネル生成なので root も D-Bus も不要。完全一致で拾えなかった
場合は前後の空白を無視して再比較する（AJAZZ の先頭スペース7個のようなケース対策）。
ファイルが読めない、または一件も名前が取れなかったときは全デバイスを Connected 扱いに
フォールバックするので、判定失敗でデバイスが消えることはない。注入中のデバイスは
判定結果によらず常に Connected に置く。

**パネルのレイアウト**
`panel.luau` はパネルの寸法を**一切参照しない**。スクロール領域は `flexGrow` で
余りを取るだけ。

0.2.x では `PANEL_HEIGHT - CHROME_HEIGHT` という引き算で固定高さを与えていたが、
これは壊れる。`.luau` は保存した瞬間にホットリロードされるのに対し `plugin.toml` は
次のコンフィグリロードまで反映されないため、**2つのファイルが別々のタイミングで
読み込まれる**。スクリプトが新しい寸法で計算している間、サーフェスはまだ古い寸法の
まま、という状態が発生し、リロードのやり方次第でレイアウトが変わる不安定さを生んで
いた。寸法への依存を消せばこの問題は原理的に起きない。

`flexGrow` が効かない環境向けに `scroll_height` 設定（0 = 自動）を逃げ道として
残してある。フッターが画面外に出るときだけ数値を入れる。

**シェルクォート**
`plugin_api = 15` では `runAsync` の引数配列形式（API 24）が使えないため、
コマンドはシェル文字列として組み立てられる。デバイス名には空白・カンマ・
先頭スペース（AJAZZ は7個）が入るので、全ての値を POSIX のシングルクォート
エスケープ（`'` → `'\''`）に通している。

**状態の持ち方**
`input-remapper` には「どのプリセットが注入中か」を返す CLI がないため、
プラグインが自分の発行した start/stop を記憶し、`pluginDataDir()` に永続化する。
デーモンに疎通できなくなったら注入はあり得ないので記憶を破棄する。
GUI 側で操作して食い違ったときは Reload で直る。

**エントリ間の通信**
`service` が唯一の真実として `devices` / `active` / `daemon` を `noctalia.state`
に publish し、`panel` と `widget` が watch する。`panel` はコマンド成功後に
`active` を書き戻す。

---

## 0.3.2 で直った不具合（原因の記録）

0.2.0 〜 0.3.1 で「開くたびに見た目が変わる」現象が出ていた。診断ログを仕込んで
特定した結果、**バージョンの多重読み込みでもレイアウト計算のズレでもなく**、
Connected/Saved の開閉状態をパネルを閉じても覚え続けていたのが原因だった。
デバッグ中の操作でどこかのタイミングで畳まれ、それがずっと引き継がれて
「何も表示されないパネル」に見えていた。0.3.2 ではパネルを開くたびに
Connected を展開・Saved を折りたたみへリセットするようにした。

## 既知の制約と今後

- **プリセット名にゴミが混ざる**: `Akko Keyboard/Roblox_Evade_macro copy.json` が
  そのまま一覧に出る。不要なら消すのが早い。
- **フォルダ名と evdev のデバイス名がずれる場合**: 通常は一致するが、ずれていると
  `start` が「device unknown」で失敗する。そのときは通知が出るので
  `sudo input-remapper-control --list-devices` と突き合わせる。
- **接続判定は名前一致**: フォルダ名と evdev のデバイス名がずれていると Saved 側に
  落ちる。Saved のカードもクリックすれば起動を試せる（無効化はしていない）ので、
  誤判定で操作不能にはならない。気になるなら `detect_connected` をオフに。
- **autoload 未対応**: `config.json` の `autoload` は現状空なので UI を出していない。
  使い始めたら「起動時に自動適用」バッジとして足せる。
- **注入状態の実測**: 今は自己申告。デーモンの D-Bus に `get_state` があるので、
  そこから実測に切り替えれば GUI 併用時のズレもなくなる。

## ライセンス

MIT
