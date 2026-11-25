# Using Orchard Explorer

## Navigate and find files

Launching Orchard Explorer opens **Home**, with Quick access and Recent. If you open a specific folder from Finder, Orchard Explorer opens that folder.

| Action | How |
| --- | --- |
| Open a location | Choose a sidebar folder, press **⌘O** to choose a folder, or press **⌘L** and enter a path. A document path opens in its macOS handler. |
| Complete a path | In the address editor, type an absolute or tilde-prefixed path. Use the arrow keys to highlight a suggestion, **Tab** to complete its name, **Return** to open it and **Esc** to cancel. |
| Navigate without typing | Click a breadcrumb to visit an ancestor or its chevron to choose a child. Use **⌘[** and **⌘]** for Back and Forward, **⌘↑** for the parent and **⌘R** to refresh. |
| Manage tabs | **⌘T** or the **+** button opens a new Home tab, **⌘W** closes it, and **⌘⇧D** duplicates it. **Control-Tab** and **Control-Shift-Tab** cycle through tabs. |
| Pin a location | Choose **Go → Pin Current Folder to Quick Access** or use the folder’s context menu. Pins persist across launches. |
| Find a file by name | Press **⌘F**. Search the current folder or its subfolders, then narrow results by Kind, Date or Size. The search reports incomplete coverage and skips the contents of packages and linked folders. |

When the pinned **Documents** folder points to OneDrive, the breadcrumb shows the OneDrive account. **⌘L** shows the full provider path. Address history contains successfully submitted addresses and is shared across windows. Clearing it preserves tab Back and Forward history.

## Home, Finder tags and Recent

In **Home → Tags → More tags**, check the tags you want to see. Home shows one group per checked tag. A file tagged both Work and Important appears in both groups when both are checked. Your choices become the default in new tabs and on your next launch. Click a tag shortcut to focus on that group; click it again to return to your default.

In **Home → Recent** and **Home → Tags**, click once to select a file and show it in the open Details or Preview pane. Control-click or Command-click toggles individual rows. Shift-click selects a range, including rows in adjacent tag groups. If you select the same file under two tags, the inspector counts it once. Double-click to open a file or folder. Right-click or press Shift-F10 for the same file menu used in folders. **Open With** applies to a single eligible file. **Compress to** and **Make Alias** place their output beside the selected items when they share a physical folder.

You can copy, cut, rename, drag or move selected files to the Trash from either list. A file selected under two tags is acted on once. **Remove from Recent** only hides its history entry. To paste or drop on the background, select a destination folder or a file in that folder. If the selection points to several folders, or nothing is selected, Orchard Explorer asks you to choose a folder. Cancelling preserves the clipboard. Drop directly on a folder row to use that folder.

When a drag needs the folder chooser, Orchard Explorer shows a copy badge and copies the files. Hold Command while dropping a selection dragged from Orchard Explorer to request a move.

Check **All tagged** in More tags to add its shortcut and make the all-items preview your default. It includes up to 500 distinct tagged items. Uncheck it to return to your saved named groups. If you clear every checkbox, More tags stays available. The colored dots follow Finder’s palette, and a hollow dot means the tag has no color. The picker includes configured Finder tags even when they have no indexed items.

To apply tags, select one or more files or folders, right-click and choose **Tags…**. Choose an existing name or type a new one and select **Create**. A mixed checkbox means some of the selected items have the tag. Choose **Apply** to save your changes. The same assignments appear in Finder.

**Home → Recent** shows up to 100 documents, newest first. It combines successful Orchard Explorer opens with documents that Spotlight reports used in the last 90 days. Items outside the index can still appear when opened through Orchard Explorer. **Remove from Recent** hides an entry until a later open.

## Views, Preview and Properties

The **View** menu offers eight layouts. **Control-Shift-1** through **Control-Shift-8** choose Extra large icons, Large icons, Medium icons, Small icons, List, Details, Tiles and Content, respectively. Click a column heading in Details to sort. Use **⌘-click** to toggle an item, **Shift-click** to extend the selection and **⌘A** to select all. **F6** and **Shift-F6** move keyboard focus between areas of the window.

Choose Light, Dark or Follow System under **View**. **Interface Size** scales the controls from 100% to 200%. **Background Folder Checks** lets you opt in to checking unopened protected, cloud or mounted-network folders for children. Enabling these checks can contact the provider or trigger a macOS permission prompt.

- **Preview (⌘⌥P)** shows a selected image, PDF, text file, media file or supported document. Text previews show up to 1 MiB. Text and supported physical PNG, JPEG and XLSX previews have zoom controls. Some formats use macOS Quick Look. Preview can download a supported online-only file.
- **Details (⌘⇧P)** shows information about the selection. Details and Preview share the side pane. Drag the divider to resize it.
- **Properties (⌘I)** shows read-only metadata for a physical item or a summary for a selection. Refreshing a single item checks the original entry. Folder sizes are not calculated recursively.

## Create, move and recover files

Use **New** to create a folder, shortcut, bitmap image, text document or ZIP. **⌘⇧N** creates a folder. To rename one item, select it and press **F2**. **Return** commits and **Esc** cancels. If the new name is occupied, choose another name.

Copy with **⌘C** and paste with **⌘V**, including between Finder and Orchard Explorer. To move, use **⌘X** then **⌘V**, or Copy followed by **Move Here (⌘⌥V)**. After a refused or cancelled move, issue Copy or Cut again. Dragging physical files inside Orchard Explorer moves by default. Hold **Option** to copy. Incoming external drags copy.

When a transfer finds a conflict, the dialog offers the choices supported for that item, such as Skip, Keep Both or Replace. Cancelling a batch keeps items already completed. If a folder becomes unavailable, its listing is dimmed until you can refresh it successfully.

With the file list focused, **Delete**, **Forward Delete** and **⌘Delete** move physical items to Trash. **File → Recently Trashed…** can restore verified items trashed by Orchard Explorer in this session. Supply a new name if the original is occupied. **⌘Z** and **⌘⇧Z** undo and redo the last verified physical rename in the current window.

## Cloud files and OneDrive

Pinning a folder to Quick Access adds a sidebar shortcut. To keep a file’s contents offline, use **Always Keep on This Device** on the file itself.

| OneDrive badge | What it means |
| --- | --- |
| Green outlined check | The visible file has local contents. |
| White check on a solid green disk | The visible file has local contents and OneDrive confirmed **Always Keep on This Device**. |
| Blue cloud | The visible file is online-only. A small pin beside the cloud means OneDrive also confirmed **Always Keep on This Device**. |
| Question mark | Orchard Explorer recognizes the cloud file and is still missing a reliable observation of its local contents. A pin with a question mark means OneDrive confirmed **Always Keep on This Device** while local availability is unknown. |
| Small clock beside a badge | OneDrive previously confirmed a pin. The main badge shows the current local availability while the keep setting awaits verification. |

Hover over a badge or read its accessibility value for the keep setting and any verification failure. Help includes the last successful check time when available. The spinner identifies an active download. A resident file may still be uploading.

For an eligible single online-only file, choose **Download** in the context menu to fetch a local copy. Download leaves the pin setting alone. Orchard Explorer accepts files up to 1 GiB and waits up to 120 seconds. The provider may continue after you stop waiting.

For a single supported file in a OneDrive account under `~/Library/CloudStorage`, **Always Keep on This Device** pins the file. **Free Up Space** asks OneDrive to remove its local copy. Both commands work while the verified OneDrive client is running. Close Preview or finish an active download for the target if its command is unavailable.

If OneDrive clears the pin while the file is still in use, Orchard Explorer reports that removal may finish in the background. While the row is visible and the notice is open, Orchard Explorer can update the badge and notice when it observes that removal has finished. The cloud copy remains available. Folders, mixed selections and search results do not offer retention commands.

## ZIP folders

Open a ZIP to browse its contents. To extract selected files or folders, copy them and paste into a physical folder. To add local items, copy them and paste inside the archive. You can also cut, rename and permanently delete supported entries. ZIP deletion requires confirmation and has no Trash recovery. Use a physical folder as an intermediate location when transferring between ZIPs.

Opening a member in another app creates a read-only temporary copy. To keep edits, save a separate file and add it back to the archive. Orchard Explorer retains edited temporary copies and reports them. Protected `__MACOSX` metadata companions move with the associated item. Unsupported compression, encrypted members and unsafe names produce an error. Refresh the listing after another app changes the archive.

## Upgrading from Maxplorer

The two apps share the bundle identifier `dev.native-explorer.app`. The renamed app uses your existing preferences, pins, and retained ZIP edits.

1. Finish ongoing file operations and quit Maxplorer. In Finder, compress `Maxplorer.app` to a ZIP backup and retain it. A ZIP backup keeps the old app available for rollback without presenting macOS with two file viewers that have the same identifier.
2. Remove the old, unpacked bundle from installed locations before opening the new one. Check your previous source checkout as well as Applications for loose builds in `app/dist`. Leave your preferences and Application Support files in place.
3. Move `Orchard Explorer.app` into Applications. Open it and check a familiar pin or folder. If you previously configured **Show in Finder** for Maxplorer, the same setting applies. Use another app's reveal command on a known file and confirm Orchard Explorer selects it. If you previously granted Full Disk Access and a location is inaccessible, check the entry for the renamed app in **System Settings → Privacy & Security → Full Disk Access**.

To roll back, quit Orchard Explorer, remove the unpacked renamed bundle from installed locations, and restore the archived Maxplorer bundle to Applications. Both versions use the same user data.

## Use Orchard Explorer for “Show in Finder”

Some apps send a system request to reveal a file. Install Orchard Explorer in `/Applications` to use it for those requests. If you already use another viewer, record its setting with `defaults read -g NSFileViewer` before running this command in Terminal.

```sh
defaults write -g NSFileViewer -string dev.native-explorer.app
```

A reveal selects the file in its containing folder. Apps that control Finder directly keep using Finder. To return to the system default, run `defaults delete -g NSFileViewer`. If you previously set another viewer, restore its bundle identifier.

## File access

**Orchard Explorer → File Access…** shows the running app’s location and explains macOS Full Disk Access. **Choose Folder to Check** tries to list a folder you select. A successful check confirms read access there. macOS still enforces filesystem permissions and read-only volumes. When reporting a problem, include your macOS version, the type of location and the exact message.
