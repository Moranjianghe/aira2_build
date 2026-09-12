# aria2 自定义构建

这个仓库使用 GitHub Actions 跟踪 aria2 官方稳定版发布，并为个人设备构建六个发行包：

- Windows x86-64-v3：BitTorrent 版、无 BitTorrent 版
- Debian 12 x86-64-v2：BitTorrent 版、无 BitTorrent 版
- Debian 13 x86-64-v3：BitTorrent 版、无 BitTorrent 版

目标对应的设备：

- Windows x86-64-v3：AMD Ryzen 5 7500F 本机
- Debian 13 x86-64-v3：第 11 代 Intel 笔记本
- Debian 12 x86-64-v2：Intel Xeon E5-2650 v2 VPS

x86-64-v3 包只适用于支持 AVX2 等对应指令集的设备；E5-2650 v2 使用 v2 是因为它不支持 v3 所需的 AVX2。

## 已确认的自定义内容

- 将 max-connection-per-server 的内部最大值从 16 改为 -1，表示不设上限；默认值仍然是 1。
- 两个功能变体分别使用 --enable-bittorrent 和 --disable-bittorrent。
- Windows 使用 MinGW-w64、WinTLS 和静态链接。
- Debian 使用 OpenSSL 和动态链接，默认 CA bundle 为 /etc/ssl/certs/ca-certificates.crt。
- 编译器参数使用 -O3 -flto=auto，并按目标分别使用 x86-64-v2 或 x86-64-v3。

没有加入 -march=native，因为构建运行在 GitHub 公共 runner 上；也没有加入尚未确认的下载行为改动，例如调整 min-split-size、默认分片数或重试策略。

## 发布方式

工作流 .github/workflows/release.yml 每天定时检查 aria2 官方 GitHub Releases，也可以手动运行并填写 upstream_tag，例如 release-1.37.0。

检测到新的正式稳定版后，工作流会：

1. 从 aria2 官方 Release 下载对应的源码压缩包并校验 GitHub 提供的 digest（如果有）。
2. 应用 patches/unlimited-max-connection-per-server.patch。
3. 并行构建六个目标。
4. 将各包及其 SHA-256 文件发布到本仓库的 aria2-X.Y.Z Release。

工作流只跟踪 release-X.Y.Z 格式的正式稳定版，不跟踪 master、预发布版或草稿版。如果对应的自定义 Release 已存在且已经包含六个目标包，则跳过构建；旧 Release 缺少包时会自动重建并补充资产。

## 本地构建

GitHub Actions 会在公共 runner 上运行。Debian 构建直接使用对应的官方 Docker 镜像；Windows 构建使用仓库内的 docker/Dockerfile.mingw。

Windows ZIP 包包含 `aria2c.exe`、`COPYING` 和 `BUILD-INFO.txt`；Debian `.deb` 包安装 `aria2c`、版权文件和 `BUILD-INFO.txt`。所有包均发布包级别的 `.sha256` 校验文件。

Debian 构建发布可由 deb-get/apt 安装的 `.deb` 包，两个变体的内部包名均为 `aria2`。BitTorrent 版本使用 `X.Y.Z+custom1~bt`，无 BitTorrent 版本使用更高的 `X.Y.Z+custom1`；deb-get 的 `aria2` 定义固定选择无 BitTorrent 资产。Windows 发布 ZIP 包。

BUILD-INFO.txt 会记录上游 tag、目标 ISA、BitTorrent 状态和完整编译参数。
