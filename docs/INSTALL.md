# Build and install Orchard Explorer

Orchard Explorer is distributed as source. These steps build the app on your Mac and install it in Applications.

## What you need

- A Mac with Apple silicon running **macOS 26.7.1 or later**. You can check the chip and macOS version in **Apple menu → About This Mac**.
- Apple’s Command Line Tools for Xcode, or Xcode with its command-line tools selected. The release build has been verified with **Apple Swift 6.4**.
- An internet connection to clone the repository and fetch the pinned ZIPFoundation dependency on the first build.

If you haven’t installed the developer tools, open **Terminal** and run the following command. Click **Install** in the system dialog and wait for it to finish before continuing.

```sh
xcode-select --install
```

You can check the active toolchain with `swift --version`. [Apple’s Command Line Tools installation guide](https://developer.apple.com/documentation/xcode/installing-the-command-line-tools)

## Build the app

In Terminal, open the folder where you want to keep the source and run these commands. If you already cloned the repository, open its `orchard-explorer` folder and run just the last command.

```sh
git clone https://github.com/Elis-Org/orchard-explorer.git
cd orchard-explorer
bash app/build.sh release
```

When the build succeeds, the script prints `Built` followed by the full path to `app/dist/Orchard Explorer.app`. This is the app bundle you’ll install.

## Install and launch

1. From the same Terminal window, open the build output in Finder.

   ```sh
   open -a Finder app/dist
   ```

2. Drag **Orchard Explorer.app** onto **Applications** in the Finder sidebar. If you built the app on another disk, hold **Command** as you drag to move the bundle.
3. In Applications, double-click **Orchard Explorer**. Its first window opens on **Home**. [Try your first folder and tab](../README.md#get-started).
