# Orchard Explorer

Orchard Explorer is a native Mac file manager for people who feel at home in Windows File Explorer. Open several folders in tabs, browse ZIP archives like folders, and use Finder tags to find files across locations. Home brings together your pinned folders, tags, and recent documents.

## Build and open

Use an Apple Silicon Mac running macOS 26.7.1 or later with Git and the Xcode Command Line Tools. The project has been built with Swift 6.4. The first build uses the network to fetch the pinned ZIPFoundation dependency.

If you already use Maxplorer, read [Upgrading from Maxplorer](docs/USAGE.md#upgrading-from-maxplorer) before building or launching Orchard Explorer. The two versions share a bundle identifier.

Clone this repository and build from the checkout.

```sh
bash app/build.sh release
```

The build uses an ad-hoc signature. For a fresh installation, move `app/dist/Orchard Explorer.app` to Applications and open it there. To run a development build directly from its build folder, use `open "app/dist/Orchard Explorer.app"`.

## Find your way around

| To | In Orchard Explorer |
| --- | --- |
| Open a folder by path | Press **⌘L**, enter the path, and press **Return**. |
| Open a second location | Press **⌘T** for a new Home tab, then choose a folder. |
| Search for a filename | Press **⌘F** and choose whether to include subfolders. |
| Extract part of a ZIP | Open the ZIP, copy the entries you want, and paste into a regular folder. |
| Keep a OneDrive file offline | Right-click an eligible file and choose **Always Keep on This Device**. |

For keyboard shortcuts, file recovery, cloud status, and setup for “Show in Finder,” see the [usage guide](docs/USAGE.md). For tests and pull requests, see [Contributing](CONTRIBUTING.md).

## License

Orchard Explorer uses the [MIT License](LICENSE). The [ZIPFoundation notice](app/ThirdPartyNotices/ZIPFoundation-LICENSE.txt) accompanies the app.
