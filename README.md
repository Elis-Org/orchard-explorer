# Maxplorer

Maxplorer is a native file manager for Apple Silicon Macs. Open several folders in tabs, browse ZIP archives like folders, and use Finder tags to find files across locations. Home brings together your pinned folders, tags, and recent documents.

## Build and open

Use an Apple Silicon Mac running macOS 26.7.1 or later with Git and the Xcode Command Line Tools. The project has been built with Swift 6.4. The first build uses the network to fetch the pinned ZIPFoundation dependency.

Clone this repository and run these commands from the checkout.

```sh
bash app/build.sh release
open app/dist/Maxplorer.app
```

The script creates a locally signed app. To keep it in Applications, quit Maxplorer and drag the built app there in Finder.

## Find your way around

| To | In Maxplorer |
| --- | --- |
| Open a folder by path | Press **⌘L**, enter the path, and press **Return**. |
| Open a second location | Press **⌘T** for a new Home tab, then choose a folder. |
| Search for a filename | Press **⌘F** and choose whether to include subfolders. |
| Extract part of a ZIP | Open the ZIP, copy the entries you want, and paste into a regular folder. |
| Keep a OneDrive file offline | Right-click an eligible file and choose **Always Keep on This Device**. |

For keyboard shortcuts, file recovery, cloud status, and setup for “Show in Finder,” see the [usage guide](docs/USAGE.md). For tests and pull requests, see [Contributing](CONTRIBUTING.md).
