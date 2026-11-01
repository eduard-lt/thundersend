# ThunderSend

Send files and folders between two Macs over a Thunderbolt cable.

[![Download for Mac](https://img.shields.io/badge/Download_for_Mac-ThunderSend.dmg-2F5BEA?style=for-the-badge&logo=apple&logoColor=white)](https://github.com/eduard-lt/thundersend/releases/latest/download/ThunderSend.dmg)

[![Buy me a coffee on Ko-fi](https://img.shields.io/badge/Buy_me_a_coffee-Ko--fi-FF5E5B?logo=kofi&logoColor=white)](https://ko-fi.com/eduardolteanu)

Open ThunderSend on both Macs, connect them with a Thunderbolt (or USB4) cable, and the window shows the name of the other Mac. Choose files or folders, or drop them onto the window, and they are copied to the other Mac's Downloads folder.

Either Mac can cancel a running transfer. The window lists this session's transfers, so you can send something again or show it in Finder. The list clears when the app quits.

## Install

Do this on both Macs:

1. Download [ThunderSend.dmg](https://github.com/eduard-lt/thundersend/releases/latest/download/ThunderSend.dmg), open it and drag ThunderSend to Applications.
2. Open ThunderSend. macOS blocks it the first time, because the app is free and not notarized by Apple. Approve it one of two ways:
   - **System Settings:** go to System Settings > Privacy & Security, scroll down and click **Open Anyway**.
   - **Terminal:** run this command, then open the app again.

     ```sh
     xattr -cr /Applications/ThunderSend.app
     ```
3. When macOS asks to find devices on your local network, click **Allow**. Otherwise the other Mac cannot be found.

## Requirements

- Two Macs running macOS 14 or later
- A Thunderbolt or USB4 cable between them
- Thunderbolt Bridge enabled in System Settings > Network (it is on by default)

## How it works

- macOS turns the cable into a network link called Thunderbolt Bridge.
- ThunderSend only listens and looks for the other Mac on that link, never over Wi-Fi or Ethernet.
- The selected folder is streamed with the built-in `tar` tool and unpacked on the other side.
- Received items land in Downloads. If a folder with the same name already exists, the new one gets a number added instead of replacing it.

## Notes

- Anyone with a cable plugged into your Mac and ThunderSend open can send you files. Close the app when you are not using it.
- Transfers are not encrypted. They only travel over the cable between the two Macs.
- One transfer at a time.
- Use the same version on both Macs. Versions with a different transfer format do not work together.

## Build from source

Needs the Xcode Command Line Tools.

```sh
./build.sh   # creates build/ThunderSend.app
./dmg.sh     # creates build/ThunderSend.dmg
```

Pushing a tag such as `v1.0` builds the installer on GitHub and publishes it as a release.

## License

[MIT](LICENSE)
