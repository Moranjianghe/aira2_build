# aria2 自訂建置

這個倉庫使用 GitHub Actions 追蹤 aria2 官方穩定版，並為個人設備建置六個套件：

- Windows x86-64-v3：BitTorrent 版、無 BitTorrent 版
- Debian 12 x86-64-v2：BitTorrent 版、無 BitTorrent 版
- Debian 13 x86-64-v3：BitTorrent 版、無 BitTorrent 版

目標設備：

- Windows x86-64-v3：AMD Ryzen 5 7500F 本機
- Debian 13 x86-64-v3：第 11 代 Intel 筆記型電腦
- Debian 12 x86-64-v2：Intel Xeon E5-2650 v2 VPS

x86-64-v3 套件只適用於支援 AVX2 等對應指令集的設備；E5-2650 v2 不支援 v3 所需的 AVX2，因此使用 v2。

## 自訂內容

- 將 `max-connection-per-server` 的內部最大值從 16 改為 -1，表示不設上限；預設值仍為 1。
- 兩個功能變體分別使用 `--enable-bittorrent` 和 `--disable-bittorrent`。
- Windows 使用 MinGW-w64、WinTLS 和靜態連結。
- Debian 使用 OpenSSL 和動態連結，預設 CA bundle 為 `/etc/ssl/certs/ca-certificates.crt`。
- 編譯器參數使用 `-O3 -flto=auto`，並按目標分別使用 x86-64-v2 或 x86-64-v3。

沒有加入 `-march=native`，因為建置執行在 GitHub 公共 runner 上；也沒有更改尚未確認的下載行為，例如最小分片大小、預設分片數或重試策略。

## 觸發與發佈

工作流 `.github/workflows/release.yml` 每 6 小時於 UTC 00:17、06:17、12:17、18:17 查詢 aria2 官方 GitHub Releases。推送建置腳本、補丁、Dockerfile 或工作流到 `main` 也會執行檢查；亦可手動執行並選填 `upstream_tag`，例如 `release-1.37.0`。推送後的自動建置仍須先在 `scripts/build-config.sh` 提高 `BUILD_REVISION`，否則已有完整資產的相同修訂版會略過建置。

工作流追蹤官方 `release-X.Y.Z` 格式的最新正式穩定版。上游主分支提交、測試版與草稿版不會觸發建置；GitHub 也不會將另一個倉庫的 Release 事件直接送到本倉庫。排程可能延遲；每次檢查的穩定版、目標 Release 與略過原因會顯示在 Actions 執行摘要中。

偵測到尚未建置的正式穩定版或新的建置修訂版後，工作流會：

1. 從 aria2 官方 Release 下載原始碼壓縮檔，並檢查 GitHub 提供的 digest（如果有）。
2. 套用 `patches/unlimited-max-connection-per-server.patch`。
3. 平行建置六個目標。
4. 將套件及其 SHA-256 檔案發佈到本倉庫的 `aria2-X.Y.Z-customN` Release。

`N` 取自 `scripts/build-config.sh` 的 `BUILD_REVISION`。需要在同一個上游穩定版重建時提高該值，保留舊修訂版資產供回溯。如果目標 Release 已包含六個套件及各自的 SHA-256 檔案，就略過建置；缺少資產則重建補齊。最新上游穩定版的自訂 Release 會標記為 GitHub 的 Latest，供 deb-get 選取。

## 套件與安裝

GitHub Actions 在公共 runner 上執行。Debian 建置使用對應的官方 Docker 映像檔；Windows 建置使用 `docker/Dockerfile.mingw`。

Windows ZIP 包含 `aria2c.exe`、`COPYING` 和 `BUILD-INFO.txt`；Debian `.deb` 安裝 `aria2c`、授權檔案和 `BUILD-INFO.txt`。所有套件均附有 `.sha256` 檔案。

兩個 Debian 變體的內部套件名均為 `aria2`。BitTorrent 版使用 `X.Y.Z+zzcustomN~bt`，無 BitTorrent 版使用較高的 `X.Y.Z+zzcustomN`；這兩個版本在相同上游版本下也高於 Debian 的 `X.Y.Z+debian-*`。deb-get 的 `aria2` 定義選取無 BitTorrent 資產。Windows 發佈 ZIP 包。

新 Release 發佈且 deb-get 定義更新後，執行 `deb-get update --repos-only`、`deb-get install aria2`，再以 `dpkg-query -W aria2` 檢查版本。若要避免 Debian 官方包在自訂版發佈前搶先升級，可以在本機 `/etc/apt/preferences.d/aria2-custom.pref` 加入：

```text
Package: aria2
Pin: release o=Debian
Pin-Priority: -1
```

這只阻擋 Debian 軟體來源提供的 `aria2`，不影響手動安裝自訂 `.deb`。僅提高 `*custom*` 版本優先級無法保護只存在於本機安裝狀態的版本。啟用後，官方 aria2 更新也會被擋下，請持續檢查自訂版的上游更新。以 `apt-cache policy aria2` 確認候選版仍是已安裝的自訂版。

`BUILD-INFO.txt` 會記錄上游 tag、建置修訂號、目標 ISA、BitTorrent 狀態和完整編譯參數。
