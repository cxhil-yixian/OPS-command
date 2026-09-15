# APPS/

`apps.sh` — 常用軟體安裝：`docker`、`nc`、`tcpping`、`mtr`、`nginx`。依這台的發行版 /
套件管理器挑對的裝法，裝之前把會跑的指令全部攤開，裝完回頭驗證指令真的在。

可以透過根目錄的 [`../ops.sh`](../README.md) 選單操作（主選單按 `a`），以下是直接呼叫的說明。

| | |
|---|---|
| Shell | POSIX sh（Alpine 的 busybox ash 可直接執行） |
| 需要 root | 是（`status` / `-h` 除外） |
| 會改系統嗎 | 會：安裝套件、新增套件來源（docker-ce、CentOS 7 的 EPEL）、寫入 `/usr/local/bin/tcpping` |
| 相依 | 套件管理器（apt / dnf / yum / apk / zypper / pacman）；docker 與 tcpping 要 `curl` 或 `wget` |

```bash
./apps.sh status                    五項軟體的安裝狀態與版本
./apps.sh install <名稱...>          安裝指定項目，例：install nc mtr
./apps.sh install all               還沒裝的全部裝
```

選項：`-y` 免確認、`-n` 乾跑。已經裝好的項目一律略過，不會重裝。

---

## 各項怎麼裝

套件名跟著**套件管理器**走，不跟著發行版名稱走：`ID_LIKE` 沒寫或寫得怪的衍生版，
只要用的是下表其中一種套件管理器就對得上。

| 項目 | apt（Debian / Ubuntu） | dnf / yum（RHEL 系） | apk（Alpine） | zypper / pacman |
|---|---|---|---|---|
| docker | get.docker.com | get.docker.com（見下） | `docker docker-cli-compose` | get.docker.com |
| nc | `netcat-openbsd` | `nmap-ncat` | `netcat-openbsd` | `netcat-openbsd` / `openbsd-netcat` |
| tcpping | `traceroute` + 腳本 | `traceroute` + 腳本 | `tcptraceroute` + 腳本 | `traceroute` + 腳本 |
| mtr | `mtr-tiny` | `mtr` | `mtr` | `mtr` |
| nginx | `nginx` | `nginx`（CentOS/RHEL 7 先裝 `epel-release`） | `nginx` | `nginx` |

`mtr` 在 Debian 系選 `mtr-tiny`：`mtr` 那個套件會把整套 GTK 拉進來，伺服器用不到。

### docker

照 Docker 官方的做法：

```bash
curl -fsSL https://get.docker.com -o get-docker.sh
sudo sh ./get-docker.sh
```

腳本多做了三件事：

1. **先驗內容再執行**。下載到的檔案開頭不是 `#!`、或裡面沒有 `do_install`，就當成是被代理 /
   入口網頁攔截，直接擋下——不把一頁 HTML 丟給 `sh`。檔案放在用完就刪的暫存目錄。
2. **已經裝了就略過**。get-docker.sh 對已裝 docker 的機器會停 20 秒警告，而且會把 repo 設定
   重設回它的預設值，那不是「安裝常用軟體」該順手做的事。
3. **它不支援的發行版改走別條路**：

   | 情況 | 做法 |
   |---|---|
   | Alpine | get-docker.sh 會直接回 `Unsupported distribution`，改用 `apk add docker docker-cli-compose` |
   | AlmaLinux / Oracle Linux 等 | get-docker.sh 只認 `centos` / `rhel` / `rocky` / `fedora`，其他 RHEL 系改用 Docker 文件的 RHEL 相容做法：加 `download.docker.com/linux/centos/docker-ce.repo` 再裝 `docker-ce` 一組 |
   | CentOS 7 / RHEL 7 / Debian 9-11 / Ubuntu ≤ 20.04 | 照樣走 get-docker.sh，但它會印 `DEPRECATION WARNING` 並**停 10 秒**才繼續——腳本事先講，免得以為當掉 |

get-docker.sh 裝完**會自己 `systemctl enable --now docker`**（開機啟動 + 立刻啟動），這是它的
行為不是本腳本的。另外兩條路徑（apk、docker-ce repo）不會自動啟動，裝完會印出啟動指令。

連不到 `download.docker.com` 的機器可以設 `OPS_DOCKER_MIRROR=Aliyun`（或 `AzureChinaCloud`），
會變成 `sh ./get-docker.sh --mirror Aliyun`。

裝之前還會檢查：

- **RHEL 8+ 已裝 `podman` / `buildah` / `runc`**：它們帶的 runc 跟 `containerd.io` 衝突，
  dnf 會整個失敗。確定不用 podman 的話先 `dnf remove -y podman buildah runc`。
- **容器環境**：容器裡再裝 docker 需要 privileged，通常不是你要的。

> **docker 發佈的埠（`-p`）會繞過 firewalld / ufw 的規則。** docker 自己在 iptables 寫
> `DOCKER` 鏈，封包在進到 firewalld / ufw 的規則之前就被轉走了——防火牆上看起來沒開的埠，
> 外面其實連得進來。只想給本機用的服務請綁 `127.0.0.1`：`-p 127.0.0.1:8080:80`。

### tcpping

不在任何發行版的套件庫裡。它是一支 shell 腳本，實際上是呼叫 `traceroute -T`
送 TCP SYN 來量延遲（ICMP 被擋、`ping` 不通的時候用），所以分兩步：

1. 用套件管理器裝 `traceroute`（GNU 版 2.x 才有 `-T`）。Alpine 的 `traceroute` 是 busybox
   精簡版不支援 `-T`，改裝 `tcptraceroute`，tcpping 會自動改用它。
2. 從 GitHub 下載 [deajan/tcpping](https://github.com/deajan/tcpping) 的 **`v2.7`** 放到
   `/usr/local/bin/tcpping`。釘在 release tag 而不抓 `master`：`master` 是 `-dev` 版，行為隨時
   會變。一樣先落 `.part`、確認開頭是 `#!` 而且真的是 tcpping（有 `ver=` 那行）才改名。

```bash
tcpping -x 3 1.1.1.1 443
seq 0: tcp response from one.one.one.one (1.1.1.1)  1.826 ms
seq 1: tcp response from one.one.one.one (1.1.1.1)  1.917 ms
```

送 TCP SYN 要 raw socket，**要用 root 執行**。`status` 會把「腳本在、但 traceroute 不在」
標成 `缺 traceroute`——只有腳本是跑不動的。

### nginx

- **Debian / Ubuntu 裝完會立刻啟動並監聽 80 埠**（套件的 postinst 做的）。80 埠已經被佔住的話
  nginx 起不來、dpkg 會把套件留在半裝狀態，所以裝之前會先查 80 埠，有人在聽就標紅講出來。
- RHEL 系、Alpine 裝完**不會**自動啟動，裝完會印出啟動指令。
- CentOS / RHEL 7 的 nginx 在 EPEL，沒有 EPEL 的話會先裝 `epel-release`（8 之後在 AppStream，不需要）。
- 防火牆不會幫你開 80 / 443。

---

## 裝完一定驗證

套件管理器回傳 0 不代表指令真的在（套件名對到別的東西、postinst 失敗但套件已解開…），
所以裝完逐項用「指令存不存在 + 版本」確認：

```
==> 驗證
  + nc  Ncat: Version 7.92 ( https://nmap.org/ncat )
  + tcpping  tcpping v2.7
  + mtr  mtr 0.94
  + nginx  nginx/1.20.1
  + 全部完成
```

有沒裝上的會列出來並讓 `install` 回傳非 0。docker / nginx 另外印服務現況（active / 開機啟動），
**要不要開機啟動留給你決定**；用 `sudo` 執行時還會提示怎麼讓原本的使用者免 sudo 用 docker
（加進 `docker` 群組，等同給 root 權限）。

---

## 實測

在 docker 容器裡實際安裝過（容器沒有 systemd，所以「裝完會不會自動啟動服務」這部分沒驗到）：

| 環境 | 實裝項目 | 結果 |
|---|---|---|
| Debian 12 | nc / tcpping / mtr / nginx | 全部裝上，tcpping 實際量到延遲 |
| Ubuntu 24.04 | 全部（docker 走 get-docker.sh） | 全部裝上，docker 29.8.0 |
| Rocky Linux 9 | nc / tcpping / mtr / nginx | 全部裝上，tcpping 實際量到延遲 |
| AlmaLinux 9 | 全部（docker 走 docker-ce repo） | 全部裝上，docker 29.8.0 |
| Alpine 3.20（busybox ash） | tcpping / mtr / nginx | 全部裝上，tcpping 走 tcptraceroute 量到延遲；docker 只驗乾跑 |
| CentOS 7.9 | —— | 只驗 `status` 與乾跑（官方 repo 已下線，容器裝不了東西）；EPEL 判斷與 EOL 提示正確 |

zypper / pacman 的套件名是照各自的套件庫對的，**沒有實跑過**。

---

## 相容性

| 情況 | 行為 |
|---|---|
| Alpine 內建的 `nc` 是 busybox 的 | 算已安裝（能用），`status` 標成「busybox nc（精簡版）」並給出完整版的安裝指令 |
| 沒有 `curl` 也沒有 `wget` | docker 與 tcpping 在計畫階段就擋下，其他三項照裝 |
| 找不到任何套件管理器 | 列出需要的套件名後停下 |
| pacman | 不先 `-Sy`：只同步不升級是 Arch 明講不支援的「部分升級」 |

---

## 檔案位置

操作記錄寫在 `/var/log/OPS-ssh/apps-ops.log`（跟其他工具收在一起，可用 `OPS_SSH_DIR` 改）。
乾跑（`-n`）寫進去的每一行都標 `[乾跑]`。

tcpping 裝在 `/usr/local/bin/tcpping`，要移除直接刪掉這個檔即可。

---

## 環境變數

| 變數 | 作用 |
|---|---|
| `OPS_DOCKER_URL` | docker 安裝腳本的網址，預設 `https://get.docker.com`；內網鏡像用 |
| `OPS_DOCKER_MIRROR` | 交給 get-docker.sh 的 `--mirror`：`Aliyun` 或 `AzureChinaCloud` |
| `OPS_TCPPING_URL` | tcpping 腳本的網址，預設 GitHub 上的 `v2.7` |
| `OPS_SSH_DIR` | 操作記錄的位置，預設 `/var/log/OPS-ssh` |
| `NO_COLOR` | 關閉顏色 |
