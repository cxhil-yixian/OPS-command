# FAIL2BAN/

`fail2ban.sh` — fail2ban 的封鎖管理介面：手動封鎖 / 解封、白名單、排行、環境檢查。

可以透過根目錄的 [`../ops.sh`](../README.md) 選單操作（主選單按 `b`），以下是直接呼叫的說明。

| | |
|---|---|
| Shell | POSIX sh（Alpine 的 busybox ash 可直接執行） |
| 需要 root | 是（fail2ban 的控制 socket 只有 root 能用），`doctor` / `-h` 除外 |
| 會改系統嗎 | 會：封鎖狀態（透過 fail2ban-client）與 `jail.d/zz-ops-*.local` 兩個設定檔 |
| 相依 | fail2ban 本身；沒裝可以用 `install` 裝 |

```bash
./fail2ban.sh status              服務與各 jail 的封鎖概況
./fail2ban.sh list [jail]         列出已封鎖的 IP
./fail2ban.sh ban <IP…>           手動封鎖（預設所有 jail）
./fail2ban.sh unban <IP…>         解除封鎖（自動找出哪些 jail 封了它）
./fail2ban.sh unban-all           清空封鎖清單
./fail2ban.sh check <IP>          查這個 IP 現在的狀態
./fail2ban.sh allow <IP…>         加白名單（ignoreip）
./fail2ban.sh disallow <IP…>      移除白名單
./fail2ban.sh top [n]             封鎖次數最多的來源
./fail2ban.sh log [n]             最近的封鎖 / 解除事件
./fail2ban.sh tail                即時追蹤 fail2ban 日誌
./fail2ban.sh bantime [jail] [秒] 查看 / 設定封鎖時長
./fail2ban.sh enable-sshd         建立 sshd jail（埠號取實際生效值）
./fail2ban.sh reload              重載設定
./fail2ban.sh install             安裝並啟用 fail2ban
./fail2ban.sh doctor              環境檢查
```

選項：`-j <jail>` 只對單一 jail、`-t <秒|perm>` 封鎖時長、`-y` 免確認、`-n` 乾跑、
`--force` 即使會鎖到自己也照做。

支援 IP 與 CIDR（`203.0.113.0/24`），IPv6 可用但涵蓋判斷只做前綴字串比對。

---

## 不會讓你把自己關在門外

跟 `../SSH/ssh-port.sh` 同一個原則。手動封鎖最容易出事的就是打錯一碼、或封了一段
涵蓋自己的網段，然後 SSH 立刻斷線。

封鎖前一定先算三件事，命中任何一項就直接擋下來：

| 檢查 | 說明 |
|---|---|
| 你目前的 SSH 來源 | 取自 `SSH_CONNECTION` / `SSH_CLIENT`；`sudo` 把環境變數清掉時，改用「持有行程在自己的祖先鏈上**且**本地埠是實際 SSH 埠」的連線反推；再加上 `who` 列出的其他已登入 session |
| 本機自己的位址 | `ip addr` / `ifconfig` 上的所有位址 |
| loopback | `127.0.0.0/8`、`::1` |

> 反推那條的兩個條件缺一不可，而且都是真的踩過才補上的：**只比對埠號**會把攻擊者
> 卡在認證階段的連線也當成「你自己」——結果是不准你封鎖正在爆破你的 IP，`doctor`
> 還會建議你把攻擊者加白名單；**只比對祖先鏈**則會把登入後在這條 session 裡跑的
> 任何對外連線（yum、curl、agent…）的對端算成你的來源。

CIDR 是真的做網段涵蓋計算的，不是字串比對：

```
$ ./fail2ban.sh ban 61.219.0.0/16
  x 61.219.0.0/16 涵蓋 你目前的 SSH 來源 61.219.171.56
  封下去就是把自己關在外面。要真的執行請加 --force（風險自負）
```

> POSIX awk 沒有位元運算，所以網段比對是用「除以 2^(32-prefix) 後比商」做的，
> 效果等同遮罩比對，但不需要 `gawk` 的擴充函式。

真的要封含自己的網段（例如你等下要從別條線路進來）就加 `--force`，它會照做，
但會先警告。

---

## 三種「設了但不會生效」

`doctor` 專門在抓這些。它們的共同點是：fail2ban 服務看起來好好的、`systemctl status`
是綠的，但實際上一個攻擊都擋不住。

**1. 沒有任何 jail**
RHEL 系裝完 fail2ban 之後，`jail.conf` 裡全部 `enabled = false`，服務起得來、
但什麼都不會封。這是最常見的「以為裝了就有保護」。

```bash
./fail2ban.sh enable-sshd     # 建立 jail.d/zz-ops-sshd.local
```

**2. jail 的 port 沒跟上實際的 SSH 埠**
用 [`../SSH/ssh-port.sh`](../SSH/README.md) 換過埠之後最容易踩到：fail2ban 照樣讀日誌、
照樣「封鎖成功」，但防火牆規則套在舊埠上，攻擊者從新埠進來完全不受影響。

`doctor` 會把 jail 設定裡的 `port` 跟 `sshd -T` 的實際值比對：

```
  實際 SSH 埠: 9227
  sshd jail 的 port: 22
  x SSH 實際在 9227，但 jail 的 port 是「22」— 封鎖會套錯埠
  修正：./fail2ban.sh enable-sshd
```

**換完 SSH 埠請重跑一次 `enable-sshd`。**

**3. 封鎖清單有東西，防火牆裡卻沒有規則**
`banaction` 與實際的防火牆後端對不上時會這樣（firewalld 環境常見）。封鎖清單裡有、
防火牆裡沒有，就是封包照樣進得來。

`doctor` 的驗證方式是**拿一個現在真的被封的 IP，去 iptables / nftables / ipset /
firewalld 裡實際找**，而不是看規則名稱裡有沒有 `f2b`——後者在 banaction 走 firewalld
或 ipset 時規則不叫這個名字，會變成誤報。找不到時會一併給出該查哪個設定、
以及 fail2ban 日誌裡對應的錯誤關鍵字。

---

## 白名單（ignoreip）

`allow` / `disallow` 只寫一個檔案：`/etc/fail2ban/jail.d/zz-ops-ignoreip.local`。

fail2ban 的設定載入順序是 `jail.conf` → `jail.d/*.conf` → `jail.local` →
`jail.d/*.local`，**我們的檔案在最後**，所以它的 `[DEFAULT] ignoreip` 會蓋掉前面
所有設定。這代表寫入時一定要把「原本就生效的值」一起帶上，否則會把管理員原有的
白名單默默吃掉——腳本因此每次都先讀回目前生效的清單再合併，並且一定含
`127.0.0.1/8` 與 `::1`。`disallow` 也拒絕移除 loopback。

兩個容易誤解的點：

- **白名單不會解除已經被封的 IP。** `ignoreip` 只影響「之後」要不要封。`allow` 偵測到
  該 IP 目前仍在封鎖清單裡時會提醒你去跑 `unban`。
- **即時生效的方式看版本。** 新版用 `addignoreip` 直接套到執行中的 jail；舊版沒有這個
  子命令，腳本會改用 `reload`。兩種情況都會在畫面上講明走的是哪條路。

---

## 封鎖時長

`-t` 是 best-effort：不同版本的 `banip` 對「帶時長」的支援不一樣，腳本**先試帶時長的
寫法，再看那個 IP 有沒有真的進封鎖清單**來判斷成不成功——不是比對版本號（發行版常有
backport，版本號不可靠），也不是解析 help 文字（各版用詞不同）。

不支援時會退回 jail 本身的 `bantime`，並明講一次：

```
  ! 這個 fail2ban 版本的 banip 不接受指定時長，改用 jail 本身的 bantime
    要改 jail 的預設時長：./fail2ban.sh bantime <jail> <秒>
```

`bantime <jail> <秒>` 改的是**執行中**的設定，重啟 fail2ban 就會回到設定檔的值；
要永久生效請寫進 `jail.d` 底下的 `.local` 檔（`enable-sshd` 產生的那份可以直接改）。

---

## 檔案位置

| 路徑 | 用途 |
|---|---|
| `/var/log/OPS-ssh/fail2ban-ops.log` | 本腳本的操作稽核（誰在什麼時候封了誰） |
| `/etc/fail2ban/jail.d/zz-ops-ignoreip.local` | `allow` / `disallow` 管理的白名單 |
| `/etc/fail2ban/jail.d/zz-ops-sshd.local` | `enable-sshd` 產生的 sshd jail |

產出目錄跟其他工具共用，見 [../SSH/README.md](../SSH/README.md#檔案位置)；
設 `OPS_SSH_DIR` 可換位置。

**只寫 `jail.d/zz-ops-*.local`，不動發行版的 `jail.conf`。** 後者會在套件升級時被覆寫，
改在那裡的東西遲早會消失，而且事後很難看出是誰改的。兩個檔案開頭都有「由 fail2ban.sh
管理」的註解。

---

## 相容性

封鎖操作一律透過 `fail2ban-client`，**不自己寫 iptables / nftables 規則**。手寫規則跟
fail2ban 自己的狀態不一致，是這類工具最難查的問題：清單裡看不到、規則卻還在，或反過來。

狀態一律解析 `fail2ban-client status` 的輸出，不用 0.10+ 才有的 `get` 子命令，所以
0.9（Debian 9 內建）到 1.x 都能跑。版本能力（`banip --time`、`addignoreip`）用「試一次
看結果」判斷，不支援就降級並在畫面上講明。

| 情況 | 行為 |
|---|---|
| 沒裝 fail2ban | 直接說要跑哪一行安裝（RHEL 系會提醒在 EPEL） |
| 服務沒起來 | 用 `ping` 判斷而非只看 `systemctl`，並指向 `doctor` |
| 沒有 `banip --time` | 退回 jail 的 bantime，警告一次 |
| 沒有 `addignoreip` | 改用 `reload` 套用白名單 |
| 讀不到 fail2ban 日誌 | `top` / `log` 明講讀不到；`check` 的歷史統計標示不可用 |
| busybox 環境 | 日誌來源會找 `logread`；Alpine 未啟用 syslog 時會提示怎麼開 |

---

## 疑難排解

**`fail2ban 伺服器沒有回應`**
服務沒起來，或 socket 權限 / SELinux 有問題。先看 `./fail2ban.sh doctor`，再看
`journalctl -u fail2ban -n 50`。RHEL 系上 jail 用 `backend = systemd` 卻沒裝
`fail2ban-systemd` 是常見原因，`install` 在 CentOS 7 會一併裝。

**封了但對方還連得進來**
照「三種設了但不會生效」逐項檢查，`doctor` 會一次跑完。最常見的是 jail 的 port 沒跟上
換過的 SSH 埠。

**自己被自己的 fail2ban 擋在外面**
從主控台（雲端 Console / VNC / IPMI）登入後：

```bash
./fail2ban.sh unban <你的IP>
./fail2ban.sh allow <你的IP>     # 之後就不會再被封
```

`doctor` 會主動提醒「你目前的來源不在白名單內」，建議固定辦公室 / 跳板機的 IP 先加進去。

**想確認某個 IP 到底發生過什麼**

```bash
./fail2ban.sh check 203.0.113.5
```

會一次回答：在不在白名單、目前被哪些 jail 封、歷史上被封 / 解封幾次。
