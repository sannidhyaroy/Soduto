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
- [Building](#building)
- [Debugging](#debugging)
- [Limitations](#limitations)
- [Workarounds](#workarounds)
- [Get in touch](#get-in-touch)
- [FAQ](#faq)
- [License](#license)
---
## Installation

To install my forked version of Soduto, head to the [Releases Page](https://github.com/sannidhyaroy/soduto/releases/latest) of this Repository and download the `.dmg` file from the latest build. Then open the downloaded `.dmg` file. You might get a pop-up window containing the license. Tap agree if you've read it and wish to continue. Then drag `Soduto.app` onto the Applications Folder. When running for the first time, you might get a prompt saying that macOS can't run apps from an unidentified developer. Press and hold `control` and click on the app icon. While still holding `Control`, select `Open`.

The official build of Soduto can be downloaded from [soduto.com](https://www.soduto.com) or from [Soduto's official repository](https://github.com/soduto/Soduto).

There is also a (unofficial) Homebrew formulae, that can install Soduto with such command:

```bash
brew install --cask soduto
```
Do note that currently there's no Homebrew formulae for my forked version and the only source is the [Releases Page](https://github.com/sannidhyaroy/soduto/releases/latest) of this repository.

---
## Building

* Clone this repo and update submodules

  `git clone && git submodule update --init`

* Install [Carthage](https://github.com/Carthage/Carthage#installing-carthage):

    `brew install carthage`
    
* Fetch and build frameworks using Carthage:
    
    `carthage update --platform macOS --use-xcframeworks`

* Compile universal openssl and libssh2 library using [iSSH2](https://github.com/Frugghi/iSSH2):

    `./build_lib.sh`

* Open project `Soduto.xcodeproj` with XCode
* Select `Soduto` as Target. Go to `Signing & Capabilities` and under the `App Groups` section, copy the `App Group key`.
* Open the `SharedUserDefaults.swift` file & paste the key in the `suiteName` variable.

    `static let suiteName = "<your key here>"`

* Make sure you have the same `App Group key` for `Soduto Share`.
* Build target `Soduto`

---
## Debugging

* To see logged messages of Release build of Soduto:
    * Open `Console.app`
    * On Action menu select "Include Debug Messages"
    * In Search field enter "process:Soduto category:CleanroomLogger"

* To switch logging level in `Terminal.app` run command (with `<level>` being an integer between 1 and 5, 1 being the most verbose and 5 - the least):

    `defaults write com.soduto.Soduto com.soduto.logLevel -int <level>`
    
    It is highly recommended to enable verbose logging levels only during debugging as sensitive data may be logged in plain text (like passwords copied into a clipboard).

---
## Limitations
- Google introduced some privacy changes on Android 10 and higher, that doesn’t allow apps to access clipboard data, unless the app is the default input method editor (IME) or is currently in focus. This will affect seamless clipboard sync between KDE Connect and Soduto. Your clipboard will automatically sync to your other devices when you copy something on your mac, however you will have to manually tap on `Send Clipboard` in the KDE Connect app, everytime you want to sync your android's clipboard to your mac.
- On Android 11 and higher, you may not be able to add the root location of your Internal Storage or your Download folder to KDE Connect's `Filesystem expose` locations due to Google's privacy changes.
- The Share Extension is currently buggy & doesn't provide support for sharing multiple files yet. Soduto Share won't appear in the share menu if multiple files are selected.

---
## Workarounds
- If you have `Riru` or `Zygisk`, you can bypass the clipboard restriction on Android 10 or higher by using [Kr328's Clipboard Whitelist](https://github.com/Kr328/Riru-ClipboardWhitelist) module and then tick `KDE Connect`/`Zorin Connect` from the `Clipboard Whitelist` app. If you're on Android 13 and the module isn’t working for you, try [Xposed Clipboard Whitelist](https://github.com/GamerGirlandCo/xposed-clipboard-whitelist) (remember to select `System Framework` for the module scope). You need to have `Xposed Framework` for the `Xposed Clipboard Whitelist` module to work.
- [NoStorageRestrict](https://github.com/Xposed-Modules-Repo/com.github.dan.nostoragerestrict) is an `Xposed Module` that removes the restriction when selecting folders(like Internal Storage, Android, Download, data, obb) through file manager on Android 11 and higher. There is a [Magisk module](https://github.com/DanGLES3/NoStorageRestrict) for this as well but I haven’t tested the Magisk Module version yet, so use it at your own risk ⚠️.
- To share multiple files, use the option to `Send Files` from the menu bar app options or drag & drop multiple selected files to the menu bar icon. As of now, Soduto Share only supports sharing one file at a time.

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

The reason macOS shows a prompt saying that this app is from an unidentified developer is because I have a free Apple Developer Account and not a paid one, thus the builds of Soduto released by me is not notarized. If you build the app yourself for your own mac, you won’t get the warning. Head over to the [building](#building) section to do so.

### Why is the app not notarized?

Developers can’t send an app for notarization with a free Apple Developer Account. I am a Student and developing apps for the Apple Platform is neither my job or my hobby. Neither I can or want to pay Apple, a hefty amount of $99 every year for the privilege of developing apps for their platform.

### Why is this not on the Mac App Store?

Same as above. I also don't want to have to go through their app review process.

---
## License

Soduto is licensed under the [GNU General Public License v3.0](https://github.com/sannidhyaroy/soduto/blob/nightly/LICENSE).
