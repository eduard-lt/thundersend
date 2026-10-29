# ThunderSend

Send folders between two Macs over a Thunderbolt cable.

Open ThunderSend on both Macs, connect them with a Thunderbolt (or USB4) cable, and the window shows the name of the other Mac. Choose a folder, or drop one onto the window, and it is copied to the other Mac's Downloads folder.

## Requirements

- Two Macs running macOS 14 or later
- A Thunderbolt or USB4 cable between them
- Thunderbolt Bridge enabled in System Settings > Network (it is on by default)

## Build

```sh
./build.sh
```

The app is created at `build/ThunderSend.app`. Copy it to both Macs.

The first time it opens, macOS asks for permission to find devices on the local network. Allow it, otherwise the other Mac cannot be found.

Since the app is not notarized, the first launch on another Mac needs a right-click on the app and then Open.

## How it works

- macOS turns the cable into a network link called Thunderbolt Bridge.
- ThunderSend only listens and looks for the other Mac on that link, never over Wi-Fi or Ethernet.
- The selected folder is streamed with the built-in `tar` tool and unpacked on the other side.
- Received items land in Downloads. If a folder with the same name already exists, the new one gets a number added instead of replacing it.

## Notes

- Anyone with a cable plugged into your Mac and ThunderSend open can send you files. Close the app when you are not using it.
- One transfer at a time.
