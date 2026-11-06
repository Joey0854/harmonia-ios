# HeSuVi Music

[English](README.md)

給 iPhone 用的 YouTube Music 播放器。不需要電腦就能自己播放，螢幕關閉也會持續播放，
並顯示在鎖定畫面與 CarPlay 的「正在播放」。

> **支援平台：** 只有 iPhone（iOS 16 以上）。**沒有 Android 版（沒有 APK）**，詳見 [Android](#android)。

## 功能

- 瀏覽、搜尋 YouTube Music；可選擇登入，取得自己的首頁、喜歡的歌曲與播放清單。
- 自己播放：App 內建 [yt-dlp](https://github.com/yt-dlp/yt-dlp)。
- 背景播放、鎖定畫面、控制中心、CarPlay「正在播放」。
- 環繞音效（耳機脈衝響應）、5 段等化器、音量平衡。
- 歌曲之間自動混音。
- 下載歌曲到手機；手機上的播放歷史；登入後播放紀錄也會送到 YouTube Music 的歷史。
- 選用：用藍牙 LE 讓車上的氛圍燈跟著音樂變化（需要相容的控制器）。

## 在 iPhone 上安裝

App **不在 App Store**。請到 [Releases](../../releases) 下載 `.ipa`，用側載工具和你自己的 Apple ID 安裝。

**需要：** iOS 16 以上的 iPhone、USB 線、一台 Windows 電腦或 Mac、一個 Apple ID。
免費 Apple ID 可以用，但 App **7 天後會過期**，要重新安裝（付費開發者帳號則為一年）。

### 方法 A：Sideloadly（Windows 或 macOS）

1. 到 Apple 官網安裝 **iTunes** 和 **iCloud for Windows**（Microsoft Store 版本不能搭配 Sideloadly）。
   Mac 不需要額外安裝。
2. 安裝 [Sideloadly](https://sideloadly.io/)。
3. 從最新的 [Release](../../releases/latest) 下載 `YTMRemote.ipa`。
4. 用線連接 iPhone，在手機上按「信任」。
5. 在 iPhone 開啟**開發者模式**：設定 > 隱私權與安全性 > 開發者模式（手機會重新啟動）。
   如果還看不到這個選項，先做第 6 步再回來。
6. 開啟 Sideloadly，把 `.ipa` 拖進去，選擇你的 iPhone，輸入 Apple ID，按 **Start**，
   需要時輸入密碼。帳號與密碼只輸入在 Sideloadly 自己的視窗。
7. 在 iPhone：設定 > 一般 > **VPN 與裝置管理** > 你的 Apple ID > **信任**。
8. 開啟 App。

### 方法 B：AltStore（Windows 或 macOS）

1. 在電腦安裝 [AltServer](https://altstore.io/)，並用它把 **AltStore** 裝到 iPhone（照 AltStore 官方說明）。
2. 把 `YTMRemote.ipa` 傳到 iPhone（AirDrop、檔案 App，或用 Safari 下載）。
3. 在 AltStore 開啟 **My Apps**，點 **+**，選擇 `.ipa`。
4. 做方法 A 的第 5、7 步（開發者模式、信任）。
5. 只要電腦上的 AltServer 開著，AltStore 會在背景自動續期。

### 第一次使用

1. 在首頁選一首歌。App 開啟後的第一首歌需要幾秒鐘查詢。
2. 選用：設定 > **YouTube Music 帳號** > 登入，取得自己的首頁、喜歡的歌曲與播放清單。
3. 選用：只有要用氛圍燈時才需要允許藍牙。

### 常見問題

| 症狀 | 處理方式 |
| --- | --- |
| 「未受信任的開發者」 | 設定 > 一般 > VPN 與裝置管理 > 信任 |
| App 一開就關閉，或找不到開發者模式 | 開啟開發者模式（第 5 步），再重新啟動手機 |
| 約一週後打不開 | 免費 Apple ID 7 天過期，重新安裝即可 |
| Sideloadly 找不到 iPhone | 重新安裝 Apple 官網版 iTunes、解鎖手機、按「信任」 |
| 歌曲播不出來 | 等約 10 秒（第一次查詢）；更新到最新 Release（YouTube 常常改版） |

### 求助時如何提供紀錄

用**兩根手指在畫面上連點三下**，會開啟紀錄畫面。按 **Copy** 或 **Share** 就能貼到訊息、
郵件或存成檔案。貼出去之前請先看過內容，裡面有你播放過的歌曲 ID 和標題。

## Android

**沒有 Android 版，也沒有 APK。** App 用到只有 iOS 才有的部分（系統音訊引擎、CarPlay、
藍牙 LE、內嵌 Python），無法直接改打包。Android 版會是另一個獨立專案，歡迎貢獻。

## 自行編譯

見 [docs/DEVELOPMENT.md](docs/DEVELOPMENT.md)。每次 push 時 CI 會建出未簽名的 ipa；
推送像 `v1.0.0` 這樣的 tag 會自動發佈成 Release。

## 法律

MIT 授權，見 [LICENSE](LICENSE) 與 [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)。
本 App 與 YouTube、Google、Apple 無任何關聯。從 YouTube 讀取音訊可能違反 YouTube 服務條款，
請自行承擔風險，且僅供個人使用。
