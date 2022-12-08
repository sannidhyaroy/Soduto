# Soduto

## What is it?

Soduto is a KDEConnect compatible application for macOS. It allows better integration between your phones, desktops and tablets.
For more information take a look at [soduto.com](https://www.soduto.com)

## Installation

Soduto application can be downloaded from [soduto.com](https://www.soduto.com). To install, open the downloaded .dmg file and drag 
Soduto.app onto Applications folder.

There is also a (unofficial) Homebrew formulae, that can install Soduto with such command:

```bash
brew install --cask soduto
```

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
* Build target `Soduto`

## Debugging

* To see logged messages of Release build of Soduto:
    * Open `Console.app`
    * On Action menu select "Include Debug Messages"
    * In Search field enter "process:Soduto category:CleanroomLogger"

* To switch logging level in `Terminal.app` run command (with `<level>` being an integer between 1 and 5, 1 being the most verbose and 5 - the least):

    `defaults write com.soduto.Soduto com.soduto.logLevel -int <level>`
    
    It is highly recommended to enable verbose logging levels only during debugging as sensitive data may be logged in plain text (like passwords copied into a clipboard)
