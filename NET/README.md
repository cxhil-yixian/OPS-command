# NET/

`net-set.sh` — IP 與 DNS 伺服器的增加、減少、替換。重點是**遠端改 IP 不要把自己鎖在門外**。

可以透過根目錄的 [`../ops.sh`](../README.md) 選單操作（主選單按 `n`），以下是直接呼叫的說明。

| | |
|---|---|
| Shell | POSIX sh |
| 支援改設定 | Ubuntu 22.04 / 24.04；其他系統只有 `status` / `doctor`，改設定會拒絕 |
| 需要 root | 是（`status` / `doctor` / `-h` 除外） |
| 會改系統嗎 | 會：`/etc/netplan/`、`/etc/network/interfaces`、`/etc/resolv.conf`、網卡上的位址；IP 變更進行中另有 `ops-net-watchdog.service` |
| 相依 | `iproute2`；netplan 後端需要 `python3-yaml`（netplan 本身就相依它） |

```bash
./net-set.sh status                         網卡 / IP / 閘道 / DNS / 進行中的變更
./net-set.sh ip-add <IP[/前綴]> [-i 網卡]   增加 IP
./net-set.sh ip-del <IP>                    刪除 IP
./net-set.sh ip-replace <舊IP> <新IP>       替換 IP（同網段，閘道不變）
./net-set.sh dns-add <DNS> [--first]        增加 DNS，預設加在最後
./net-set.sh dns-del <DNS>                  刪除 DNS
./net-set.sh dns-replace <舊DNS> <新DNS>    替換 DNS，保留原本的順序位置
./net-set.sh confirm                        確認 IP 變更（替換時才移除舊 IP）
./net-set.sh rollback                       立刻還原到變更前
./net-set.sh doctor                         環境檢查
```

選項：`-y` 免確認、`-n` 乾跑、`-t 秒數` 看門狗時限（預設 300，最少 30）。

環境變數：`OPS_NET_TESTNAME` 驗證 DNS 時要解析的網域，預設 `cloudflare.com`。
內網 DNS 查不到外部網域時，設成內部網域。

---

## 先判斷這台實際用什麼管網路

不依系統版本猜。Ubuntu 22.04 也可能沒有 netplan，廠商映像常見用 ifupdown。

| 偵測結果 | IP 寫在哪 |
|---|---|
| `/etc/netplan/*.yaml` 有設定，renderer 不是 NetworkManager | netplan |
| `/etc/network/interfaces` 有 `lo` 以外的網卡 | ifupdown |
| 兩邊都有設定 | **拒絕**，判斷不出哪邊生效 |
| NetworkManager 正在執行 | **拒絕**，這個版本沒有後端 |
| 都不是 | **拒絕** |

DNS 看 `/etc/resolv.conf` 的實際來源，跟 IP 後端分開判斷：

| `/etc/resolv.conf` | DNS 寫在哪 |
|---|---|
| 一般檔案 | 直接寫這個檔案，`search` / `options` 與註解保留 |
| 連到 systemd-resolved，網卡由 netplan 管 | netplan 的 `nameservers`，寫在預設路由所在的網卡 |
| 其他 | **拒絕** |

ifupdown 的 `dns-nameservers` 沒裝 `resolvconf` 時不起作用，所以不會改它，`doctor` 會講這件事。

---

## 改 IP 怎麼防鎖死

每次 IP 變更都先備份，再開看門狗，時限內沒有 `confirm` 就自動還原。

`ip-replace` 分兩階段：

```
ip-replace 舊 新   → 加上新 IP，新舊並存，看門狗開始倒數
從新 IP 登入       → 這一步才證明新 IP 真的通
confirm            → 移除舊 IP，取消看門狗
```

以下幾條不看 `-y`，沒有開關可以繞過：

| 情況 | 行為 |
|---|---|
| `ip-del` 目前任何 SSH 連線正在用的 IP | 拒絕，請改用 `ip-replace` |
| 從舊 IP 執行替換的 `confirm` | 拒絕，要從新 IP 登入 |
| 刪掉之後預設閘道到不了 | 拒絕 |
| `sshd` 的 `ListenAddress` 沒包含新 IP | 拒絕，換過去會登不進來 |

**第一版的範圍：** 只做 IPv4；替換只限同網段，前綴與閘道都不變。跨網段可以用 `ip-add` 加副 IP
（要帶前綴），不會動預設閘道；跨網段替換主 IP 會拒絕。

ifupdown 帶閘道或唯一的主段落不能 `ip-del`，要換位址請用 `ip-replace`。

### 改 netplan 會消失的東西

netplan 的 YAML 用 python3-yaml 改寫，**檔案裡的註解會消失**，動手前會警告，原檔在備份裡。

### 重開機中途

未 `confirm` 的變更碰上重開機，由 `ops-net-watchdog.service` 接手：等開機的網路就緒後重新倒數一個
完整時限，時間到沒有 `confirm` 就自動還原。服務只在變更進行中存在，`confirm` 或還原後就移除。

服務裝不起來時工具會警告，`status` 也會標出「看門狗已不在」，這時請手動 `confirm` 或 `rollback`。

---

## 改 DNS

DNS 改錯不會斷 SSH，所以不開看門狗，用實際解析驗證：

1. 加入前先向那台 DNS 查一次。查不到就警告並詢問，`-y` 模式直接拒絕。
2. 變更後回讀清單，再用系統解析一次。
3. 變更前能解析、變更後不能，就自動還原。變更前本來就不能解析時，只警告。

不能刪最後一台。IP 變更進行中不能改 DNS，因為還原 IP 會把同一份檔案蓋回去。

---

## 重開機後被蓋回去

工具偵測到 `rsService`（RStack 的代理程式）或未停用網路設定的 cloud-init 時會警告，**不會停用它們**。
如果 IP 或 DNS 是由廠商面板管理，面板也要同步修改。

---

## 實測紀錄

| 項目 | Ubuntu 24.04（netplan，networkd） | Ubuntu 22.04（ifupdown） |
|---|---|---|
| 偵測後端 / DNS 來源 / 覆寫來源 | 通過 | 通過 |
| 增加、刪除、還原、看門狗逾時 | 公網 IP 通過 | 公網 IP 通過 |
| 替換副 IP | 公網 IP 通過 | `dummy0` 通過 |
| 替換主 IP，從舊 IP `confirm` 被拒 | 公網 IP 通過 | 公網 IP 通過 |
| 替換主 IP，**從新 IP 登入後 `confirm`** | 公網 IP 通過，舊 IP 確實斷線 | **未驗證** |
| DNS 增加 / 刪除 / 替換 / IPv6 | 通過 | 通過（IPv6 未測） |
| DNS 全掛時自動還原 | 通過（Proxmox VM） | 通過 |
| 重開機後 IP 與 DNS 保留（刪除、加回） | 通過（Proxmox VM） | **未驗證** |
| 未 `confirm` 就重開機：開機後自動還原 / 開機後 `confirm` / 開機後 `rollback` | 通過（Proxmox VM） | **未驗證** |

重開機測試在 Ubuntu 24.04.5 的 Proxmox VM 上跑了 9 次，只改 `01-netcfg.yaml` 裡的 `eth0`。
這台開機時 `systemd-networkd-wait-online` 會卡 2 分鐘，開機接手的倒數確實等它結束才開始，
和 SSH 能連線的時間相同。這台的
cloud-init 網路設定未停用，但 `instance-id` 沒變，開機時記錄 `No network config applied`，
`50-cloud-init.yaml` 的 hash 全程不變。`rsService` 在這台沒有執行。

**尚未驗證：**

- **重開機之後設定是否保留（22.04 ifupdown）。** 另外，`rsService` 會不會蓋回去還是推測，
  Proxmox 改過 Cloud-Init 設定、造成 `instance-id` 變更時會不會蓋回去也沒有測。
- **ifupdown 從新 IP 登入。** 測試機的第二個 IP 外面連不進來（封包沒有進到 VM），這不是工具造成的，
  原始狀態就是如此。兩階段的改寫邏輯是用 `dummy0` 驗證的。
- **cloud-init 會產生 netplan 的情境。** 測試機的 cloud-init 網路設定已停用，只驗過 `match` / `set-name`
  的 YAML 解析與 `netplan generate`。
- **Ubuntu 22.04 + netplan、24.04 + ifupdown** 這兩個組合。

## 實測學到的事

- **未 `confirm` 的變更會留到重開機之後。** 設定檔在 `confirm` 前就寫好了，原本的背景看門狗
  活不過重開機，改壞又碰上重開機就沒有自動還原。所以加了開機接手的服務，倒數排在開機等網路之後。
- **閘道可能代答 ARP。** 同網段的 IP 全部解析成閘道的 MAC，所以 ARP 有回應不代表被佔用，只有 MAC
  跟閘道不同才算。也因此衝突檢查不是萬能的：不回 ping 又躲在代答後面的機器查不出來。
- **`promote_secondaries=0` 時刪主位址，同網段副位址會一起消失。** 工具動手時會暫時打開，事後恢復。
  核心看的是 `all` 或網卡自己其中一個為 1；`netplan apply` 時 networkd 也會把網卡的值設成 1。
- **`dig +short` 逾時會把錯誤印在 stdout。** 只看有沒有輸出會把不通的 DNS 當成通的。
