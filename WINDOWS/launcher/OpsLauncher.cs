// OPS-command.exe —— Windows 工具的線上啟動器
//
// 做的事和一行指令 ops-win.ps1 完全一樣，只是包成點兩下就能跑的 exe：
//   1. 從 GitHub 下載 SHA256SUMS、Win_Admin_Tool.ps1、Win_Schedule_Panel.ps1 到 %LOCALAPPDATA%\OPS-command\
//   2. 檢查內容不是被代理／入口網頁換掉的 HTML，兩支檔案的 SHA256（先把 CRLF 換成 LF 再算）都要和清單對得上
//   3. 用 powershell.exe -STA -File 開主面板
// 程式本身不放在 exe 裡，所以 exe 不用跟著工具改版重出；每次執行拿到的都是 GitHub 上的最新版。
//
// 參數（一般不用帶）：
//   --use-cached       下載失敗時改用上次留在 %LOCALAPPDATA%\OPS-command\ 的副本（也可設 OPS_USE_CACHED=1）
//   --base-url <網址>  改用自己的 fork／內網鏡像（也可設 OPS_RAW_BASE）
//   --no-launch        只下載與核對，不開面板（測試用）
//
// 用 Windows 內建的 .NET Framework 4.x 編譯（build.ps1），語法維持在 C# 5，不需要另外安裝任何東西。

using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Net;
using System.Reflection;
using System.Security.Cryptography;
using System.Text;
using System.Text.RegularExpressions;
using System.Threading;

[assembly: AssemblyTitle("OPS-command")]
[assembly: AssemblyDescription("OPS-command Windows 工具啟動器")]
[assembly: AssemblyProduct("OPS-command")]
[assembly: AssemblyCopyright("MIT License")]
[assembly: AssemblyVersion("1.0.1.0")]
[assembly: AssemblyFileVersion("1.0.1.0")]
[assembly: AssemblyInformationalVersion("1.0.1")]

static class Program
{
    const string DefaultBase = "https://raw.githubusercontent.com/cxhil-yixian/OPS-command/main";

    // 每支檔案：檔名、開頭 5 行裡一定會出現的字（用來認出被換成 HTML 的情況）
    static readonly string[][] Files = new string[][] {
        new string[] { "Win_Admin_Tool.ps1", "Windows 10/11" },
        new string[] { "Win_Schedule_Panel.ps1", "Windows schedule panel" },
    };

    static void Say(string text, ConsoleColor? color)
    {
        if (color.HasValue) Console.ForegroundColor = color.Value;
        Console.WriteLine(text);
        Console.ResetColor();
    }

    static int Main(string[] args)
    {
        try { Console.OutputEncoding = Encoding.UTF8; } catch { }
        try { Console.Title = "OPS-command"; } catch { }

        bool useCached = false, noLaunch = false;
        string baseUrl = null;
        for (int i = 0; i < args.Length; i++)
        {
            string a = args[i].ToLowerInvariant();
            if (a == "--use-cached" || a == "-usecached") useCached = true;
            else if (a == "--no-launch") noLaunch = true;
            else if ((a == "--base-url" || a == "-baseurl") && i + 1 < args.Length) baseUrl = args[++i];
        }
        if (string.IsNullOrEmpty(baseUrl)) baseUrl = Environment.GetEnvironmentVariable("OPS_RAW_BASE");
        if (string.IsNullOrEmpty(baseUrl)) baseUrl = DefaultBase;
        baseUrl = baseUrl.TrimEnd('/');
        if (Environment.GetEnvironmentVariable("OPS_USE_CACHED") == "1") useCached = true;

        // .NET Framework 預設不一定開 TLS 1.2，GitHub 只收 1.2 以上（3072 = Tls12，舊版 enum 沒有這個名字）
        try { ServicePointManager.SecurityProtocol |= (SecurityProtocolType)3072; } catch { }

        string dir = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "OPS-command");
        string main = Path.Combine(dir, Files[0][0]);
        string ver = Assembly.GetExecutingAssembly().GetName().Version.ToString(3);

        Console.WriteLine();
        Say(" OPS-command Windows 工具（啟動器 " + ver + "）", ConsoleColor.Cyan);
        Console.WriteLine(" 來源  " + baseUrl + "/WINDOWS/");
        Console.WriteLine(" 落地  " + dir);
        Console.WriteLine();

        bool ready = false, integrityFailed = false;
        string sumTmp = Path.Combine(dir, "SHA256SUMS.part");
        try
        {
            Directory.CreateDirectory(dir);
            Console.Write(" 下載中 ... ");
            using (WebClient wc = new WebClient())
            {
                wc.Headers[HttpRequestHeader.UserAgent] = "OPS-command-launcher/" + ver;
                wc.DownloadFile(baseUrl + "/WINDOWS/SHA256SUMS", sumTmp);
                foreach (string[] f in Files)
                    wc.DownloadFile(baseUrl + "/WINDOWS/" + f[0], Path.Combine(dir, f[0] + ".part"));
            }

            // 清單格式同 sha256sum：<64 位十六進位>  <檔名>
            Dictionary<string, string> sums = new Dictionary<string, string>();
            foreach (string line in File.ReadAllLines(sumTmp))
            {
                Match m = Regex.Match(line, @"^\s*([0-9a-fA-F]{64})\s+\*?(\S+)\s*$");
                if (m.Success) sums[m.Groups[2].Value] = m.Groups[1].Value.ToLowerInvariant();
            }

            List<string> bad = new List<string>();
            foreach (string[] f in Files)
            {
                string part = Path.Combine(dir, f[0] + ".part");
                if (!HeadContains(part, f[1]))
                    throw new Exception("內容不像 " + f[0] + "，可能被代理或入口網頁攔截");
                string want;
                if (!sums.TryGetValue(f[0], out want))
                {
                    integrityFailed = true;
                    throw new Exception("SHA256SUMS 裡沒有 " + f[0] + "，無法確認檔案完整，拒絕執行");
                }
                string got = LfSha256(part);
                if (got != want) bad.Add("   " + f[0] + "\n     清單  " + want + "\n     下載  " + got);
            }
            if (bad.Count > 0)
            {
                integrityFailed = true;
                throw new Exception("下載的檔案和 SHA256SUMS 對不上，拒絕執行：\n" + string.Join("\n", bad.ToArray()) +
                    "\n   可能原因：下載不完整、被代理或入口網頁換掉、檔案被竄改；" +
                    "\n   剛推上新版的幾分鐘內 GitHub 快取也可能新舊混雜，稍候再試。");
            }
            foreach (string[] f in Files)
            {
                string dst = Path.Combine(dir, f[0]);
                if (File.Exists(dst)) File.Delete(dst);
                File.Move(Path.Combine(dir, f[0] + ".part"), dst);
            }
            Say("完成（SHA256 已核對）", ConsoleColor.Green);
            ready = true;
        }
        catch (Exception ex)
        {
            Say("失敗", ConsoleColor.Red);
            Console.WriteLine("   " + ex.Message);
            foreach (string[] f in Files) TryDelete(Path.Combine(dir, f[0] + ".part"));
        }
        finally
        {
            TryDelete(sumTmp);
        }

        if (!ready)
        {
            Console.WriteLine();
            if (integrityFailed)
            {
                // 核對失敗不是「沒下載到」，而是「下載到的東西不對」：不改用舊副本，也不執行任何東西
                Say(" 完整性檢查沒通過，什麼都沒有執行；上次留下的副本也沒有被覆蓋。", ConsoleColor.Red);
                Console.WriteLine(" 這種情況不會改用舊副本（--use-cached 只在「下載失敗」時才有效）。");
                Console.WriteLine(" 請先查清楚原因：換個網路、關掉代理再試，或手動下載整個 WINDOWS 資料夾比對。");
            }
            else if (!AllCached(dir))
            {
                Say(" 沒有完整的主腳本與視窗面板副本，無法繼續。", ConsoleColor.Red);
                Console.WriteLine(" 請確認這台電腦能連上 GitHub，或手動下載整個 WINDOWS 資料夾、雙擊 Win_Admin_Tool.bat。");
            }
            else if (!useCached)
            {
                Say(" 這台有一份 " + File.GetLastWriteTime(main) + " 的舊副本，但沒有重新下載就不會用它。", ConsoleColor.Yellow);
                Console.WriteLine(" 舊副本可能不是最新版。確定要用，就從命令列加 --use-cached 重跑（或設 OPS_USE_CACHED=1）。");
            }
            else
            {
                Say(" 改用 " + File.GetLastWriteTime(main) + " 的舊副本（--use-cached）", ConsoleColor.Yellow);
                ready = true;
            }
        }

        if (!ready)
        {
            Console.WriteLine();
            WaitEnter();
            return 1;
        }
        if (noLaunch) return 0;

        // 和 ops-win.ps1 同一種開法：STA + -File（提權、背景工作都要靠主腳本的實體路徑）。
        // 隱藏主控台用 powershell 自己的 -WindowStyle Hidden；這裡的 WindowStyle 不能設 Hidden，
        // 否則 Windows 會把這個行程第一個顯示的視窗（也就是主面板）也藏起來。
        try
        {
            ProcessStartInfo psi = new ProcessStartInfo("powershell.exe",
                "-NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File \"" + main + "\"");
            psi.UseShellExecute = true;
            psi.WorkingDirectory = dir;
            Process.Start(psi);
        }
        catch (Exception ex)
        {
            Say(" 開不起主面板：" + ex.Message, ConsoleColor.Red);
            WaitEnter();
            return 2;
        }
        Console.WriteLine();
        Console.WriteLine(" 主面板開啟中，這個視窗會自己關掉。");
        Thread.Sleep(2000);
        return 0;
    }

    // 出錯時停在畫面上讓人看訊息；從腳本或 SSH 執行（輸入被導向）時沒有人能按 Enter，不等
    static void WaitEnter()
    {
        try { if (Console.IsInputRedirected) return; } catch { }
        Console.Write(" 按 Enter 關閉 ... ");
        try { Console.ReadLine(); } catch { }
    }

    // SHA256（先把 CRLF 換成 LF）：GitHub raw 給 LF，本機或鏡像可能是 CRLF，統一後兩邊都對得上
    static string LfSha256(string path)
    {
        byte[] b = File.ReadAllBytes(path);
        MemoryStream ms = new MemoryStream(b.Length);
        for (int i = 0; i < b.Length; i++)
        {
            if (b[i] == 13 && i + 1 < b.Length && b[i + 1] == 10) continue;
            ms.WriteByte(b[i]);
        }
        using (SHA256 sha = SHA256.Create())
        {
            StringBuilder sb = new StringBuilder();
            foreach (byte x in sha.ComputeHash(ms.ToArray())) sb.Append(x.ToString("x2"));
            return sb.ToString();
        }
    }

    static bool HeadContains(string path, string needle)
    {
        using (StreamReader r = new StreamReader(path, Encoding.UTF8, true))
        {
            for (int i = 0; i < 5; i++)
            {
                string line = r.ReadLine();
                if (line == null) break;
                if (line.Contains(needle)) return true;
            }
        }
        return false;
    }

    static bool AllCached(string dir)
    {
        foreach (string[] f in Files) if (!File.Exists(Path.Combine(dir, f[0]))) return false;
        return true;
    }

    static void TryDelete(string path)
    {
        try { if (File.Exists(path)) File.Delete(path); } catch { }
    }
}
