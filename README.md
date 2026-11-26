# Orchard Explorer

Orchard Explorer is a native macOS file manager for people who like the way Windows File Explorer works. Browse folders in tabs, sort files in Details view, and press **F2** to rename a file. Your Finder tags and OneDrive files are available in the same window.

**[Build and install Orchard Explorer](docs/INSTALL.md)** on an Apple silicon Mac running macOS 26.7.1 or later.

## Get started

1. **Open a folder.** Launch Orchard Explorer from Applications. It opens on **Home**, where you’ll find Quick access and recent documents. Choose a folder in the sidebar, or press **⌘L**, type `~/Downloads`, and press **Return**.
2. **Work across two folders.** Press **⌘T** to open a second tab and navigate to a destination folder. To copy a file, select it in the first tab and press **⌘C**, then switch to the destination tab and press **⌘V**.
3. **Keep a folder handy.** In a folder you visit often, choose **Go → Pin Current Folder to Quick Access**. Its shortcut stays in the sidebar the next time you open the app.

## Features

- **Search by filename.** Press **⌘F** in a folder, enter a name, and press **Return**. Search just that folder or include its subfolders, then narrow the results by kind, date, or size.
- **Choose how to see your files.** Use Details view to sort by a column, or switch to icons, a list, or tiles. Select a file and press **⌘⌥P** to preview a PDF, image, or text document alongside the folder.
- **Organize with Finder tags.** Right-click files, choose **Tags…**, and apply a tag. **Home → Tags** brings together tagged files from different folders. The same tags appear in Finder.
- **Browse ZIPs like folders.** Open an archive, copy the entries you need, and paste them into a regular folder to extract them. To add files to a ZIP, paste them inside the archive.
- **Manage OneDrive storage.** Badges show which files are local or online-only. With OneDrive running, right-click a supported file and choose **Always Keep on This Device** to keep it offline or **Free Up Space** to release the local copy.
- **Recover trashed files.** Choose **File → Recently Trashed…** to restore eligible items you sent to the Trash from Orchard Explorer during the current session.

The [usage guide](docs/USAGE.md) covers keyboard shortcuts, file operations, and how to make Orchard Explorer handle “Show in Finder” requests from other apps. To run tests or submit a change, see [Contributing](CONTRIBUTING.md).

## License

Orchard Explorer uses the [MIT License](LICENSE). The [ZIPFoundation notice](app/ThirdPartyNotices/ZIPFoundation-LICENSE.txt) accompanies the app.
