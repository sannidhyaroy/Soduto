<div align="center">
  <img src="Soduto/Assets.xcassets/AppIcon.appiconset/1024.png" alt="Soduto Logo" width="200"/>
  <h1 style="font-weight: 700; font-size: 4em; margin: 0; padding-top: 0;">Soduto</h1>
  <div style="margin-bottom: 1em">
  <a href="https://github.com/sannidhyaroy/soduto/blob/nightly/LICENSE"><img src="https://img.shields.io/github/license/sannidhyaroy/soduto.svg" alt="GNU Licensed"></a>
  <a href="https://github.com/sannidhyaroy/soduto/issues"><img alt="GitHub issues" src="https://img.shields.io/github/issues/sannidhyaroy/soduto"></a>
  <a href="https://github.com/sannidhyaroy/soduto/commits/nightly"><img src="https://img.shields.io/github/last-commit/sannidhyaroy/soduto/nightly" alt="Last Commit"></a>
  <a href="https://github.com/sannidhyaroy/soduto/releases/latest"><img alt="GitHub Release Date" src="https://img.shields.io/github/release-date/sannidhyaroy/soduto"></a>
  </div>
  <p>
  Soduto is a KDE Connect compatible application for macOS. It allows better integration between your phones, desktops and tablets. For more information take a look at <a href="https://www.soduto.com">soduto.com</a>
  </p>
</div>

## Installation

The official build of Soduto can be downloaded from [soduto.com](https://www.soduto.com). To install, open the downloaded `.dmg` file and drag `Soduto.app` onto Applications folder.

There is also a (unofficial) Homebrew formulae, that can install Soduto with such command:

```bash
brew install --cask soduto
```
Since, Soduto is open-sourced, there are many forks of it on GitHub. You can download my forked version of Soduto from the [Releases Page](https://github.com/sannidhyaroy/soduto/releases/latest) of this Repository.

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

## Debugging

* To see logged messages of Release build of Soduto:
    * Open `Console.app`
    * On Action menu select "Include Debug Messages"
    * In Search field enter "process:Soduto category:CleanroomLogger"

* To switch logging level in `Terminal.app` run command (with `<level>` being an integer between 1 and 5, 1 being the most verbose and 5 - the least):

    `defaults write com.soduto.Soduto com.soduto.logLevel -int <level>`
    
    It is highly recommended to enable verbose logging levels only during debugging as sensitive data may be logged in plain text (like passwords copied into a clipboard)
