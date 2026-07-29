# OPS-command

一組給 Linux 伺服器日常運維用的腳本，重點放在**遠端操作時不要把自己鎖在門外**。

所有工具都能單獨執行，也可以透過 `ops.sh` 的視覺化選單操作。

---

## 快速開始

```bash
git clone https://github.com/cxhil-yixian/OPS-command.git
cd OPS-command
chmod +x ops.sh SSH/*.sh

sudo ./ops.sh
```

```
────────────────────────────────────────────────────────────────────
 OPS-command 運維工具箱  v1.0
────────────────────────────────────────────────────────────────────
 系統   Rocky Linux 9.4  (family=rhel, init=systemd, pkg=dnf)
 SSH    服務 sshd = active   埠 22
 防護   防火牆 firewalld   SELinux enforcing   身分 root
────────────────────────────────────────────────────────────────────
 SSH 連接埠  (SSH/ssh-port.sh)
   1) 查看目前狀態
   2) 變更連接埠      新舊埠並存 + 看門狗，不會把自己鎖在門外
   3) 確認新埠可用    收掉舊埠，取消看門狗
   4) 立即還原        回到變更前的設定

 SSH 監控與取證  (SSH/selfheal-ssh.sh)
   5) 即時監看        每秒刷新，看得到誰在連、卡在哪個階段
   6) 一次性取證      完整報告寫入 /var/log/n9e-selfheal/
   7) 追蹤認證日誌    即時 tail 登入成功/失敗事件
   8) 解析排查        傾印原始 ss / ps 資料，回報問題時用

 系統
   9) 更換套件來源鏡像 呼叫 linuxmirrors.cn 的外部腳本
   d) 環境自我診斷     檢查相依套件與已知相容性問題
   i) 安裝缺少的相依套件
   q) 離開
```

**上手前建議先按 `d`**，它會告訴你這台機器缺什麼、有哪些已知相容性問題。

---

## 目錄結構

```
OPS-command/
├── ops.sh              視覺化操作選單（POSIX sh，零相依）
├── SSH/                → 詳見 SSH/README.md
│   ├── ssh-port.sh     安全變更 SSH 連接埠（雙埠並存 + 看門狗自動還原）
│   └── selfheal-ssh.sh SSH 連線取證與即時監看（夜鶯 n9e 自愈腳本）
├── REPO/
│   └── URL             換源腳本的來源網址（linuxmirrors.cn，第三方）
└── LICENSE             MIT
```

---

## ops.sh

一支入口把底下的工具包起來，不必記參數。

```bash
./ops.sh            進入互動選單
./ops.sh doctor     只做環境檢查後離開；有必要套件缺失時 exit 1，可寫進巡檢排程
./ops.sh -h         說明
```

設計上刻意保持三件事：

1. **零相依**：純 POSIX sh，不需要 `dialog` / `whiptail` / ncurses。Alpine 的 busybox
   ash 與 CentOS 7 的舊 bash 都能直接跑，最小化安裝的機器不用先裝東西才能用。
2. **選單自己不碰系統設定**：它只做「導覽 + 前置檢查 + 呼叫」，所有實際變更都在被呼叫
   的腳本裡。出事時追查範圍不會擴散到選單本身。
3. **危險動作先攤開再問**：換埠會先自動跑一次乾跑把「將要動到什麼」印出來才問你要不要
   做；換源要打完整的 `YES` 才會執行。

沒有 UTF-8 locale 的機器（常見於最小化安裝的 CentOS 7）會自動退回 ASCII 框線；
非終端機執行會直接擋下來並提示改用底層腳本。設 `NO_COLOR=1` 可關閉顏色。

---

## 支援矩陣

| 發行版 | ops.sh | ssh-port.sh | selfheal-ssh.sh |
|---|---|---|---|
| CentOS 7.9 | ✅ | ✅ | ✅ |
| RHEL 8 / 9 / 10 | ✅ | ✅ | ✅ |
| Rocky / AlmaLinux 8 / 9 | ✅ | ✅ | ✅ |
| Debian 9 / 10 / 11 / 12 | ✅ | ✅ | ✅ |
| Ubuntu 18.04 / 20.04 / 22.04 / 24.04 | ✅ | ✅ | ✅ |
| Alpine (OpenRC + busybox) | ✅ | ✅ | ✅ |

**三支腳本全部是 POSIX sh，Alpine 的 busybox ash 可以直接執行，不需要安裝 bash。**
唯一需要 bash 的是選單第 9 項呼叫的第三方換源腳本。

外部指令一律「先探測能力再用」，探測不到就降級並在輸出中寫明降級了什麼，不靜默失效：

| 情況 | 行為 |
|---|---|
| 沒有 `ss` | 退回 `netstat` |
| 沒有 procps 版 `ps` | 階段分類降級為粗略統計，並在畫面上標紅說明 |
| 沒有 `journalctl` | 依序找 `/var/log/secure`、`auth.log`、`messages`、`logread` |
| 沒有 `flock` | 跳過重入保護，照常採集（不會誤判成「已有程序執行中」而整輪不跑） |
| 沒有 `who` / 系統不維護 utmp | session 數改由 sshd 行程標題推估 |
| busybox `date` 不支援 `-d '1 hour ago'` | 改用 `-d @epoch` / `-D %s`，再不行退回現在時刻 |
| busybox `watch` 不支援 `-t` / `--color` | 逐項探測後只帶支援的選項 |

---

## 相依套件

三支腳本都能在最小化安裝上跑起來，下表是**想要完整功能**時建議補的：

| 系統 | 安裝指令 |
|---|---|
| CentOS 7 | `yum install -y iproute procps-ng util-linux policycoreutils-python` |
| RHEL/Rocky 8+ | `dnf install -y iproute procps-ng util-linux policycoreutils-python-utils` |
| Debian / Ubuntu | `apt-get install -y iproute2 procps util-linux` |
| Alpine | `apk add --no-cache procps coreutils util-linux iproute2` |

- `procps` 是唯一會影響**判讀正確性**的一項：沒有它就分不出「已登入」與「認證中」，
  而這正是分辨「50 個人在用」和「正在被爆破」的關鍵。
- `policycoreutils-python*` 只在 **SELinux 啟用**時需要——沒有 `semanage`，換到非標準
  埠會讓 sshd 在 bind 階段被 SELinux 拒絕，服務起不來就是直接失聯。
- Alpine 若要有登入失敗統計，需啟用 syslog：
  `rc-update add syslog && rc-service syslog start`。沒有它連線層統計照常運作，
  只是失敗數會是 0——`doctor` 會明講這是「讀不到」而不是「沒被攻擊」。

選單按 `i` 會依偵測結果組出這台機器實際需要的那一行並執行。

---

## 安全須知

- **換埠請務必走「set → 另開視窗測試 → confirm」三步**。`set` 階段新舊埠同時監聽，
  現有連線不會斷；沒有在時限內 `confirm`，看門狗會自動把設定檔、防火牆規則、SELinux
  標籤全部還原。詳細機制見 [SSH/README.md](SSH/README.md)。
- **雲端主機另外要開安全群組 / 網路 ACL**。本機防火牆放行了不代表雲端那層放行了，
  這是換埠失聯最常見的原因。
- **選單第 9 項會下載並以 root 執行第三方腳本**（`REPO/URL` 記錄的
  `https://linuxmirrors.cn/main.sh`）。本 repo 只記錄網址，不對其內容負責。
  不放心請先自行下載檢視再執行。
- **`selfheal-ssh.sh` 純取證，不改變系統任何狀態、不封鎖任何 IP**。這是刻意的——
  自動封鎖腳本誤封跳板機或監控伺服器會讓機器直接失聯，要封請用 fail2ban。

---

## 授權

MIT，見 [LICENSE](LICENSE)。
