<div align="center">
  <img src="Soduto/Assets.xcassets/AppIcon.appiconset/1024.png" alt="Soduto Logo" width="200"/>
  <h1 style="font-weight: 700; font-size: 4em; margin: 0; padding-top: 0;">Soduto</h1>
  <div style="margin-bottom: 1em">
  <a href="https://github.com/sannidhyaroy/soduto/blob/nightly/LICENSE"><img src="https://img.shields.io/github/license/sannidhyaroy/soduto.svg?color=B0BB88&style=flat-square" alt="GNU Licensed"></a>
  <a href="https://github.com/sannidhyaroy/soduto/issues"><img alt="GitHub issues" src="https://img.shields.io/github/issues/sannidhyaroy/soduto?color=B0BB88&style=flat-square"></a>
  <a href="https://github.com/sannidhyaroy/soduto/commits/nightly"><img src="https://img.shields.io/github/last-commit/sannidhyaroy/soduto/nightly?color=B0BB88&style=flat-square" alt="Last Commit"></a>
  <a href="https://github.com/sannidhyaroy/soduto/releases/latest"><img alt="GitHub Release Date" src="https://img.shields.io/github/release-date/sannidhyaroy/soduto?color=B0BB88&style=flat-square"></a>
  <a href="https://github.com/sannidhyaroy/soduto/releases"><img alt="GitHub Release Downloads" src="https://img.shields.io/github/downloads/sannidhyaroy/soduto/total?color=B0BB88&style=flat-square"></a>
  </div>
  <p>
  Soduto is a KDE Connect compatible application for macOS. It allows better integration between your phones, desktops and tablets. For more information take a look at <a href="https://www.soduto.com">soduto.com</a>
  </p>
</div>

---
## **Navigation**
- [Installation](#installation)
- [Features](#features)
- [Building](#building)
- [Debugging](#debugging)
- [Verifying Downloads](#verifying-downloads)
  - [Signing Identity](#-signing-identity)
  - [Verification Steps](#verification-steps)
- [Limitations](#limitations)
  - [Clipboard Sync (Android 10+)](#clipboard-sync-android-10)
  - [Storage Access (Android 11+)](#storage-access-android-11)
  - [Sensitive Notification Content (Android 15+)](#sensitive-notification-content-android-15)
- [Workarounds](#workarounds)
  - [Clipboard Sync (Android 10+)](#clipboard-sync-android-10-1)
  - [Storage Access (Android 11+)](#storage-access-android-11-1)
  - [Sensitive Notification Content (Android 15+)](#sensitive-notification-content-android-15-1)
- [Troubleshooting](#troubleshooting)
- [Documentation & Resources](#documentation--resources)
- [Get in touch](#get-in-touch)
- [FAQ](#faq)
- [License](#license)
---
## Installation

To install builds of Soduto from this repository, head to the [Releases Page](https://github.com/sannidhyaroy/soduto/releases/latest) and download the [`.dmg`](https://github.com/sannidhyaroy/Soduto/releases/latest/download/Soduto.Nightly.dmg) file. As an optional step, you may head over to the [Verifying Downloads](#verifying-downloads) section if you wish to verify its integrity and cryptographic signature. Open it and you might get a pop-up window containing the license. Tap agree if you've read it and wish to continue. Then drag `Soduto.app` onto the Applications Folder. When running for the first time, you might get a prompt saying that macOS can't run apps from an unidentified developer. Pick any one of the following options to continue:
- Go to `System Preferences → Privacy & Security` and find `Soduto` was blocked message, then tap `Open Anyway` and follow the on-screen instructions.
- Remove the quarantine flag from the downloaded [`.dmg`](https://github.com/sannidhyaroy/Soduto/releases/latest/download/Soduto.Nightly.dmg) file before opening it: 
  ```bash
  xattr -d com.apple.quarantine <path to your dmg directory>/Soduto.Nightly.dmg
  ```
- On macOS (14) Sonoma and earlier, you can press and hold `control` and click on the app icon. While still holding `Control`, select `Open`.

The official build of Soduto can be downloaded from [soduto.com](https://www.soduto.com) or from [Soduto's official repository](https://github.com/soduto/Soduto). You may find support for the official build in [Soduto's official repository](https://github.com/soduto/Soduto), so only post issues [here](https://github.com/sannidhyaroy/Soduto/issues) related to the builds of this repository.

Please note that currently there's no brew cask for Soduto builds of this repository and the only source is the [Releases Page](https://github.com/sannidhyaroy/soduto/releases/latest) of this repository. Installation is a one-time process, and future upgrades are handled in-app using [Sparkle](https://sparkle-project.org/).

---
## Features

Soduto implements the following KDE Connect plugin features (compatible with any KDE Connect device):

### Notifications
- [x] Receive — Mirror remote device notifications on macOS (with automatic OTP copying)
- [ ] Send — Send macOS notifications to remote devices

### Clipboard
- [x] Receive — Receive clipboard content from remote devices
- [x] Send — Send macOS clipboard content to remote devices

### File Sharing
- [x] Receive — Receive shared files, links, and text from remote devices (files are saved in the Downloads folder)
- [x] Send — Share files, links, and text to remote devices via Share extension, drag and drop to menu bar, or `Send Files` option
- [x] Browse storage — Access remote device filesystem via SFTP

### Battery Status
- [x] Receive — View remote device battery level and charging status
- [x] Send — Send macOS battery status to remote devices

### Media Control (MPRIS)
- [x] Receive — Control remote device music/video playback from macOS Control Center and Now Playing Module (experimental)
- [ ] Send — Control macOS music/video playback from remote devices

### Telephony
- [x] Receive — View incoming call and SMS notifications from remote devices

### SMS Window
- [ ] Receive — View SMS of remote devices
- [x] Send — Send SMS from macOS

### Remote Input
- [x] Receive — Use remote device as keyboard and touchpad for macOS
- [x] Send — Use macOS to control remote device input (experimental)

### Ping
- [x] Receive — Receive ping messages from remote devices
- [x] Send — Send ping messages to remote devices

### Run Commands
- [x] Receive — Execute macOS commands from remote devices
- [ ] Send — Execute predefined commands on remote devices

### Find My Device
- [x] Receive — Make macOS play an alarm sound to locate it
- [x] Send — Make remote device play an alarm sound to locate it

### Connectivity Report
- [x] Receive — Monitor remote device network connectivity status

### Presentation Remote
- [x] Receive — Use remote device as presentation remote for macOS
- [ ] Send — Use macOS as presentation remote for remote device

### Contacts
- [x] Receive — Synchronize contacts between macOS and remote devices

### System Integration
- [ ] Screensaver Inhibit — Prevent macOS screensaver when device is connected
- [ ] Call Pause — Automatically pause macOS media during device calls

For the complete list of KDE Connect features and documentation, visit the [official KDE Connect Wiki](https://userbase.kde.org/KDEConnect).

---
## Building

- Clone this repo:

  ```bash
  git clone git@github.com:sannidhyaroy/Soduto.git Soduto && cd Soduto
  ```
  <details><summary>Clone using HTTPS? 👀</summary>

  Run this command, instead of the above one:
    ```bash
    git clone https://github.com/sannidhyaroy/Soduto.git Soduto && cd Soduto
    ```

  </details>

- Open project `Soduto.xcodeproj` with Xcode (select the Soduto Project menu in Xcode Project Navigator).
  - Swift Package dependencies (`swift-certificates`, `SwiftNIO`, `NIOSSL`, `NIOSSH`, `Citadel`, `Sparkle`, etc.) will resolve automatically on first build.
- Select `Soduto` as Target. Go to `Signing & Capabilities` and under the `Signing` section, ensure your appropriate `Team` is selected.
- Make sure you have the same `App Group key` for `Soduto Share` and also verify that the same `Team` is selected for each target.
- Build target `Soduto`

---
## Debugging

Soduto uses Apple's Unified Logging system (`os.Logger`). Logs are organized by subsystem and categories:

| Target | Subsystem | Categories |
|--------|-----------|------------|
| **Soduto** | `com.soduto.Soduto` | `general`, `network`, `device`, `config`, `services`, `ui` |
| **Soduto Files** | `com.soduto.Soduto-Files` | `general`, `filesystem`, `ui` |
| **Soduto Share** | `com.soduto.Soduto.Soduto-Share` | `general`, `sharing`, `ui` |

### View logs in real-time:
```bash
# Show all messages (debug, info, notice, error) for Soduto
log stream --predicate 'subsystem == "com.soduto.Soduto"' --level debug

# Show all messages for Soduto Files
log stream --predicate 'subsystem == "com.soduto.Soduto-Files"' --level debug

# Show all messages for Soduto Share
log stream --predicate 'subsystem == "com.soduto.Soduto.Soduto-Share"' --level debug

# Show all messages from ALL Soduto components
log stream --predicate 'subsystem BEGINSWITH "com.soduto.Soduto"' --level debug

# Show only info and above (excludes debug logs) for Soduto
log stream --predicate 'subsystem == "com.soduto.Soduto"' --level info
```

The `--level debug` flag shows messages at debug level **and above** (info, notice, error, fault).

### Enable debug message persistence:
By default, debug messages are only kept in memory and not saved to disk. To persist them:

```bash
# Enable debug persistence for main app
sudo log config --subsystem com.soduto.Soduto --mode level:debug

# Enable debug persistence for file browser
sudo log config --subsystem com.soduto.Soduto-Files --mode level:debug

# Enable debug persistence for share extension
sudo log config --subsystem com.soduto.Soduto.Soduto-Share --mode level:debug
```

This allows you to view debug messages in Console.app after they occur. To revert to default behavior:

```bash
# Revert main app
sudo log config --subsystem com.soduto.Soduto --mode level:default

# Revert file browser
sudo log config --subsystem com.soduto.Soduto-Files --mode level:default

# Revert share extension
sudo log config --subsystem com.soduto.Soduto.Soduto-Share --mode level:default
```

### View logs in the Console:
- Open `Console.app`
- In the search field, enter the subsystem for the target you want to view:
  - `subsystem:com.soduto.Soduto` - Main app
  - `subsystem:com.soduto.Soduto-Files` - File browser
  - `subsystem:com.soduto.Soduto.Soduto-Share` - Share extension
  - `subsystem BEGINSWITH com.soduto.Soduto` - All components
- Filter by category for targeted debugging:
  - `category:network`, `category:services`, `category:device` (main app)
  - `category:filesystem` (file browser)
  - `category:sharing` (share extension)
- Enable "Include Debug Messages" in the Action menu to see debug-level logs

**Warning:** Debug logging may include sensitive data (clipboard contents, passwords). Only enable its persistence during debugging and revert to default when done.

---
## Verifying Downloads
All releases published onwards `v2.0.0` in this repository are cryptographically signed.
This allows you to verify that a downloaded release was published by the Soduto project and was not modified after publication.

This step is **optional** and intended for users who want additional security guarantees.

- The signing key is **not stored in this repository**.
- The canonical source of truth for the signing key is the project domain.
- The same key is discoverable automatically via standard OpenPGP mechanisms.
- The DMG itself is not signed with GPG. Instead, the checksum file is signed to verify authenticity and integrity.
- Sparkle handles update security separately.
- Most users do not need to perform these steps, unless they wish to manually verify downloads.


### 🔑 Signing Identity
**Signed by**: _Soduto Releases (Soduto Release Signing Key)_ _`releases@soduto.thenoton.com`_

**Key fingerprint:** _`4951 D786 1266 F77E A86D  2B3C D952 D26C 5D6D 9D22`_

You can use the fingerprint above to manually verify that you have obtained the correct public key.

### Verification steps:
- The easiest way is to let GPG locate the key automatically.
  ```bash
  gpg --locate-keys releases@soduto.thenoton.com
  ```

  <details><summary>Not Working? 🥲</summary>

  #### Try any of the following methods:

  - Force **Web Key Directory (WKD)** (recommended):
    ```bash
    gpg --locate-keys --auto-key-locate wkd releases@soduto.thenoton.com
    ```
  - Force a **public keyserver lookup** (email-verified at [keys.openpgp.org](https://keys.openpgp.org)):
    ```bash
    gpg --locate-keys --keyserver hkps://keys.openpgp.org releases@soduto.thenoton.com
    ```
  - Final fallback - manual import:
    ```bash
    curl -o soduto-release-signing-key.asc https://raw.githubusercontent.com/sannidhyaroy/soduto-releases/refs/heads/main/.well-known/openpgpkey/hu/i4cdqgcarfjdjnba6y4jnf498asg8c6p
    gpg --import soduto-release-signing-key.asc
    ```

  </details>
- Download the [`.dmg`](https://github.com/sannidhyaroy/Soduto/releases/latest/download/Soduto.Nightly.dmg) file, the [`.dmg.sha256`](https://github.com/sannidhyaroy/Soduto/releases/latest/download/Soduto.Nightly.dmg.sha256) file and the [`.dmg.sha256.asc`](https://github.com/sannidhyaroy/Soduto/releases/latest/download/Soduto.Nightly.dmg.sha256.asc) file.
- Open the directory where you downloaded the `.dmg` file, and run the following commands:
  ```bash
  gpg --verify Soduto-X.Y.Z.dmg.sha256.asc  # Enter correct path to the .dmg.sha256.asc file
  shasum -a 256 -c Soduto-X.Y.Z.dmg.sha256  # Enter correct path to the .dmg.sha256 file
  ```
  Expected output includes:
  ```
  Good signature from "Soduto Releases <releases@soduto.thenoton.com>"
  ```
  This confirms that:
  - The checksum file (`.dmg.sha256`) was signed by the Soduto Release Signing Key.
  - The downloaded `.dmg` matches the published SHA-256 checksum.

---
## Limitations

#### Clipboard Sync (Android 10+)
Google introduced privacy restrictions on Android 10 and higher that prevent apps from accessing clipboard data unless the app is the default input method editor (IME) or is currently in focus. This affects seamless clipboard sync between KDE Connect and Soduto. Your clipboard will automatically sync to your other devices when you copy something on your mac, however you will have to manually tap on `Send Clipboard` in the KDE Connect app every time you want to sync your Android's clipboard to your mac.

#### Storage Access (Android 11+)
On Android 11 and higher, you may not be able to add the root location of your Internal Storage or your Download folder to KDE Connect's `Filesystem expose` locations due to Google's privacy changes.

#### Sensitive Notification Content (Android 15+)
On Android 15 and higher, the system hides sensitive notification content (such as passwords, OTPs, and other sensitive information) from applications by default. This means Soduto will display "Sensitive notification content hidden" instead of the actual content. This restriction also affects automatic OTP copying in Soduto. KDE Connect will not receive sensitive notifications unless you explicitly grant the `RECEIVE_SENSITIVE_NOTIFICATIONS` permission (see workarounds below).

---
## Workarounds

#### Clipboard Sync (Android 10+)
If you have `Riru` or `Zygisk`, you can bypass the clipboard restriction on Android 10 or higher by using [Kr328's Clipboard Whitelist](https://github.com/Kr328/Riru-ClipboardWhitelist) module and then tick `KDE Connect`/`Zorin Connect` from the `Clipboard Whitelist` app. If you're on Android 13 and the module isn't working for you, try [Xposed Clipboard Whitelist](https://github.com/GamerGirlandCo/xposed-clipboard-whitelist) (remember to select `System Framework` for the module scope). You need to have `Xposed Framework` for the `Xposed Clipboard Whitelist` module to work.

#### Storage Access (Android 11+)
[NoStorageRestrict](https://github.com/Xposed-Modules-Repo/com.github.dan.nostoragerestrict) is an `Xposed Module` that removes the restriction when selecting folders(like Internal Storage, Android, Download, data, obb) through file manager on Android 11 and higher. There is a [Magisk module](https://github.com/DanGLES3/NoStorageRestrict) for this as well but I haven't tested the Magisk Module version yet, so use it at your own risk ⚠️.

#### Sensitive Notification Content (Android 15+)
The recommended approach is to grant KDE Connect the `RECEIVE_SENSITIVE_NOTIFICATIONS` permission using ADB (Android Debug Bridge). This will allow sensitive notifications to be delivered normally and enable automatic OTP copying.

- **Set up ADB** — Follow the [official Android ADB setup guide](https://developer.android.com/tools/adb).

- **Connect your device** — Connect your phone via USB or wireless ADB.

- **Grant the permission** — Run this command:
  ```bash
  adb shell cmd appops set --user 0 org.kde.kdeconnect_tp RECEIVE_SENSITIVE_NOTIFICATIONS allow
  ```

- **If permission monitoring error occurs** — If you see this error, follow these steps:
  ```
  java.lang.SecurityException: uid 2000 does not have android.permission.MANAGE_APP_OPS_MODES
  ```
   - Go to Developer Options and enable "Disable permission monitoring"
   - Reboot your phone
   - Run the ADB command again

- **Reboot** — Reboot your phone for the changes to take effect.

After completing these steps, sensitive notifications (including OTPs) will be delivered to Soduto, and automatic OTP copying will work as expected.

---
## Troubleshooting

### 1. Soduto Share doesn't show up in the share sheet

Go to `System Preferences → General → Login Items & Extensions → Sharing` info button, and ensure `Soduto Share` toggle is enabled. If you still have issues, keep reading.


<details><summary>On macOS (14) Sonoma and earlier?</summary>
<p>

Go to `System Preferences → Privacy & Security → Extensions → Sharing`, and ensure `Soduto Share` is checked. If you still have issues, keep reading.

</p>
</details> 

If `Soduto Share` doesn't appear in the share menu, only when multiple files are selected, macOS may have cached a stale extension registration. To fix this:
  1. Check for stale plugin registrations:
     ```bash
     pluginkit -m -Dv -i com.soduto.Soduto.Soduto-Share
     ```
  2. If multiple entries appear (or entries pointing to non-existent paths), remove them:
     ```bash
     pluginkit -r "<path shown in the output>"
     ```
  3. Restart your Mac, then open Soduto. The extension should re-register automatically with the correct rules.

### 2. SSL certificate errors after re-pairing

If you see SSL/TLS certificate errors in Console.app after re-pairing your device, the remote device is rejecting Soduto's certificate.

```
Connection error: NIOSSL.NIOSSLError.handshakeFailed(NIOSSL.BoringSSLError.sslError([Error: 268436502 error:10000416:SSL routines:OPENSSL_internal:SSLV3_ALERT_CERTIFICATE_UNKNOWN at /Users/sannidhyaroy/Library/Developer/Xcode/DerivedData/Soduto-djazogzlahmuayfoqwqoflmgulsi/SourcePackages/checkouts/swift-nio-ssl/Sources/CNIOBoringSSL/ssl/tls_record.cc:484]))
```

This `SSLV3_ALERT_CERTIFICATE_UNKNOWN` error means the remote device is rejecting Soduto's certificate as "unknown"

<details><summary>Click here for Legacy versions (CocoaAsyncSocket)</summary>
<p>

```
socketDidDisconnect(<<GCDAsyncSocket: 0x...>> withError:<Error Domain=kCFStreamErrorDomainSSL Code=-9829 "(null)" UserInfo={NSLocalizedRecoverySuggestion=Error code definition can be found in Apple's SecureTransport.h}>)
```

This is error code -9829 (`errSSLPeerCertUnknown`), which means the remote device is rejecting Soduto's certificate as "unknown"

</p>
</details> 

**When does this happen?**

This occurs when Soduto's keychain entries are cleared (manually or by reinstalling) but the app's preferences remain. Soduto generates a new SSL certificate with the same device ID but different cryptographic content. The remote KDE Connect app has cached the old certificate and rejects the new one as a mismatch.

**Symptoms:**
- Device pairing appears to succeed
- Main connection works initially
- Secondary connections fail (file transfers, notification icons, etc.)
- The paired device may disconnect and fail to reconnect after restarting Soduto

**Note:** With the current SwiftNIO implementation, previously paired devices usually reconnect successfully despite this error appearing in logs. However, devices that were paired before the certificate was regenerated and never re-paired will not connect.

**Why does this happen?**

Soduto and KDE Connect use SSL/TLS with self-signed certificates to secure communications. Each device stores the other's certificate during pairing. KDE Connect on Android caches certificate data aggressively, and this cache persists even after unpairing. When Soduto presents a new certificate (same device ID, different key), KDE Connect's cached data causes validation to fail.

**Solution:**

1. Unpair the device from both Soduto (on Mac) and KDE Connect (on Android/Linux)
2. On Android: Go to `Settings → Apps → KDE Connect → Storage → Clear Cache`
   - Note: Clear **cache** only, not app data (clearing app data will remove all your KDE Connect settings)
3. On Mac (optional): Remove Soduto's preferences to get a fresh device ID:
> [!CAUTION]
>  Running the following command is optional and dangerous as it will delete your saved Soduto Preferences. Only run when you absolutely want a fresh device ID and are fine with reconfiguring lost preferences
> ```bash
> defaults delete com.soduto.Soduto
> ```
4. Re-pair the devices

After clearing the cache, the new certificate will be accepted and cached correctly.

---
## Documentation & Resources

For comprehensive information about KDE Connect features, limitations, configuration, and troubleshooting across all platforms, visit the [official KDE Connect Wiki](https://userbase.kde.org/KDEConnect). While the wiki primarily focuses on Linux environments, a lot of the information will still be useful for macOS and Android.

---
## Get in touch
To ask a question, offer suggestions or share an idea, please use the [discussions tab](https://github.com/sannidhyaroy/soduto/discussions) of this repository.

If you spot any bugs or vulnerabilities, please [create an issue](https://github.com/sannidhyaroy/soduto/issues/). It's always a good idea to make sure there aren't any similar issues open, before creating a new one!

---
## FAQ

### Is this the official version of Soduto?

No, this is not the official version of Soduto. Head over to their [official site](https://www.soduto.com) or [GitHub Repo](https://github.com/soduto/soduto) for the official version.

### Why another version of Soduto?

The development for the official version seems to have been inactive for a very long time. Thus, a lot of Soduto's features were broken on recent versions of macOS. This is why, I have tried to replace some deprecated code in my repo.

### Is this app safe? Why does macOS show a warning when opening Soduto for the first time?

The code is public, so instead of taking someone else's word for it, it's better to review it yourself if the app is safe.

The reason macOS shows a prompt saying that this app is from an unidentified developer is because I have a free Apple Developer Account and not a paid one, thus the builds of Soduto released by me are not notarized. If you build the app yourself for your own mac, you won’t get the warning. Head over to the [building](#building) section to do so.

### Why is the app not notarized?

Developers can't send an app for notarization with a free Apple Developer Account. I am a student and developing apps for the Apple Platform is neither my job nor my hobby. Neither can I nor do I want to pay Apple a hefty amount of $99 every year for the privilege of developing apps for their platform.

### Why is this not on the Mac App Store?

Same as above. I also don't want to have to go through their app review process.

---
## License

Soduto is licensed under the [GNU General Public License v3.0](https://github.com/sannidhyaroy/soduto/blob/nightly/LICENSE).
