import AppKit
@testable import ExplorerCore
import Testing
import UniformTypeIdentifiers
@testable import ExplorerApp

@Suite @MainActor
struct ContextMenuTests {
    // MR-MENU-001/005; MT-MENU-01/04/09; MAC-MENU-FUP-005.
    // Natural symbol dimensions must not move text baselines or shrink AX targets.
    @Test func actionRowHasAlignedContentAndWholeCellAccessibilityTargets() async throws {
        let f = try await P18Fixture.make(); defer { f.close() }
        f.select([f.items[1]])
        let controller = FileContextMenuController(store: f.store)
        let menu = try #require(controller.menu(for: f.items[1]) as? ContextCommandMenu)
        let source = contextTestWindow(), panel = contextTestWindow()
        defer { source.close(); panel.close() }
        let presentation = FileContextMenuPanelController(controller: controller, menu: menu,
            origin: try #require(source.contentView), point: NSPoint(x: 10, y: 200), keyboard: true,
            panel: panel, panelFactory: { contextTestWindow() }, isApplicationActive: { true })
        presentation.show()
        defer { presentation.dismiss(reason: .replacement) }
        panel.contentView?.layoutSubtreeIfNeeded()
        let ids = ["context-cut", "context-copy", "context-rename", "context-share", "context-moveToTrash"]
        let labels = ["Cut", "Copy", "Rename", "Share", "Delete"]
        let row = try ids.map { id in try #require(contextButtons(in: panel).first { $0.identifier?.rawValue == id }) }
        var titleRegions: [NSRect] = [], imageRegions: [NSRect] = []
        for (index, button) in row.enumerated() {
            let cell = try #require(button.cell as? NSButtonCell)
            let title = cell.titleRect(forBounds: button.bounds)
            let image = cell.imageRect(forBounds: button.bounds)
            titleRegions.append(title); imageRegions.append(image)
            #expect(button.accessibilityLabel() == labels[index] && button.accessibilityRole() == .button)
            #expect(button.bounds.contains(title) && button.bounds.contains(image))
            let imageIsAboveTitle = button.isFlipped ? image.maxY < title.minY : title.maxY < image.minY
            #expect(imageIsAboveTitle, "Icons remain above their labels in the button's actual coordinates")
            let screenFrame = panel.convertToScreen(button.convert(button.bounds, to: nil))
            #expect(button.accessibilityFrame() == screenFrame,
                    "Each action exposes its entire hit target, regardless of its symbol's natural size")
            for point in [NSPoint(x: 1, y: 1), NSPoint(x: button.bounds.maxX - 1, y: button.bounds.maxY - 1)] {
                #expect(button.hitTest(button.convert(point, to: button.superview)) === button)
            }
            #expect(button.subviews.allSatisfy { !$0.isAccessibilityElement() })
        }
        let firstTitle = try #require(titleRegions.first), firstImage = try #require(imageRegions.first)
        for (title, image) in zip(titleRegions, imageRegions) {
            #expect(abs(title.minY - firstTitle.minY) < 0.01 && abs(title.height - firstTitle.height) < 0.01,
                    "The five short labels share one text region and baseline")
            #expect(abs(image.minY - firstImage.minY) < 0.01 && abs(image.height - firstImage.height) < 0.01,
                    "The five symbols share one aligned icon region")
        }
        let disabled = try #require(row.first)
        disabled.isEnabled = false
        #expect(!disabled.isAccessibilityEnabled() && !disabled.accessibilityPerformPress())
        #expect(presentation.session.state == .open)
    }

    // MAC-MENU-FUP-005: inspect the pixels emitted by the actual row cell, not
    // just its reserved icon region. A raw SF Symbol can occupy that region at
    // the wrong size when the custom cell bypasses NSButton's configuration.
    @Test(arguments: [false, true])
    func actionRowRendersConfiguredSymbolsAndDisabledAppearance(_ dark: Bool) async throws {
        let f = try await P18Fixture.make(); defer { f.close() }
        f.select([f.items[1]])
        let controller = FileContextMenuController(store: f.store)
        let menu = try #require(controller.menu(for: f.items[1]) as? ContextCommandMenu)
        let source = contextTestWindow(), panel = contextTestWindow()
        defer { source.close(); panel.close() }
        panel.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        let presentation = FileContextMenuPanelController(controller: controller, menu: menu,
            origin: try #require(source.contentView), point: NSPoint(x: 10, y: 200), keyboard: true,
            panel: panel, panelFactory: { contextTestWindow() }, isApplicationActive: { true })
        presentation.show()
        defer { presentation.dismiss(reason: .replacement) }
        for button in contextButtons(in: panel).filter({ $0.imagePosition == .imageAbove }) {
            let cell = try #require(button.cell as? NSButtonCell)
            let image = try #require(button.image)
            let configuration = try #require(button.symbolConfiguration)
            let configured = try #require(image.withSymbolConfiguration(configuration))
            let iconRect = cell.imageRect(forBounds: button.bounds)
            let titleRect = cell.titleRect(forBounds: button.bounds)
            let wasEnabled = button.isEnabled
            defer { button.isEnabled = wasEnabled }
            button.isEnabled = true
            let actual = try contextCellInk(button, region: iconRect, dark: dark) {
                cell.drawInterior(withFrame: button.bounds, in: button)
            }
            let expected = try contextCellInk(button, region: iconRect, dark: dark) {
                cell.drawImage(configured, withFrame: iconRect, in: button)
            }
            #expect(abs(actual.bounds.width - expected.bounds.width) <= 1
                    && abs(actual.bounds.height - expected.bounds.height) <= 1,
                    "The rendered icon must retain the button's configured symbol size")
            let enabledTitle = try contextCellInk(button, region: titleRect, dark: dark) {
                cell.drawInterior(withFrame: button.bounds, in: button)
            }
            button.isEnabled = false
            let disabledIcon = try contextCellInk(button, region: iconRect, dark: dark) {
                cell.drawInterior(withFrame: button.bounds, in: button)
            }
            let disabledTitle = try contextCellInk(button, region: titleRect, dark: dark) {
                cell.drawInterior(withFrame: button.bounds, in: button)
            }
            #expect(disabledIcon.contrast < actual.contrast * 0.95,
                    "Disabled icons visibly dim in each appearance")
            #expect(disabledTitle.contrast < enabledTitle.contrast * 0.95,
                    "Disabled labels visibly dim in each appearance")
        }
    }

    // MR-MENU-003/005; MT-MENU-04/07. Retain real target/action and AX dispatch
    // when row cell drawing and AX geometry are customized.
    @Test(arguments: [false, true], [false, true])
    func panelRenameButtonKeepsGuardedControlAndAccessibilityDispatch(_ accessibility: Bool, _ identityCurrent: Bool) async throws {
        let f = try await P18Fixture.make(); defer { f.close() }
        let selected = f.items[1]; f.select([selected])
        f.store.validateRoutingTarget = { _ in identityCurrent }
        let controller = FileContextMenuController(store: f.store)
        let menu = try #require(controller.menu(for: selected) as? ContextCommandMenu)
        let source = contextTestWindow(), panel = contextTestWindow()
        defer { source.close(); panel.close() }
        let presentation = FileContextMenuPanelController(controller: controller, menu: menu,
            origin: try #require(source.contentView), point: NSPoint(x: 10, y: 200), keyboard: true,
            panel: panel, panelFactory: { contextTestWindow() }, isApplicationActive: { true })
        presentation.show()
        defer { presentation.dismiss(reason: .replacement) }
        let item = try #require(menu.item(withTitle: "Rename"))
        let button = try contextButton(item, in: panel)
        if accessibility {
            #expect(button.accessibilityPerformPress())
            #expect(!button.accessibilityPerformPress())
        } else {
            // Exercise the real NSControl target/action without performClick's
            // animation event loop, which can stop Swift Testing's main loop.
            // Actual pointer activation is covered by the separate UI run.
            let action = try #require(button.action), target = try #require(button.target)
            #expect(button.sendAction(action, to: target))
            #expect(button.sendAction(action, to: target))
        }
        try await p18Wait { presentation.session.state == (identityCurrent ? .completed : .cancelled) }
        if identityCurrent {
            #expect(f.store.nameEdit?.item?.id == selected.id)
        } else {
            #expect(f.store.nameEdit == nil)
            #expect(f.store.operationNotice == "An item changed or is no longer available. Nothing was done. Refresh and try again.")
        }
        #expect(panel.contentView == nil)
    }

    // MR-MENU-005; MT-MENU-04; MAC-MENU-FUP-002. Visible checkmarks and
    // submenu openness must be available as standard public AX role/state.
    @Test(arguments: ["View", "Sort by"])
    func backgroundSubmenusExposeChoiceStateAndSafeAccessibilityActivation(_ title: String) async throws {
        let f = try await P18Fixture.make(); defer { f.close() }
        f.select([])
        let controller = FileContextMenuController(store: f.store)
        let menu = try #require(controller.menu(for: nil) as? ContextCommandMenu)
        let source = contextTestWindow(), panel = contextTestWindow()
        defer { source.close(); panel.close() }
        let presentation = FileContextMenuPanelController(controller: controller, menu: menu,
            origin: try #require(source.contentView), point: NSPoint(x: 10, y: 200), keyboard: true,
            panel: panel, panelFactory: { contextTestWindow() }, isApplicationActive: { true })
        presentation.show()
        defer { presentation.dismiss(reason: .replacement) }
        let parent = try #require(menu.item(withTitle: title))
        let initial = try contextButton(parent, in: panel)
        #expect(initial.accessibilityRole() == .popUpButton && !initial.isAccessibilityExpanded())
        #expect(initial.title == parent.title)
        #expect(initial.image != nil)
        initial.layoutSubtreeIfNeeded()
        let arrow = try #require(initial.subviews.compactMap { $0 as? NSTextField }.first { $0.stringValue == "›" })
        let parentCell = try #require(initial.cell as? NSButtonCell)
        #expect(parentCell.titleRect(forBounds: initial.bounds).maxX <= arrow.frame.minX)
        #expect(!arrow.isAccessibilityElement())
        #expect(initial.accessibilityPerformPress())
        let expanded = try contextButton(parent, in: panel)
        #expect(expanded.isAccessibilityExpanded())
        let childMenu = try #require(parent.submenu)
        let children = childMenu.items.filter { !$0.isSeparatorItem }
        let controls = try children.map { try contextButton($0, in: panel) }
        let ids = controls.compactMap { $0.accessibilityIdentifier() }
        #expect(ids.count == children.count && Set(ids).count == children.count,
                "Every choice has a distinct stable accessibility identity")
        let parentID = expanded.accessibilityIdentifier()
        #expect(!parentID.isEmpty && !ids.contains(parentID))
        for (item, button) in zip(children, controls) {
            #expect(button.accessibilityRole() == .radioButton)
            #expect((button.accessibilityValue() as? NSNumber)?.intValue == (item.state == .on ? 1 : 0))
            #expect(button.accessibilityLabel() == item.title && button.isAccessibilityEnabled() == item.isEnabled)
            #expect(button.title == item.title && (button.image != nil) == (title == "View"))
            #expect(button.subviews.allSatisfy { !$0.isAccessibilityElement() })
            let cell = try #require(button.cell as? NSButtonCell)
            button.layoutSubtreeIfNeeded()
            let marker = button.subviews.compactMap { $0 as? NSTextField }.first { $0.stringValue == "•" }
            #expect((marker != nil) == (item.state == .on))
            if let marker {
                let text = cell.titleRect(forBounds: button.bounds)
                if title == "View" {
                    let image = cell.imageRect(forBounds: button.bounds)
                    #expect(marker.frame.maxX <= image.minX && image.maxX <= text.minX)
                } else {
                    #expect(marker.frame.maxX <= text.minX)
                }
            }
            let narrow = NSRect(x: 0, y: 0, width: 32.pt, height: button.bounds.height)
            let narrowText = cell.titleRect(forBounds: narrow)
            let narrowImage = cell.imageRect(forBounds: narrow)
            #expect(narrowText.maxX <= narrow.maxX && narrowText.width >= 0)
            #expect(narrowImage.maxX <= narrow.maxX && narrowImage.width >= 0)
        }
        if title == "Sort by" {
            let keyGroup = try #require(controls.first?.accessibilityParent() as? NSAccessibilityElement)
            let directionGroup = try #require(controls.last?.accessibilityParent() as? NSAccessibilityElement)
            #expect(keyGroup !== directionGroup)
            for (group, suffix, label, expectedCount) in [(keyGroup, "key", "Sort key", SortKey.allCases.count),
                                                         (directionGroup, "direction", "Sort direction", 2)] {
                #expect(group.accessibilityRole() == .radioGroup)
                #expect(group.accessibilityIdentifier() == "context-sortBy-\(suffix)-group")
                #expect(group.accessibilityLabel() == label)
                let members = try #require(group.accessibilityChildren() as? [ContextActionButton])
                #expect(members.count == expectedCount)
                #expect(members.filter { ($0.accessibilityValue() as? NSNumber)?.intValue == 1 }.count == 1)
                #expect(members.allSatisfy { ($0.accessibilityParent() as? NSAccessibilityElement) === group })
            }
            let body = try #require(keyGroup.accessibilityParent() as? NSView)
            let groups = try #require(body.accessibilityChildren() as? [NSAccessibilityElement])
            #expect(groups.count == 2 && groups[0] === keyGroup && groups[1] === directionGroup)
            let grouped = groups.flatMap { $0.accessibilityChildren() as? [ContextActionButton] ?? [] }
            #expect(grouped.map(ObjectIdentifier.init) == controls.map(ObjectIdentifier.init),
                    "Existing buttons appear once, in visual order, across the two independent choice groups")
        }
        let menuTitleStarts = controls.compactMap { button in
            (button.cell as? NSButtonCell)?.titleRect(forBounds: button.bounds).minX
        }
        #expect(menuTitleStarts.count == controls.count && Set(menuTitleStarts).count == 1)
        let left = try contextKey("", code: 123, modifiers: [], window: panel)
        panel.keyDown(with: left)
        let collapsed = try contextButton(parent, in: panel)
        #expect(!collapsed.isAccessibilityExpanded())
        #expect(collapsed.accessibilityPerformShowMenu(), "The submenu's AXShowMenu action opens the same child surface")
        #expect(presentation.navigation.menus.count == 2)
        let reopened = try contextButton(parent, in: panel)
        #expect(reopened.isAccessibilityExpanded())
        let reopenedIDs = try children.map { try contextButton($0, in: panel).accessibilityIdentifier() }
        #expect(reopenedIDs.compactMap { $0 } == ids)
        let choice = try #require(children.first { $0.title == (title == "View" ? "Large icons" : "Descending") })
        let button = try contextButton(choice, in: panel)
        #expect(button.accessibilityPerformPress())
        #expect(!button.accessibilityPerformPress())
        try await p18Wait { presentation.session.state == .completed }
        if title == "View" { #expect(f.store.activeTab.viewMode == .largeIcons) }
        else { #expect(!f.store.activeTab.sort.ascending) }
        #expect(panel.contentView == nil && f.store.currentSelection.selectedIDs.isEmpty)
    }

    @Test func archiveSubmenuChildrenHaveDistinctAccessibilityIdentities() async throws {
        let f = try await P18Fixture.make(); defer { f.close() }
        f.select([f.items[1]])
        let controller = FileContextMenuController(store: f.store)
        let menu = try #require(controller.menu(for: f.items[1]) as? ContextCommandMenu)
        let source = contextTestWindow(), panel = contextTestWindow()
        defer { source.close(); panel.close() }
        let presentation = FileContextMenuPanelController(controller: controller, menu: menu,
            origin: try #require(source.contentView), point: NSPoint(x: 10, y: 200), keyboard: true,
            panel: panel, panelFactory: { contextTestWindow() }, isApplicationActive: { true })
        presentation.show()
        defer { presentation.dismiss(reason: .replacement) }
        let parent = try #require(menu.item(withTitle: "Compress to"))
        let parentButton = try contextButton(parent, in: panel)
        #expect(parentButton.accessibilityPerformPress())
        let childMenu = try #require(parent.submenu)
        let children = childMenu.items.filter { !$0.isSeparatorItem }
        let ids = try children.map { try contextButton($0, in: panel).accessibilityIdentifier() }
        #expect(ids.compactMap { $0 }.count == 2 && Set(ids.compactMap { $0 }).count == 2)
        let expanded = try contextButton(parent, in: panel)
        expanded.isEnabled = false
        #expect(!expanded.accessibilityPerformPress() && !expanded.accessibilityPerformShowMenu())
        #expect(presentation.session.state == .open)
    }

    @Test func repeatedPanelCommandDeleteIsConsumedWithoutValidationOrTrash() async throws {
        let f = try await P18Fixture.make(); defer { f.close() }
        f.select([f.items[1]])
        let controller = FileContextMenuController(store: f.store)
        let menu = try #require(controller.menu(for: f.items[1]) as? ContextCommandMenu)
        let source = contextTestWindow(), panel = contextTestWindow()
        defer { source.close(); panel.close() }
        let presentation = FileContextMenuPanelController(controller: controller, menu: menu,
            origin: try #require(source.contentView), point: NSPoint(x: 10, y: 200), keyboard: true,
            panel: panel, panelFactory: { contextTestWindow() }, isApplicationActive: { true })
        presentation.show()
        defer { presentation.dismiss(reason: .replacement) }
        var validations = 0
        f.store.validateRoutingTarget = { _ in
            await MainActor.run { validations += 1 }
            return true
        }
        let repeated = try contextKey("\u{7f}", code: 51, modifiers: .command, window: panel, isRepeat: true)
        let fallback = ContextShortcutSentinel()
        let mainMenu = contextFallbackMenu("\u{7f}", target: fallback)
        let handled = panel.performKeyEquivalent(with: repeated)
        if !handled { _ = mainMenu.performKeyEquivalent(with: repeated) }
        if presentation.session.state == .validating {
            try await p18Wait { presentation.session.state != .validating && !f.store.isPerformingOperation }
        }
        #expect(handled && fallback.invocations == 0)
        #expect(presentation.session.state == .open,
                "MAC-079: a held Delete key must not consume a newly opened context session")
        #expect(validations == 0, "Auto-repeat is rejected before command validation starts")
        #expect(await f.operations.trashedNames.isEmpty)
    }

    @Test(arguments: ["\u{8}", "\u{7f}"])
    func panelCommandDeleteUsesValidatedSession(_ character: String) async throws {
        let f = try await P18Fixture.make(); defer { f.close() }
        let selected = f.items[1]; f.select([selected])
        let controller = FileContextMenuController(store: f.store)
        let menu = try #require(controller.menu(for: selected) as? ContextCommandMenu)
        let source = contextTestWindow(), panel = contextTestWindow()
        defer { source.close(); panel.close() }
        let presentation = FileContextMenuPanelController(controller: controller, menu: menu,
            origin: try #require(source.contentView), point: NSPoint(x: 10, y: 200), keyboard: true,
            panel: panel, panelFactory: { contextTestWindow() }, isApplicationActive: { true })
        presentation.show()
        defer { presentation.dismiss(reason: .replacement) }
        let gate = P18Gate(); f.store.validateRoutingTarget = { _ in await gate.wait() }
        let event = try contextKey(character, code: 51, modifiers: .command, window: panel)
        let fallback = ContextShortcutSentinel()
        let mainMenu = contextFallbackMenu(character, target: fallback)
        let handled = panel.performKeyEquivalent(with: event)
        if !handled { _ = mainMenu.performKeyEquivalent(with: event) }
        #expect(fallback.invocations == 0, "The panel must not hand Cmd-Delete to main-window commands")
        try #require(handled && presentation.session.state == .validating,
            "Both Delete encodings must enter the common validated context session")
        try await p18Wait { gate.pending == 1 }
        #expect(await f.operations.trashedNames.isEmpty, "Identity validation precedes any Trash request")
        gate.release(true)
        try await p18Wait { presentation.session.state == .completed && !f.store.isPerformingOperation }
        #expect(await f.operations.trashedNames == [selected.name])
        let trash = try #require(menu.item(withTitle: "Move to Trash"))
        #expect(!presentation.session.activate(trash), "The resolved session cannot dispatch twice")
    }

    @Test func panelConsumesUnmatchedCommandKeysButPreservesVoiceOverChords() async throws {
        let f = try await P18Fixture.make(); defer { f.close() }
        f.select([f.items[1]])
        let controller = FileContextMenuController(store: f.store)
        let menu = try #require(controller.menu(for: f.items[1]) as? ContextCommandMenu)
        let source = contextTestWindow(), panel = contextTestWindow()
        defer { source.close(); panel.close() }
        let presentation = FileContextMenuPanelController(controller: controller, menu: menu,
            origin: try #require(source.contentView), point: NSPoint(x: 10, y: 200), keyboard: true,
            panel: panel, panelFactory: { contextTestWindow() }, isApplicationActive: { true })
        presentation.show()
        defer { presentation.dismiss(reason: .replacement) }
        let fallback = ContextShortcutSentinel()
        let shortcuts: [(String, UInt16)] = [("v", 9), ("w", 13), ("[", 33)]
        for (character, code) in shortcuts {
            let event = try contextKey(character, code: code, modifiers: .command, window: panel)
            let mainMenu = contextFallbackMenu(character, target: fallback)
            let handled = panel.performKeyEquivalent(with: event)
            if !handled { _ = mainMenu.performKeyEquivalent(with: event) }
            #expect(handled, "Unmatched Command shortcuts cannot escape the open context surface")
        }
        #expect(fallback.invocations == 0 && presentation.session.state == .open)
        let voiceOver = try contextKey("c", code: 8, modifiers: [.control, .option], window: panel)
        #expect(!panel.performKeyEquivalent(with: voiceOver))
        #expect(f.store.clipboard.payload == nil)
    }

    @Test(arguments: [false, true])
    func backgroundOriginAcquiresOwnershipBeforeCopyAndRechecksAfterAwait(_ loseOwnership: Bool) async throws {
        let f = try await P18Fixture.make(); defer { f.close() }
        let selected = f.items[1]; f.select([selected])
        let controller = FileContextMenuController(store: f.store)
        let menu = try #require(controller.menu(for: selected) as? ContextCommandMenu)
        let source = contextTestWindow(), panel = contextTestWindow()
        source.ownsMainWindow = false
        defer { source.close(); panel.close() }
        let presentation = FileContextMenuPanelController(controller: controller, menu: menu,
            origin: try #require(source.contentView), point: NSPoint(x: 10, y: 200), keyboard: true,
            panel: panel, panelFactory: { contextTestWindow() }, isApplicationActive: { true })
        presentation.show()
        defer { presentation.dismiss(reason: .replacement) }
        #expect(source.ownsMainWindow, "Direct background-window invocation must acquire its origin before presenting")
        let copy = try #require(menu.item(withTitle: "Copy"))
        let button = try contextButton(copy, in: panel)
        let gate = P18Gate(); f.store.validateRoutingTarget = { _ in await gate.wait() }
        try #require(button.accessibilityPerformPress(), "A displayed context surface cannot be inert because its origin was background")
        try await p18Wait { gate.pending == 1 }
        if loseOwnership { source.ownsMainWindow = false }
        gate.release(true)
        try await p18Wait { presentation.session.state != .validating }
        if loseOwnership {
            #expect(presentation.session.state == .cancelled && f.store.clipboard.payload == nil)
        } else {
            #expect(presentation.session.state == .completed)
            #expect(f.store.clipboard.payload?.items.map(\.id) == [selected.id])
        }
    }

    @Test func submenuKeyboardFocusSurvivesStationaryPointerAndRetainedParent() async throws {
        let f = try await P18Fixture.make(); defer { f.close() }
        f.select([f.items[1]])
        let controller = FileContextMenuController(store: f.store)
        let menu = try #require(controller.menu(for: f.items[1]) as? ContextCommandMenu)
        let parent = try #require(menu.item(withTitle: "Open With"))
        let firstEnabledChild = parent.submenu?.items.first { $0.isEnabled }
        let child = try #require(firstEnabledChild)
        let source = ContextMenuTestPanel(contentRect: NSRect(x: 40, y: 300, width: 600, height: 400),
            styleMask: [.borderless], backing: .buffered, defer: false)
        let panel = ContextMenuTestPanel(contentRect: .zero, styleMask: [.borderless], backing: .buffered, defer: false)
        source.isReleasedWhenClosed = false; panel.isReleasedWhenClosed = false
        defer { source.close(); panel.close() }
        let origin = try #require(source.contentView)
        let presentation = FileContextMenuPanelController(controller: controller, menu: menu, origin: origin,
            point: NSPoint(x: 10, y: 200), keyboard: false, panel: panel, panelFactory: { contextTestWindow() }, isApplicationActive: { true })
        presentation.show()
        defer { presentation.dismiss(reason: .replacement) }
        let oldParent = try contextButton(parent, in: panel)
        panel.pointerScreen = panel.convertPoint(toScreen: oldParent.convert(
            NSPoint(x: oldParent.bounds.midX, y: oldParent.bounds.midY), to: nil))
        oldParent.updateTrackingAreas()
        await contextCallbacksSettled()
        #expect(presentation.navigation.focused === parent)
        let right = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
            timestamp: 1, windowNumber: panel.windowNumber, context: nil, characters: "",
            charactersIgnoringModifiers: "", isARepeat: false, keyCode: 124))
        oldParent.keyDown(with: right)
        #expect(presentation.navigation.focused === child && presentation.navigation.activeColumn == 1)
        let rebuiltParent = try contextButton(parent, in: panel)
        #expect(rebuiltParent === oldParent)
        #expect(rebuiltParent.bounds.contains(rebuiltParent.convert(panel.mouseLocationOutsideOfEventStream, from: nil)))
        rebuiltParent.updateTrackingAreas()
        await contextCallbacksSettled()
        #expect(presentation.navigation.focused === child && presentation.navigation.activeColumn == 1,
                "Reinstalling a parent's tracking area beneath a stationary pointer must retain child keyboard focus")
        let childButton = try contextButton(child, in: panel)
        #expect(childButton.keyboardFocused && childButton.window?.firstResponder === childButton)
        #expect(childButton.window !== panel)
        let applications = try #require(parent.submenu).items.filter { !$0.isSeparatorItem }
        let applicationIDs = try applications.map { try contextButton($0, in: panel).accessibilityIdentifier() }
        #expect(applicationIDs == [
            "context-openWith-file:///tmp/Editor.app",
            "context-openWith-file:///tmp/Viewer.app",
            "context-openWith-choose-application"
        ])
        // Movement within the same already-hovered parent must restore pointer
        // navigation; there need not be another mouseEntered transition.
        panel.pointerScreen.x += 2
        rebuiltParent.mouseMoved(with: ContextMenuPointerEvent(window: panel))
        await contextCallbacksSettled()
        #expect(presentation.navigation.focused === parent && presentation.navigation.activeColumn == 0)
        #expect(!childButton.keyboardFocused)
    }

    @Test func panelBodyRetainsCanonicalShortcutLabelsWithoutExtraAccessibilityStops() async throws {
        let f = try await P18Fixture.make(); defer { f.close() }
        f.select([f.items[1]])
        let controller = FileContextMenuController(store: f.store)
        let menu = try #require(controller.menu(for: f.items[1]) as? ContextCommandMenu)
        let source = ContextMenuTestPanel(contentRect: NSRect(x: 40, y: 300, width: 600, height: 400),
            styleMask: [.borderless], backing: .buffered, defer: false)
        let panel = ContextMenuTestPanel(contentRect: .zero, styleMask: [.borderless], backing: .buffered, defer: false)
        source.isReleasedWhenClosed = false; panel.isReleasedWhenClosed = false
        defer { source.close(); panel.close() }
        let presentation = FileContextMenuPanelController(controller: controller, menu: menu,
            origin: try #require(source.contentView), point: NSPoint(x: 10, y: 200), keyboard: true,
            panel: panel, panelFactory: { contextTestWindow() }, isApplicationActive: { true })
        presentation.show()
        defer { presentation.dismiss(reason: .replacement) }
        for (title, shortcut) in [("Copy as Pathname", "⌥⌘C"), ("Properties", "⌘I")] {
            let item = try #require(menu.item(withTitle: title))
            let button = try contextButton(item, in: panel)
            let label = try #require(button.subviews.compactMap { $0 as? NSTextField }.first {
                $0.stringValue == shortcut
            }, "Body rows must display the canonical menu item's shortcut")
            #expect(!label.isAccessibilityElement())
            #expect(button.accessibilityLabel() == title && button.isEnabled == item.isEnabled)
            #expect(button.title == title && button.image != nil)
            let cell = try #require(button.cell as? NSButtonCell)
            let icon = cell.imageRect(forBounds: button.bounds)
            let text = cell.titleRect(forBounds: button.bounds)
            button.layoutSubtreeIfNeeded()
            #expect(!icon.isEmpty && button.bounds.contains(icon))
            #expect(icon.maxX <= text.minX && text.maxX <= label.frame.minX)
        }
        let path = try #require(menu.item(withTitle: "Copy as Pathname"))
        let pathButton = try contextButton(path, in: panel)
        let action = try #require(pathButton.action), target = try #require(pathButton.target)
        #expect(pathButton.sendAction(action, to: target))
        try await p18Wait { presentation.session.state == .completed }
        #expect(f.board.string(forType: .string) == f.items[1].url.path)
    }

    @Test(arguments: [false, true])
    func panelBodyRendersWideAndColorArtworkAndDimsDisabledRows(_ dark: Bool) async throws {
        let f = try await P18Fixture.make(); defer { f.close() }
        f.select([f.items[1]])
        let controller = FileContextMenuController(store: f.store)
        let menu = try #require(controller.menu(for: f.items[1]) as? ContextCommandMenu)
        let path = try #require(menu.item(withTitle: "Copy as Pathname"))
        let properties = try #require(menu.item(withTitle: "Properties"))
        let color = NSImage(size: NSSize(width: 32, height: 32), flipped: false) { rect in
            NSColor(srgbRed: 0.95, green: 0.3, blue: 0.15, alpha: 1).setFill()
            rect.insetBy(dx: rect.width / 8, dy: rect.height / 8).fill()
            return true
        }
        path.image = try #require(MenuIcons.symbol("arrow.left.and.right"))
        properties.image = try #require(MenuIcons.sizedCopy(color))
        #expect(properties.image !== color && color.size == NSSize(width: 32, height: 32))
        let source = contextTestWindow(), panel = contextTestWindow()
        defer { source.close(); panel.close() }
        panel.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        let presentation = FileContextMenuPanelController(controller: controller, menu: menu,
            origin: try #require(source.contentView), point: NSPoint(x: 10, y: 200), keyboard: true,
            panel: panel, panelFactory: { contextTestWindow() }, isApplicationActive: { true })
        presentation.show()
        defer { presentation.dismiss(reason: .replacement) }
        for item in [path, properties] {
            let button = try contextButton(item, in: panel)
            let cell = try #require(button.cell as? NSButtonCell)
            let icon = cell.imageRect(forBounds: button.bounds)
            try #require(!icon.isEmpty && button.bounds.contains(icon))
            let enabled = try contextCellInk(button, region: icon, dark: dark) {
                cell.drawInterior(withFrame: button.bounds, in: button)
            }
            if item === path {
                #expect(enabled.bounds.width > enabled.bounds.height)
            } else {
                #expect(enabled.saturation > 0.25, "Application artwork retains color in the body cell")
            }
            button.isEnabled = false
            let disabled = try contextCellInk(button, region: icon, dark: dark) {
                cell.drawInterior(withFrame: button.bounds, in: button)
            }
            #expect(disabled.contrast < enabled.contrast * 0.95)
        }
    }

    @Test func allSemanticMenuSymbolsResolveAndCachedArtworkIsUnchanged() throws {
        for glyph in MenuIcons.Glyph.allCases {
            #expect(glyph.image != nil, "Missing system symbol \(glyph.rawValue)")
        }
        for command in NewCommand.allCases {
            #expect(MenuIcons.symbol(command.symbol) != nil, "Missing New symbol \(command.symbol)")
        }
        let original = ExplorerIcons.folder
        let originalSize = original.size
        let copy = try #require(MenuIcons.sizedCopy(original))
        #expect(copy !== original && original.size == originalSize)
        #expect(copy.size == NSSize(width: 16.pt, height: 16.pt))
        #expect(copy.isTemplate == original.isTemplate)
    }

    @Test func panelActionOrderNavigationAndSubmenuBoundary() async throws {
        let f = try await P18Fixture.make(); defer { f.close() }
        f.select([f.items[1]])
        let controller = FileContextMenuController(store: f.store)
        let menu = try #require(controller.menu(for: f.items[1]) as? ContextCommandMenu)
        let navigation = ContextMenuNavigation(menu: menu, keyboard: true)
        #expect(navigation.rowItems.map { $0.identifier?.rawValue } ==
            ["context-cut", "context-copy", "context-rename", "context-share", "context-moveToTrash"])
        #expect(navigation.bodyItems(at: 0).allSatisfy { !navigation.rowItems.contains($0) })
        #expect(navigation.focused?.title == "Cut")
        navigation.move(123); #expect(navigation.focused?.title == "Cut")
        navigation.move(124); #expect(navigation.focused?.title == "Copy")
        navigation.move(125); #expect(navigation.focused?.title == "Rename")
        navigation.move(124); #expect(navigation.focused?.identifier?.rawValue == "context-share")
        navigation.move(124); navigation.move(124)
        #expect(navigation.focused?.title == "Move to Trash")
        navigation.move(125); #expect(navigation.focused?.title == "Open")
        navigation.move(126); #expect(navigation.focused?.title == "Move to Trash")
        let openWith = try #require(menu.item(withTitle: "Open With"))
        navigation.hover(openWith); navigation.move(124)
        #expect(navigation.menus.count == 2 && navigation.focused?.title == "Editor (default)")
        navigation.move(123)
        #expect(navigation.menus.count == 1 && navigation.focused === openWith)
        navigation.typeSelect("p", timestamp: 2)
        #expect(navigation.focused?.title == "Properties")
        #expect(navigation.commandEquivalent(key: String(UnicodeScalar(NSF2FunctionKey)!), modifiers: [])?.title == "Rename")
        #expect(navigation.commandEquivalent(key: "c", modifiers: .command)?.title == "Copy")
        #expect(navigation.commandEquivalent(key: "c", modifiers: [.control, .option]) == nil)
        let pointerNavigation = ContextMenuNavigation(menu: menu, keyboard: false)
        #expect(pointerNavigation.focused == nil)
        menu.item(withTitle: "Cut")?.isEnabled = false
        pointerNavigation.move(124)
        #expect(pointerNavigation.focused?.title == "Copy")
    }

    @Test func panelDispatchSettlesOnceAndDisabledAccessibilityPressRefuses() async throws {
        let f = try await P18Fixture.make(); defer { f.close() }
        let selected = f.items[1]; f.select([selected])
        let controller = FileContextMenuController(store: f.store)
        let menu = try #require(controller.menu(for: selected) as? ContextCommandMenu)
        let copy = try #require(menu.item(withTitle: "Copy"))
        let session = ContextMenuActionSession(menu: menu, controller: controller)
        var closed = 0; session.closeForAction = { closed += 1 }
        let button = ContextActionButton(title: "Copy", identifier: "context-copy")
        button.invoke = { session.activate(copy) }
        button.isEnabled = false
        #expect(!button.accessibilityPerformPress() && session.state == .open)
        button.isEnabled = true
        #expect(button.accessibilityPerformPress())
        #expect(!button.accessibilityPerformPress())
        try await p18Wait { session.state == .completed }
        let payload = try #require(f.store.clipboard.payload)
        #expect(payload.items.map(\.id) == [selected.id])
        #expect(closed == 1)
        #expect(!session.activate(copy) && f.store.clipboard.payload?.id == payload.id)
    }

    @Test(arguments: [false, true])
    func panelRechecksContextAndOriginAfterIdentityValidation(_ loseOrigin: Bool) async throws {
        let f = try await P18Fixture.make(); defer { f.close() }
        let selected = f.items[1]; f.select([selected])
        let controller = FileContextMenuController(store: f.store)
        let menu = try #require(controller.menu(for: selected) as? ContextCommandMenu)
        let copy = try #require(menu.item(withTitle: "Copy"))
        let session = ContextMenuActionSession(menu: menu, controller: controller)
        let gate = P18Gate(); f.store.validateRoutingTarget = { _ in await gate.wait() }
        var ownsOrigin = true; session.isOriginCurrent = { ownsOrigin }
        f.board.clearContents(); #expect(f.board.setString("keep while validation waits", forType: .string))
        let generation = f.board.changeCount
        #expect(session.activate(copy))
        try await p18Wait { gate.pending == 1 }
        if loseOrigin { ownsOrigin = false } else { f.select([f.items[2]]) }
        gate.release(true)
        try await p18Wait { session.state == .cancelled }
        #expect(f.board.changeCount == generation && f.store.clipboard.payload == nil)
        #expect(f.store.nameEdit == nil)
    }

    @Test func openingNameEditorInvalidatesPriorMenuSnapshot() async throws {
        let f = try await P18Fixture.make(); defer { f.close() }
        let item = f.items[1]; f.select([item])
        let snapshot = ContextMenuSnapshot(store: f.store, item: item)
        #expect(snapshot.matches(f.store))
        f.store.beginRename()
        #expect(!snapshot.matches(f.store))
    }

    @Test func panelRoutingIdentityRefusalKeepsExistingExplanation() async throws {
        let f = try await P18Fixture.make(); defer { f.close() }
        let item = f.items[1]; f.select([item])
        let router = P18Router(); f.store.applications = router
        let controller = FileContextMenuController(store: f.store)
        let menu = try #require(controller.menu(for: item) as? ContextCommandMenu)
        let open = try #require(menu.item(withTitle: "Open"))
        f.store.validateRoutingTarget = { _ in false }
        let session = ContextMenuActionSession(menu: menu, controller: controller)
        #expect(session.activate(open))
        try await p18Wait { session.state == .cancelled }
        #expect(router.defaults.isEmpty && router.opens.isEmpty)
        #expect(f.store.operationNotice == ExplorerStore.changedNotice([item.name]))
    }

    // MAC-MENU-FUP-001: a chosen nonrouting action explains a confirmed
    // identity/unavailability refusal without dispatching or retargeting.
    @Test(arguments: ["cut", "copy", "rename", "share", "moveToTrash"])
    func panelNonroutingIdentityRefusalExplainsWithoutDispatch(_ command: String) async throws {
        let f = try await P18Fixture.make(); defer { f.close() }
        let selected = f.items[1]; f.select([selected])
        f.store.notePermanentDeleteUnavailable()
        let controller = FileContextMenuController(store: f.store)
        let menu = try #require(controller.menu(for: selected) as? ContextCommandMenu)
        let action = try #require(menu.items.first { $0.identifier?.rawValue == "context-" + command })
        f.store.validateRoutingTarget = { _ in false }
        let session = ContextMenuActionSession(menu: menu, controller: controller)
        var shares = 0; session.performShare = { _ in shares += 1 }
        f.board.clearContents(); #expect(f.board.setString("keep before refused action", forType: .string))
        let clipboardGeneration = f.board.changeCount

        #expect(session.activate(action))
        try await p18Wait { session.state == .cancelled }

        #expect(f.store.operationNotice == "An item changed or is no longer available. Nothing was done. Refresh and try again.")
        #expect(f.board.changeCount == clipboardGeneration)
        #expect(f.store.clipboard.payload == nil)
        #expect(f.store.nameEdit == nil && shares == 0)
        let trashed = await f.operations.trashedNames
        #expect(trashed.isEmpty)
        #expect(f.store.currentSelection.selectedIDs == [selected.id])
        #expect(!session.activate(action))
    }

    @Test(arguments: ["cancel", "origin", "selection"])
    func panelNonroutingIdentityRefusalStaysQuietAfterIntentChanges(_ interruption: String) async throws {
        let f = try await P18Fixture.make(); defer { f.close() }
        let selected = f.items[1]; f.select([selected])
        f.store.notePermanentDeleteUnavailable()
        let sentinel = try #require(f.store.operationNotice)
        let controller = FileContextMenuController(store: f.store)
        let menu = try #require(controller.menu(for: selected) as? ContextCommandMenu)
        let copy = try #require(menu.item(withTitle: "Copy"))
        let session = ContextMenuActionSession(menu: menu, controller: controller)
        let gate = P18Gate()
        var validationReturned = false
        f.store.validateRoutingTarget = { _ in
            let result = await gate.wait()
            validationReturned = true
            return result
        }
        var ownsOrigin = true; session.isOriginCurrent = { ownsOrigin }
        f.board.clearContents(); #expect(f.board.setString("keep after abandoned action", forType: .string))
        let clipboardGeneration = f.board.changeCount
        #expect(session.activate(copy))
        try await p18Wait { gate.pending == 1 }
        switch interruption {
        case "cancel": session.cancel()
        case "origin": ownsOrigin = false
        default: f.select([f.items[2]])
        }
        gate.release(false)
        try await p18Wait { validationReturned && session.state == .cancelled }
        await contextCallbacksSettled()

        #expect(f.store.operationNotice == sentinel)
        #expect(f.board.changeCount == clipboardGeneration && f.store.clipboard.payload == nil)
        #expect(f.store.nameEdit == nil)
        let trashed = await f.operations.trashedNames
        #expect(trashed.isEmpty)
        #expect(!session.activate(copy))
    }

    @Test func collectionItemAccessibilityMenuTargetsItsItemAndKeepsSelectedPair() async throws {
        let f = try await P18Fixture.make(); defer { f.close() }
        f.mountCollection()
        let view = try #require(f.coordinator?.collection)
        let first = f.items[1], second = f.items[2]
        let secondCell = try #require(view.item(at: IndexPath(item: 2, section: 0)))
        var targets: [String?] = []
        view.onPresentContextMenu = { item, _, origin, keyboard in
            #expect(origin === view && keyboard)
            targets.append(item?.id)
        }
        f.select([first])
        #expect(secondCell.view.accessibilityPerformShowMenu())
        #expect(targets == [second.id])
        #expect(f.store.currentSelection.selectedIDs == [second.id])
        f.select([first, second])
        #expect(view.showItemContextMenu(itemID: first.id))
        #expect(targets == [second.id, first.id])
        #expect(f.store.currentSelection.selectedIDs == Set([first.id, second.id]))
        #expect(f.store.currentSelection.focusedID == first.id)
        #expect(!view.showItemContextMenu(itemID: "missing-context-target"))
        #expect(targets.count == 2)
        view.onPresentContextMenu = nil
    }

    // MR-MENU-003 / MT-MENU-05: an old invocation must never acquire authority
    // over the new selection merely because its command is still enabled.
    @Test(arguments: ["Cut", "Copy", "Rename"])
    func staleSelectionMenuCannotRetargetQuickAction(_ command: String) async throws {
        let f = try await P18Fixture.make(); defer { f.close() }
        let controller = FileContextMenuController(store: f.store)
        let original = f.items[1], replacementSelection = f.items[2]
        f.select([original])
        let stale = controller.menu(for: original)
        f.board.clearContents()
        #expect(f.board.setString("untouched clipboard", forType: .string))
        let clipboardGeneration = f.board.changeCount

        f.select([replacementSelection])
        try invoke(stale, command)

        #expect(f.board.changeCount == clipboardGeneration)
        #expect(f.board.string(forType: .string) == "untouched clipboard")
        #expect(f.store.clipboard.payload == nil)
        #expect(f.store.nameEdit == nil)
        #expect(f.store.currentSelection.selectedIDs == [replacementSelection.id])
    }

    @Test func menuFromAnotherTabCannotCopyEvenWithIdenticalSelection() async throws {
        let f = try await P18Fixture.make(); defer { f.close() }
        let controller = FileContextMenuController(store: f.store)
        let selected = f.items[1]
        f.select([selected])
        let originalTab = f.store.activeTab
        let stale = controller.menu(for: selected)
        f.board.clearContents()
        #expect(f.board.setString("keep tab boundary", forType: .string))
        let clipboardGeneration = f.board.changeCount

        var other = BrowserTab(url: originalTab.url)
        other.items = originalTab.items
        other.directoryIdentity = originalTab.directoryIdentity
        other.selection = originalTab.selection
        other.hasLoaded = true
        f.store.tabs.append(other)
        f.store.activeTabID = other.id
        #expect(f.store.canCopySelection)
        try invoke(stale, "Copy")

        #expect(f.board.changeCount == clipboardGeneration)
        #expect(f.board.string(forType: .string) == "keep tab boundary")
        #expect(f.store.clipboard.payload == nil)
        #expect(f.store.activeTabID == other.id)
    }

    @Test func menuCannotRenameSamePathReplacement() async throws {
        let f = try await P18Fixture.make(); defer { f.close() }
        let controller = FileContextMenuController(store: f.store)
        let original = f.items[1]
        f.select([original])
        let stale = controller.menu(for: original)
        let replacement = FileItem(url: original.url, name: original.name,
            isDirectory: false, isSymbolicLink: false, size: original.size,
            modifiedAt: original.modifiedAt, kind: original.kind,
            identity: P18Fixture.identity(9_401))
        f.store.tabs[0].items[1] = replacement
        #expect(f.store.canRenameSelection)
        #expect(replacement.id == original.id && replacement.identity != original.identity)

        try invoke(stale, "Rename")

        #expect(f.store.nameEdit == nil)
        #expect(f.store.currentSelection.selectedIDs == [original.id])
        #expect(f.store.activeTab.items[1].identity == replacement.identity)
    }

    // Stage 4: eligible OneDrive files expose distinct retention commands.
    // Baseline-compatible RED: this only uses the existing menu API.
    @Test func oneDriveCandidateExposesDistinctBoundRetentionCommands() async throws {
        let root = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/CloudStorage/OneDrive-MenuValidation", isDirectory: true)
        let cloud = FileItem(url: root.appendingPathComponent("retention.txt"), name: "retention.txt",
            isDirectory: false, isSymbolicLink: false, size: 65_536, modifiedAt: nil, kind: "Text",
            identity: P18Fixture.identity(8_101), availability: .availableLocally, isRegularFile: true)
        let loader = DownloadMenuLoader(result: DirectorySnapshot(items: [cloud], directoryIdentity: P18Fixture.identity(8_100)))
        let board = NSPasteboard(name: NSPasteboard.Name("retention-menu-\(UUID().uuidString)"))
        let store = ExplorerStore(initialURL: root, loader: loader, homeURL: root,
            clipboard: TransferClipboard(pasteboard: board))
        defer { store.cancelLoads(); board.releaseGlobally() }
        try await p18Wait { store.activeTab.hasLoaded && !store.activeTab.isLoading }
        store.setSelection([cloud.id], focusedID: cloud.id)
        let menu = try #require(FileContextMenuController(store: store).menu(for: cloud) as? ContextCommandMenu)
        for (identifier, title) in [("context-oneDriveKeep", "Always Keep on This Device"),
                                    ("context-oneDriveFreeSpace", "Free Up Space")] {
            let row = try #require(menu.items.first { $0.identifier?.rawValue == identifier })
            #expect(row.title == title && row.target is ContextMenuBinding && row.action != nil)
            #expect(row.state == .off, "Residency is not a persistent retention policy")
        }
    }

    @Test func unknownOneDriveReasonReachesEachDisabledAccessibleBodyButton() async throws {
        let root = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/CloudStorage/OneDrive-MenuValidation", isDirectory: true)
        let cloud = FileItem(url: root.appendingPathComponent("retention.txt"), name: "retention.txt",
            isDirectory: false, isSymbolicLink: false, size: 65_536, modifiedAt: nil, kind: "Text",
            identity: P18Fixture.identity(8_101), availability: .availableLocally, isRegularFile: true)
        let loader = DownloadMenuLoader(result: DirectorySnapshot(items: [cloud], directoryIdentity: P18Fixture.identity(8_100)))
        let store = ExplorerStore(initialURL: root, loader: loader, oneDriveRetentionProvider: RunningRetentionMenuProvider(state: .unknown))
        defer { store.cancelLoads() }
        try await p18Wait { store.activeTab.hasLoaded && !store.activeTab.isLoading }
        store.setSelection([cloud.id], focusedID: cloud.id)
        let controller = FileContextMenuController(store: store)
        let menu = try #require(controller.menu(for: cloud) as? ContextCommandMenu)
        let source = contextTestWindow(), panel = contextTestWindow()
        defer { source.close(); panel.close() }
        let presentation = FileContextMenuPanelController(controller: controller, menu: menu,
            origin: try #require(source.contentView), point: NSPoint(x: 10, y: 200), keyboard: true,
            panel: panel, panelFactory: { contextTestWindow() }, isApplicationActive: { true })
        presentation.show(); defer { presentation.dismiss(reason: .replacement) }
        let reason = "OneDrive’s running state could not be verified. Try again, or manage this file in Finder."
        for identifier in ["context-oneDriveKeep", "context-oneDriveFreeSpace"] {
            let button = try #require(contextButtons(in: panel).first { $0.identifier?.rawValue == identifier })
            #expect(button.toolTip == reason && button.accessibilityHelp() == reason)
            #expect(!button.accessibilityPerformPress() && store.cloudCommandProgress == nil)
        }
    }

    // FR-CLOUD-006: explicit Download uses the existing bound body-command path.
    @Test func onlineOnlySingleFileExposesDownloadAsBoundBodyCommand() async throws {
        let f = try await P18Fixture.make(); defer { f.close() }
        let original = f.items[1]
        let cloud = FileItem(url: original.url, name: original.name, isDirectory: false,
            isSymbolicLink: false, size: original.size, modifiedAt: original.modifiedAt,
            kind: original.kind, identity: original.identity, availability: .onlineOnly, isRegularFile: true)
        f.store.tabs[0].items[1] = cloud
        f.select([cloud])
        let controller = FileContextMenuController(store: f.store)
        let menu = try #require(controller.menu(for: cloud) as? ContextCommandMenu)
        let download = try #require(menu.items.first { $0.identifier?.rawValue == "context-download" })
        #expect(download.title == "Download")
        #expect(download.isEnabled && controller.commandIsEnabled(download, in: menu))
        #expect(download.target is ContextMenuBinding && download.action != nil)
        #expect(download.keyEquivalent.isEmpty)
        let navigation = ContextMenuNavigation(menu: menu, keyboard: true)
        #expect(!navigation.rowItems.contains { $0 === download })
        #expect(navigation.bodyItems(at: 0).contains { $0 === download })
    }

    @Test(arguments: ["unknownRegularity", "folder", "package", "link", "resident", "archive", "multiple", "background"])
    func unsupportedSelectionsOmitDownload(_ scenario: String) async throws {
        let f = try await P18Fixture.make(); defer { f.close() }
        let original = f.items[1]
        var url = original.url
        if scenario == "archive" {
            url = try ArchiveLocation(archiveURL: f.root.appendingPathComponent("fixture.zip"), components: ["cloud.txt"]).url
        }
        let item = FileItem(url: url, name: original.name, isDirectory: scenario == "folder",
            isSymbolicLink: scenario == "link", size: 24, modifiedAt: nil,
            kind: scenario == "package" ? "Application" : "Text", identity: original.identity,
            availability: scenario == "resident" ? .availableLocally : .onlineOnly,
            isRegularFile: scenario == "unknownRegularity" ? nil : !["folder", "package", "link"].contains(scenario))
        f.store.tabs[0].items[1] = item
        f.select(scenario == "background" ? [] : scenario == "multiple" ? [item, f.items[2]] : [item])
        f.store.validateRoutingTarget = { _ in
            Issue.record("Building a menu must not start filesystem validation")
            return true
        }
        let menu = FileContextMenuController(store: f.store).menu(for: scenario == "background" ? nil : item)
        #expect(!menu.items.contains { $0.identifier?.rawValue == "context-download" })
    }

    @Test(arguments: [Optional<Int64>.none, .some(-1), .some(1_073_741_825)])
    func unavailableDownloadSizeKeepsDisabledRowWithAccessibleReason(_ bytes: Int64?) async throws {
        let f = try await P18Fixture.make(); defer { f.close() }
        let cloud = downloadMenuItem(f.items[1], size: bytes)
        f.store.tabs[0].items[1] = cloud; f.select([cloud])
        let controller = FileContextMenuController(store: f.store)
        let menu = try #require(controller.menu(for: cloud) as? ContextCommandMenu)
        let download = try #require(menu.item(withTitle: "Download"))
        #expect(!download.isEnabled && !controller.commandIsEnabled(download, in: menu))
        let reason = try #require(f.store.downloadSelectionAvailability?.disabledReason)
        #expect(!reason.isEmpty && download.toolTip == reason)
        let source = contextTestWindow(), panel = contextTestWindow()
        defer { source.close(); panel.close() }
        let presentation = FileContextMenuPanelController(controller: controller, menu: menu,
            origin: try #require(source.contentView), point: NSPoint(x: 10, y: 200), keyboard: true,
            panel: panel, panelFactory: { contextTestWindow() }, isApplicationActive: { true })
        presentation.show(); defer { presentation.dismiss(reason: .replacement) }
        let button = try #require(contextButtons(in: panel).first { $0.identifier?.rawValue == "context-download" })
        #expect(button.toolTip == reason && button.accessibilityHelp() == reason)
        #expect(!button.accessibilityPerformPress() && f.store.cloudCommandProgress == nil)
    }

    @Test(arguments: ["selection", "identity", "regularity"])
    func staleDownloadMenuCannotAcquireNewAuthority(_ change: String) async throws {
        let f = try await P18Fixture.make(); defer { f.close() }
        let cloud = downloadMenuItem(f.items[1])
        f.store.tabs[0].items[1] = cloud; f.select([cloud])
        let controller = FileContextMenuController(store: f.store)
        let menu = try #require(controller.menu(for: cloud) as? ContextCommandMenu)
        let download = try #require(menu.item(withTitle: "Download"))
        try #require(download.isEnabled)
        if change == "selection" { f.select([f.items[2]]) }
        else {
            f.store.tabs[0].items[1] = FileItem(url: cloud.url, name: cloud.name, isDirectory: false,
                isSymbolicLink: false, size: cloud.size, modifiedAt: nil, kind: cloud.kind,
                identity: change == "identity" ? P18Fixture.identity(9_501) : cloud.identity,
                availability: .onlineOnly, isRegularFile: change == "regularity" ? nil : true)
        }
        #expect(!controller.commandIsEnabled(download, in: menu))
        menu.performActionForItem(at: menu.index(of: download))
        #expect(f.store.cloudCommandProgress == nil && f.store.operationNotice != nil)
    }

    @Test func downloadIdentityRefusalExplainsWithoutDispatch() async throws {
        let f = try await P18Fixture.make(); defer { f.close() }
        let cloud = downloadMenuItem(f.items[1])
        f.store.tabs[0].items[1] = cloud; f.select([cloud])
        let controller = FileContextMenuController(store: f.store)
        let menu = try #require(controller.menu(for: cloud) as? ContextCommandMenu)
        let download = try #require(menu.item(withTitle: "Download"))
        f.store.validateRoutingTarget = { _ in false }
        let session = ContextMenuActionSession(menu: menu, controller: controller)
        #expect(session.activate(download))
        try await p18Wait { session.state == .cancelled }
        #expect(f.store.cloudCommandProgress == nil)
        #expect(f.store.operationNotice == ExplorerStore.changedNotice([cloud.name]))
    }

    @Test(arguments: [false, true])
    func searchDownloadRequiresCapturedPhysicalParent(_ hasParent: Bool) async throws {
        let f = try await P18Fixture.make(); defer { f.close() }
        let cloud = downloadMenuItem(f.items[1])
        let parent = FileOperationContext(directoryURL: f.root, directoryIdentity: try #require(f.store.activeTab.directoryIdentity))
        var search = SearchSession(query: try #require(FilenameSearchQuery(text: "Alpha")), rootURL: f.root, rootTitle: "fixture")
        search.append([FilenameSearchResult(item: cloud, parent: hasParent ? parent : nil)], sort: FileSort())
        search.phase = .complete; f.store.tabs[0].search = search; f.select([cloud])
        let menu = FileContextMenuController(store: f.store).menu(for: cloud)
        let download = menu.items.first { $0.identifier?.rawValue == "context-download" }
        #expect((download != nil) == hasParent)
        if hasParent { #expect(download?.isEnabled == true) }
    }

    @Test(arguments: ["nativeMenu", "accessibility"])
    func downloadRealTargetActionDispatchesOnce(_ route: String) async throws {
        _ = NSApplication.shared
        let root = URL(fileURLWithPath: "/tmp/cloud-menu-\(UUID().uuidString)", isDirectory: true)
        let cloud = FileItem(url: root.appendingPathComponent("cloud.txt"), name: "cloud.txt", isDirectory: false,
            isSymbolicLink: false, size: 24, modifiedAt: nil, kind: "Text", identity: P18Fixture.identity(8_001),
            availability: .onlineOnly, isRegularFile: true)
        let provider = DownloadMenuProvider()
        let loader = DownloadMenuLoader(result: DirectorySnapshot(items: [cloud], directoryIdentity: P18Fixture.identity(8_000)))
        let board = NSPasteboard(name: NSPasteboard.Name("cloud-menu-\(UUID().uuidString)"))
        let store = ExplorerStore(initialURL: root, loader: loader, homeURL: root,
            clipboard: TransferClipboard(pasteboard: board), contentProvider: provider)
        defer { store.cancelLoads(); Task { await provider.stop() }; board.releaseGlobally() }
        try await p18Wait { store.activeTab.hasLoaded && !store.activeTab.isLoading }
        store.validateRoutingTarget = { _ in true }; store.validateRoutingFolder = { _, _ in true }
        store.applications = P18Router(); store.setSelection([cloud.id], focusedID: cloud.id)
        let controller = FileContextMenuController(store: store)
        let menu = try #require(controller.menu(for: cloud) as? ContextCommandMenu)
        let download = try #require(menu.item(withTitle: "Download"))
        #expect(await provider.count == 0, "Menu construction must not request content")
        let session = ContextMenuActionSession(menu: menu, controller: controller)
        if route == "nativeMenu" {
            menu.performActionForItem(at: menu.index(of: download))
            menu.performActionForItem(at: menu.index(of: download))
        } else {
            let button = ContextActionButton(title: download.title, identifier: "context-download")
            button.invoke = { session.activate(download) }
            #expect(button.accessibilityPerformPress())
            #expect(!button.accessibilityPerformPress())
        }
        try await p18Wait { store.cloudCommandProgress != nil }
        let deadline = Date().addingTimeInterval(3)
        while await provider.count == 0, Date() < deadline { try await Task.sleep(for: .milliseconds(1)) }
        #expect(await provider.count == 1)
        #expect(await provider.downloadCount == 1)
        #expect(store.cloudCommandProgress?.itemName == cloud.name)
        let pending = try #require(controller.menu(for: cloud).item(withTitle: "Download"))
        #expect(!pending.isEnabled && pending.toolTip?.isEmpty == false)
        store.cancelCloudCommand(); await provider.stop()
        #expect(store.cloudCommandProgress == nil)
    }

    private func downloadMenuItem(_ original: FileItem, size: Int64? = 24) -> FileItem {
        FileItem(url: original.url, name: original.name, isDirectory: false, isSymbolicLink: false,
            size: size, modifiedAt: original.modifiedAt, kind: original.kind, identity: original.identity,
            availability: .onlineOnly, isRegularFile: true)
    }

    // MAC-077/078; FR-MENU-001/003/006; UI-MENU-001/003/004/006.
    @Test func exactMenusEnablementAndSubmenus() async throws {
        let f = try await P18Fixture.make(); defer { f.close() }
        let controller = FileContextMenuController(store: f.store)
        let files = Array(f.items[1...2]); f.select([files[0]])
        let file = controller.menu(for: files[0])
        #expect(titles(file) == ["Cut", "Copy", "Rename", "Share…", "Move to Trash", "Open", "Open With", "Compress to", "Copy as Pathname", "Properties", "Show in Finder", "Make Alias", "Tags…"])
        #expect(file.items.filter { !$0.isSeparatorItem }.allSatisfy { $0.isEnabled })
        let applications = try child(file, "Open With")
        #expect(titles(applications) == ["Editor (default)", "Viewer", "Other…"])
        #expect(applications.items.filter { $0.image != nil }.map(\.title) == ["Editor (default)", "Viewer"])
        let formats = try child(file, "Compress to")
        #expect(titles(formats) == ["ZIP File", "TAR File"])
        #expect(formats.items.allSatisfy { $0.image == nil })
        for title in ["Open", "Open With", "Compress to", "Copy as Pathname", "Properties"] {
            #expect(file.item(withTitle: title)?.image != nil)
        }
        f.select([f.items[0]])
        let folder = controller.menu(for: f.items[0])
        #expect(titles(folder) == ["Cut", "Copy", "Rename", "Move to Trash", "Open", "Open in New Tab", "Open in New Window", "Pin to Quick access", "Compress to", "Copy as Pathname", "Properties", "Open in Terminal", "Show in Finder", "Make Alias", "Tags…"])
        #expect(folder.items.filter { !$0.isSeparatorItem }.allSatisfy { $0.isEnabled })
        for title in ["Open", "Open in New Tab", "Open in New Window", "Pin to Quick access", "Open in Terminal"] {
            #expect(folder.item(withTitle: title)?.image != nil)
        }
        f.select(files); let multiple = controller.menu(for: files[0])
        #expect(titles(multiple) == ["Cut", "Copy", "Rename", "Share…", "Move to Trash", "Open", "Compress to", "Copy as Pathname", "Properties", "Show in Finder", "Make Alias", "Tags…"])
        #expect(multiple.items.filter { !$0.isSeparatorItem }.allSatisfy { $0.isEnabled })
        f.select([]); let background = controller.menu(for: nil)
        #expect(titles(background) == ["View", "Sort by", "New", "Properties", "Open in Terminal", "Show in Finder"])
        #expect(background.items.filter { !$0.isSeparatorItem }.allSatisfy { $0.isEnabled })
        for title in ["View", "Sort by", "New", "Properties", "Open in Terminal"] {
            #expect(background.item(withTitle: title)?.image != nil)
        }
        let view = try child(background, "View")
        #expect(titles(view) == FolderViewMode.allCases.map(\.title))
        #expect(view.items.count == 8 && view.items.filter { $0.state == .on }.count == 1)
        #expect(view.items.allSatisfy { $0.image != nil })
        #expect(view.items.first { $0.state == .on }?.representedObject as? Int == f.store.activeTab.viewMode.rawValue)
        let sort = try child(background, "Sort by")
        #expect(titles(sort) == ["Name", "Date modified", "Type", "Size", "Ascending", "Descending"])
        #expect(sort.items.filter { $0.state == .on }.map(\.title) == ["Name", "Ascending"])
        #expect(sort.items.allSatisfy { $0.image == nil })
        let new = try child(background, "New")
        #expect(new.items.map(\.title) == ["Folder", "Shortcut", "Bitmap image", "Text Document", "Compressed (zipped) Folder"])
        #expect(new.items.allSatisfy { $0.image != nil })
        for menu in [file, folder, multiple, background] { separators(menu) }
        f.select(files); f.store.copySelection(); f.select([])
        #expect(titles(controller.menu(for: nil)) == ["View", "Sort by", "Paste", "Move Here", "New", "Properties", "Open in Terminal", "Show in Finder"])
    }

    // MAC-077; FR-FILE-023/024/025; FR-MENU-003/004.
    @Test func pathnamePropertiesAndFocusedRenameInvocation() async throws {
        let f = try await P18Fixture.make(); defer { f.close() }
        let c = FileContextMenuController(store: f.store), files = Array(f.items[1...2]); f.select(files)
        var properties: [FileItem] = []; f.store.onShowMultipleProperties = { properties = $0 }
        let menu = c.menu(for: files[0]); try invoke(menu, "Copy as Pathname")
        #expect(f.board.string(forType: .string) == files.map(\.url.path).joined(separator: "\n"))
        try invoke(menu, "Properties"); #expect(properties.map(\.id) == files.map(\.id))
        try invoke(menu, "Rename"); #expect(f.store.nameEdit?.item?.id == files.last?.id)
        f.store.cancelNameEdit(); #expect(f.store.activeTab.selection.selectedIDs == Set(files.map(\.id)))
        var folder: FileItem?; f.store.onShowProperties = { folder = $0 }; f.select([])
        try invoke(c.menu(for: nil), "Properties")
        #expect(folder?.url == f.root && folder?.isDirectory == true && folder?.identity == f.store.activeTab.directoryIdentity)
    }

    // MAC-078; FR-MENU-004/006; FR-FILE-026.
    @Test(arguments: [false, true]) func newTemplatesCommitAndCancel(_ zip: Bool) async throws {
        let f = try await P18Fixture.make(); defer { f.close() }
        let creator = P18Creator(); f.store.fileCreator = creator
        let c = FileContextMenuController(store: f.store)
        let title = zip ? "Compressed (zipped) Folder" : "Text Document"
        let expected = zip ? "New Compressed (zipped) Folder.zip" : "New Text Document.txt"
        try invoke(try child(c.menu(for: nil), "New"), title)
        let draft = try #require(f.store.nameEdit)
        #expect(draft.originalName == expected && draft.newItemKind == .file(zip ? .zipArchive : .textDocument))
        #expect(draft.initialSelection.length == (expected as NSString).deletingPathExtension.utf16.count)
        f.store.cancelNameEdit(); #expect(await creator.calls.isEmpty)
        f.store.tabs[0].items.append(FileItem(url: f.root.appendingPathComponent(expected), name: expected, isDirectory: false, isSymbolicLink: false, size: 0, modifiedAt: nil, kind: "Text"))
        try invoke(try child(c.menu(for: nil), "New"), title)
        #expect(f.store.nameEdit?.originalName == (expected as NSString).deletingPathExtension + " (2)." + (expected as NSString).pathExtension)
        let edit = try #require(f.store.nameEdit); f.store.updateProposedName("Proposed." + (zip ? "zip" : "txt"), sessionID: edit.id)
        f.store.commitNameEdit(sessionID: edit.id); try await p18Wait { !f.store.isPerformingOperation }
        let calls = await creator.calls
        #expect(calls.count == 1 && calls[0].0 == "Proposed." + (zip ? "zip" : "txt") && calls[0].1 == (zip ? .zipArchive : .textDocument))
    }

    // ND-NEW-02: the bitmap command uses the existing inline creation draft.
    @Test func bitmapMenuStartsBasenameDraftAndCancelsWithoutWriting() async throws {
        let f = try await P18Fixture.make(); defer { f.close() }
        let creator = P18Creator(); f.store.fileCreator = creator
        let controller = FileContextMenuController(store: f.store)
        try invoke(try child(controller.menu(for: nil), "New"), "Bitmap image")
        let draft = try #require(f.store.nameEdit)
        #expect(draft.originalName == "New Bitmap image.bmp")
        #expect(draft.initialSelection == NSRange(location: 0, length: "New Bitmap image".utf16.count))
        f.store.cancelNameEdit()
        #expect(f.store.nameEdit == nil)
        #expect(await creator.calls.isEmpty)
    }

    @Test func newSubmenuExposesIndividualAccessibilityActions() async throws {
        let f = try await P18Fixture.make(); defer { f.close() }
        let controller = FileContextMenuController(store: f.store)
        let menu = try #require(controller.menu(for: nil) as? ContextCommandMenu)
        let source = contextTestWindow(), panel = contextTestWindow()
        defer { source.close(); panel.close() }
        let presentation = FileContextMenuPanelController(controller: controller, menu: menu,
            origin: try #require(source.contentView), point: NSPoint(x: 10, y: 200), keyboard: true,
            panel: panel, panelFactory: { contextTestWindow() }, isApplicationActive: { true })
        presentation.show()
        defer { presentation.dismiss(reason: .replacement) }
        let parent = try #require(menu.item(withTitle: "New"))
        let new = try contextButton(parent, in: panel)
        #expect(new.accessibilityPerformPress())
        let children = try #require(parent.submenu).items
        let buttons = try children.map { try contextButton($0, in: panel) }
        #expect(buttons.map { $0.accessibilityIdentifier() } == [
            "context-new-folder", "context-new-shortcut", "context-new-bitmapImage",
            "context-new-textDocument", "context-new-zipArchive"
        ])
        let shortcut = try #require(buttons.first { $0.accessibilityLabel() == "Shortcut" })
        #expect(shortcut.accessibilityPerformPress())
        try await p18Wait { presentation.session.state == .completed }
        #expect(f.store.shortcutDraft != nil && f.store.nameEdit == nil)
    }

    @Test func invalidNewMenuPayloadDoesNotStartFolderDraft() async throws {
        let f = try await P18Fixture.make(); defer { f.close() }
        let controller = FileContextMenuController(store: f.store)
        let menu = try child(controller.menu(for: nil), "New")
        let item = try #require(menu.item(withTitle: "Folder"))
        item.representedObject = "invalid-new-command"
        try invoke(menu, "Folder")
        #expect(f.store.nameEdit == nil)
    }

    @Test func capturedOpenWithChoiceRequiresItsOwnApplicationURL() async throws {
        let f = try await P18Fixture.make(); defer { f.close() }
        let router = P18Router()
        let removed = ApplicationChoice(url: URL(fileURLWithPath: "/tmp/first/Viewer.app"), name: "Viewer", isDefault: false)
        let remaining = ApplicationChoice(url: URL(fileURLWithPath: "/tmp/second/Viewer.app"), name: "Viewer", isDefault: false)
        router.choices = [removed, remaining]
        f.store.applications = router
        let controller = FileContextMenuController(store: f.store), file = f.items[1]
        f.select([file])
        let menu = try #require(controller.menu(for: file) as? ContextCommandMenu)
        let applications = try child(menu, "Open With")
        let captured = applications.items.filter { $0.title == "Viewer" }
        try #require(captured.count == 2)
        router.choices = [remaining]

        #expect(!controller.commandIsEnabled(captured[0], in: menu))
        applications.performActionForItem(at: applications.index(of: captured[0]))
        applications.performActionForItem(at: applications.index(of: captured[1]))

        try await p18Wait { router.opens.contains { $0.1 == remaining.url } }
        await contextCallbacksSettled()
        #expect(router.opens.map { $0.1 } == [remaining.url])
    }

    @Test func capturedOpenWithChoiceSurvivesDisplayNameAndDefaultChange() async throws {
        let f = try await P18Fixture.make(); defer { f.close() }
        let router = P18Router()
        let choice = router.choices[0]
        f.store.applications = router
        let controller = FileContextMenuController(store: f.store), file = f.items[1]
        f.select([file])
        let menu = try #require(controller.menu(for: file) as? ContextCommandMenu)
        let row = try #require(try child(menu, "Open With").item(withTitle: "Editor (default)"))
        router.choices = [ApplicationChoice(url: choice.url, name: "New Editor", isDefault: false)]
        router.applicationQueries.removeAll()
        router.applicationIconQueries.removeAll()
        let session = ContextMenuActionSession(menu: menu, controller: controller)

        try #require(session.activate(row))
        try await p18Wait { session.state == .completed && router.opens.count == 1 }

        #expect(router.opens.first?.1 == choice.url)
        #expect(!router.applicationQueries.isEmpty)
        #expect(router.applicationQueries.allSatisfy { $0 == file.url })
        #expect(router.applicationIconQueries.isEmpty)
    }

    @Test func panelRefusesOpenWithChoiceWithdrawnDuringFileValidation() async throws {
        let f = try await P18Fixture.make(); defer { f.close() }
        let router = P18Router()
        let choice = router.choices[1]
        f.store.applications = router
        let controller = FileContextMenuController(store: f.store), file = f.items[1]
        f.select([file])
        let menu = try #require(controller.menu(for: file) as? ContextCommandMenu)
        let row = try #require(try child(menu, "Open With").item(withTitle: "Viewer"))
        let gate = P18Gate()
        f.store.validateRoutingTarget = { _ in await gate.wait() }
        let session = ContextMenuActionSession(menu: menu, controller: controller)
        try #require(session.activate(row))
        try await p18Wait { gate.pending == 1 }

        router.choices = [ApplicationChoice(url: URL(fileURLWithPath: "/tmp/second/Viewer.app"),
                                            name: choice.name, isDefault: choice.isDefault)]
        f.store.validateRoutingTarget = { _ in true }
        gate.release(true)

        try await p18Wait { session.state == .cancelled || session.state == .completed }
        #expect(session.state == .cancelled)
        #expect(router.opens.isEmpty)
    }

    @Test func panelRefusesCapturedPasteAfterClipboardClears() async throws {
        let f = try await P18Fixture.make(); defer { f.close() }
        f.select([f.items[1]])
        f.store.copySelection()
        f.select([])
        let controller = FileContextMenuController(store: f.store)
        let menu = try #require(controller.menu(for: nil) as? ContextCommandMenu)
        let paste = try #require(menu.item(withTitle: "Paste"))
        #expect(paste.isEnabled)
        let session = ContextMenuActionSession(menu: menu, controller: controller)

        f.board.clearContents()
        #expect(menu.snapshot.matches(f.store))
        #expect(!session.activate(paste))
        #expect(session.state == .open)
    }

    @Test func panelRefusesCapturedPinAfterFolderIsPinnedDuringValidation() async throws {
        let f = try await P18Fixture.make(); defer { f.close() }
        let folder = f.items[0]
        let files = FileManager.default
        try #require(!files.fileExists(atPath: f.root.path))
        try files.createDirectory(at: f.root, withIntermediateDirectories: false)
        defer { try? files.removeItem(at: f.root) }
        try files.createDirectory(at: folder.url, withIntermediateDirectories: false)

        f.select([folder])
        let controller = FileContextMenuController(store: f.store)
        let menu = try #require(controller.menu(for: folder) as? ContextCommandMenu)
        let pin = try #require(menu.item(withTitle: "Pin to Quick access"))
        try #require(controller.commandIsEnabled(pin, in: menu))
        let gate = P18Gate()
        f.store.validateRoutingTarget = { _ in await gate.wait() }
        let session = ContextMenuActionSession(menu: menu, controller: controller)
        defer {
            session.cancel()
            gate.release(false)
        }

        try #require(session.activate(pin))
        try await p18Wait { gate.pending == 1 }
        try #require(f.store.pins.pin(folder.url))
        try #require(f.store.pins.contains(folder.url))
        gate.release(true)

        try await p18Wait { session.state == .cancelled || session.state == .completed }
        #expect(session.state == .cancelled)
        #expect(menu.snapshot.matches(f.store))
        #expect(f.store.operationNotice == nil)
        #expect(f.store.pins.contains(folder.url))
    }

    @Test(arguments: ["Open in New Tab", "Open in New Window", "Open in Terminal"])
    func panelRefusesCapturedFolderCommandAfterEnteringRecovery(_ title: String) async throws {
        let f = try await P18Fixture.make(); defer { f.close() }
        let folder = f.items[0]
        f.select([folder])
        let router = P18Router()
        f.store.applications = router
        var openedWindows: [URL] = []
        f.store.onOpenWindow = { url, key in
            #expect(key == nil)
            openedWindows.append(url)
        }
        var validationCalls = 0
        f.store.validateRoutingTarget = { _ in
            await MainActor.run { validationCalls += 1 }
            return true
        }
        f.store.validateRoutingFolder = { _, _ in
            await MainActor.run { validationCalls += 1 }
            return true
        }
        let tabIDs = f.store.tabs.map(\.id)
        let activeTabID = f.store.activeTabID
        let selection = f.store.currentSelection
        let controller = FileContextMenuController(store: f.store)
        let menu = try #require(controller.menu(for: folder) as? ContextCommandMenu)
        let command = try #require(menu.item(withTitle: title))
        try #require(controller.commandIsEnabled(command, in: menu))
        let session = ContextMenuActionSession(menu: menu, controller: controller)
        defer { session.cancel() }

        f.store.showRecovery()
        try #require(f.store.isShowingRecovery)
        try #require(menu.snapshot.matches(f.store))
        #expect(f.store.currentSelection.selectedIDs == selection.selectedIDs)
        #expect(f.store.currentSelection.focusedID == selection.focusedID)
        #expect(!session.activate(command))
        #expect(session.state == .open)
        #expect(validationCalls == 0)
        #expect(f.store.tabs.map(\.id) == tabIDs && f.store.activeTabID == activeTabID)
        #expect(openedWindows.isEmpty && router.terminals.isEmpty)
    }

    @Test func panelRefusesUnboundCommandAndAcceptsItsNativeShareItem() async throws {
        let f = try await P18Fixture.make(); defer { f.close() }
        let file = f.items[1]
        f.select([file])
        let controller = FileContextMenuController(store: f.store)
        let menu = try #require(controller.menu(for: file) as? ContextCommandMenu)
        let copy = try #require(menu.item(withTitle: "Copy"))
        let unbound = NSMenuItem(title: copy.title, action: nil, keyEquivalent: copy.keyEquivalent)
        unbound.identifier = copy.identifier
        unbound.keyEquivalentModifierMask = copy.keyEquivalentModifierMask
        unbound.isEnabled = true
        let refusedSession = ContextMenuActionSession(menu: menu, controller: controller)
        #expect(!refusedSession.activate(unbound))
        if refusedSession.state != .open { refusedSession.cancel() }
        let share = try #require(menu.items.first { $0.identifier?.rawValue == "context-share" })
        let unboundShare = NSMenuItem(title: share.title, action: nil, keyEquivalent: share.keyEquivalent)
        unboundShare.identifier = share.identifier
        unboundShare.isEnabled = true
        let refusedShareSession = ContextMenuActionSession(menu: menu, controller: controller)
        #expect(!refusedShareSession.activate(unboundShare))
        if refusedShareSession.state != .open { refusedShareSession.cancel() }
        let shareSession = ContextMenuActionSession(menu: menu, controller: controller)
        var sharedIDs: [String] = []
        shareSession.performShare = { sharedIDs = $0.map(\.id) }

        try #require(shareSession.activate(share))
        try await p18Wait { shareSession.state == .completed }
        #expect(sharedIDs == [file.id])
    }

    @Test func panelCopyDoesNotQueryApplicationChoicesOrIcons() async throws {
        let f = try await P18Fixture.make(); defer { f.close() }
        let router = P18Router()
        f.store.applications = router
        let controller = FileContextMenuController(store: f.store), file = f.items[1]
        f.select([file])
        let menu = try #require(controller.menu(for: file) as? ContextCommandMenu)
        let copy = try #require(menu.item(withTitle: "Copy"))
        #expect(!router.applicationQueries.isEmpty && !router.applicationIconQueries.isEmpty)
        router.applicationQueries.removeAll()
        router.applicationIconQueries.removeAll()
        let session = ContextMenuActionSession(menu: menu, controller: controller)

        try #require(session.activate(copy))
        try await p18Wait { session.state == .completed }

        #expect(f.store.clipboard.payload != nil)
        #expect(router.applicationQueries.isEmpty)
        #expect(router.applicationIconQueries.isEmpty)
    }

    // MAC-078; FR-MENU-001/003/004.
    @Test func routerInvocationsUseMenuPayloads() async throws {
        let f = try await P18Fixture.make(); defer { f.close() }
        let router = P18Router(); f.store.applications = router
        let c = FileContextMenuController(store: f.store), file = f.items[1]
        f.select([file]); let apps = try child(c.menu(for: file), "Open With")
        try invoke(apps, "Editor (default)"); try await p18Wait { router.opens.count == 1 }
        #expect(router.opens[0].0 == [file.url] && router.opens[0].1 == router.choices[0].url)
        let previousNotice = f.store.operationNotice
        try invoke(apps, "Other…")
        #expect(router.opens.count == 1 && router.associations.isEmpty)
        #expect(f.store.operationNotice == previousNotice)
        let application = router.choices[1].url
        router.chosen = ApplicationPickerSelection(applicationURL: application, scope: .once)
        try invoke(apps, "Other…")
        try await p18Wait { router.opens.count == 2 }
        #expect(router.opens[1].0 == [file.url] && router.opens[1].1 == application)
        #expect(router.chooserDocuments == [file.url, file.url])
        #expect(router.associations.isEmpty && router.typeAssociations.isEmpty)
        f.select(Array(f.items[1...2])); try invoke(c.menu(for: file), "Open")
        try await p18Wait { !router.defaults.isEmpty }
        #expect(router.defaults == Array(f.items[1...2]).map(\.url))
        let folder = f.items[0]; f.select([folder]); let menu = c.menu(for: folder)
        try invoke(menu, "Open in Terminal"); try invoke(menu, "Show in Finder")
        try await p18Wait { router.terminals.count == 1 }; #expect(router.terminals == [folder.url] && router.revealed == [folder.url])
        f.select([]); let background = c.menu(for: nil)
        try invoke(background, "Open in Terminal"); try invoke(background, "Show in Finder")
        try await p18Wait { router.terminals.count == 2 }; #expect(router.terminals.last == f.root && router.revealed == [f.root])
        f.select([folder, file]); try invoke(c.menu(for: folder), "Open")
        try await p18Wait { f.store.tabs.count == 2 }
        #expect(f.store.activeTab.url == folder.url && router.defaults == [file.url])
    }

    @Test(arguments: [false, true]) func otherPreservesOriginalTabAcrossModal(_ checked: Bool) async throws {
        let f = try await P18Fixture.make(); defer { f.close() }
        let file = f.items[1], originalTab = f.store.activeTabID
        f.store.duplicateTab(originalTab)
        try await p18Wait { !f.store.activeTab.isLoading }
        let otherTab = f.store.activeTabID
        try #require(otherTab != originalTab && f.store.activeTab.url == f.root)
        f.select([file])
        f.store.activateTab(originalTab)
        f.select([file])

        let router = P18Router()
        f.store.applications = router
        router.chosen = ApplicationPickerSelection(applicationURL: router.choices[1].url, scope: checked ? .file : .once)
        router.onChoose = { f.store.activateTab(otherTab) }
        defer { router.onChoose = nil }
        let controller = FileContextMenuController(store: f.store)
        try invoke(child(controller.menu(for: file), "Open With"), "Other…")

        try await p18Wait { f.store.operationNotice != nil }
        #expect(f.store.activeTabID == otherTab && f.store.openWithTarget?.id == file.id)
        #expect(f.store.operationNotice?.lowercased().contains("default was not changed") == checked)
        #expect(router.chooserDocuments == [file.url])
        #expect(router.associations.isEmpty && router.openAttempts.isEmpty)
    }

    @Test func otherRejectsFileChangeBeforeAssignment() async throws {
        let f = try await P18Fixture.make(); defer { f.close() }
        let file = f.items[1], router = P18Router(), validation = P18Gate()
        f.store.applications = router
        f.store.validateRoutingTarget = { _ in await validation.wait() }
        defer { validation.release(false) }
        f.select([file])
        router.chosen = ApplicationPickerSelection(applicationURL: router.choices[1].url, scope: .file)

        f.store.chooseApplicationAndOpen(file)
        try await p18Wait { validation.pending == 1 }
        #expect(router.associations.isEmpty && router.openAttempts.isEmpty)
        validation.release(false)

        try await p18Wait { f.store.operationNotice != nil }
        #expect(f.store.operationNotice?.lowercased().contains("default was not changed") == true)
        #expect(router.associations.isEmpty && router.openAttempts.isEmpty)
    }

    enum PostAssignmentCheck: CaseIterable { case current, selectionChanged, entryChanged }

    @Test(arguments: PostAssignmentCheck.allCases)
    func otherRevalidatesAfterAssignment(_ outcome: PostAssignmentCheck) async throws {
        let f = try await P18Fixture.make(); defer { f.close() }
        let file = f.items[1], router = P18Router(), validation = P18Gate(), association = P18Gate()
        let application = router.choices[1].url
        f.store.applications = router
        f.store.validateRoutingTarget = { _ in await validation.wait() }
        router.associationGate = association
        defer { validation.release(false); association.release(false) }
        f.select([file])
        router.chosen = ApplicationPickerSelection(applicationURL: application, scope: .file)

        f.store.chooseApplicationAndOpen(file)
        try await p18Wait { validation.pending == 1 }
        validation.release(true)
        try await p18Wait { association.pending == 1 }
        #expect(router.associations.count == 1 && router.associations.first?.file == file.url)
        #expect(router.associations.first?.application == application && router.openAttempts.isEmpty)
        #expect(f.store.openWithTarget == nil)
        f.store.chooseApplicationAndOpen(file)
        f.store.open(file, withApplicationAt: application)
        #expect(f.store.operationNotice?.contains("already in progress") == true)
        #expect(router.chooserDocuments == [file.url])
        #expect(router.associations.count == 1 && router.openAttempts.isEmpty)

        let otherFile = f.items[2]
        f.select([otherFile])
        #expect(f.store.openWithTarget?.id == otherFile.id)
        if outcome != .selectionChanged { f.select([file]) }
        association.release(true)
        try await p18Wait { validation.pending == 1 }
        #expect(router.openAttempts.isEmpty)
        validation.release(outcome != .entryChanged)

        if outcome != .current {
            try await p18Wait { f.store.operationNotice?.lowercased().contains("was already set") == true }
            #expect(router.openAttempts.isEmpty)
        } else {
            try await p18Wait { router.opens.count == 1 }
            #expect(router.opens.first?.0 == [file.url] && router.opens.first?.1 == application)
        }
        #expect(router.associations.count == 1)
        f.select([file])
        #expect(f.store.openWithTarget?.id == file.id)
    }

    @Test(arguments: [false, true]) func otherReportsWhichOperationFailed(_ assignmentFails: Bool) async throws {
        let f = try await P18Fixture.make(); defer { f.close() }
        let file = f.items[1], router = P18Router()
        f.store.applications = router
        f.select([file])
        router.chosen = ApplicationPickerSelection(applicationURL: router.choices[1].url, scope: .file)
        if assignmentFails { router.associationError = CocoaError(.userCancelled) }
        else { router.openError = CocoaError(.fileReadNoPermission) }

        f.store.chooseApplicationAndOpen(file)
        try await p18Wait { f.store.operationNotice != nil }

        #expect(router.associations.count == 1)
        #expect(router.openAttempts == (assignmentFails ? [] : [file.url]))
        #expect(router.opens.isEmpty)
        #expect(f.store.openWithTarget?.id == file.id)
        let notice = try #require(f.store.operationNotice).lowercased()
        if assignmentFails { #expect(notice.contains("could not set")) }
        else { #expect(notice.contains("was already set") && notice.contains("could not open")) }
    }

    @Test(arguments: [false, true]) func otherCannotAssignAnUnverifiableFile(_ symlink: Bool) async throws {
        let f = try await P18Fixture.make(); defer { f.close() }
        let source = f.items[1], router = P18Router()
        let file = FileItem(url: source.url, name: source.name, isDirectory: false, isSymbolicLink: symlink,
                            size: source.size, modifiedAt: source.modifiedAt, kind: source.kind,
                            identity: symlink ? source.identity : nil)
        f.store.tabs[0].items[1] = file
        f.store.applications = router
        f.select([file])
        let application = router.choices[1].url
        router.chosen = ApplicationPickerSelection(applicationURL: application, scope: .file)
        f.store.chooseApplicationAndOpen(file)
        try await p18Wait { f.store.operationNotice != nil }
        #expect(router.chooserAllowsAssociation == [false])
        #expect(router.associations.isEmpty && router.openAttempts.isEmpty)

        router.chosen = ApplicationPickerSelection(applicationURL: application, scope: .once)
        f.store.chooseApplicationAndOpen(file)
        try await p18Wait { router.opens.count == 1 }
        #expect(router.chooserAllowsAssociation == [false, false])
        #expect(router.associations.isEmpty && router.openAttempts == [file.url])
    }

    enum InvalidTypeChoice: CaseIterable { case unavailable, forged, changedAfterPicker, staleOrigin, staleIdentity }

    @Test(arguments: InvalidTypeChoice.allCases)
    func otherRejectsInvalidOrStaleTypeChoice(_ outcome: InvalidTypeChoice) async throws {
        let f = try await P18Fixture.make(); defer { f.close() }
        let file = f.items[1], router = P18Router()
        f.store.applications = router
        let original = f.store.activeTabID
        f.store.duplicateTab(original)
        try await p18Wait { !f.store.activeTab.isLoading }
        let other = f.store.activeTabID
        f.select([file])
        f.store.activateTab(original)
        f.select([file])

        if outcome == .unavailable { router.eligibleType = nil }
        let validation = P18Gate()
        defer { validation.release(false) }
        if outcome == .staleIdentity { f.store.validateRoutingTarget = { _ in await validation.wait() } }
        router.chosen = ApplicationPickerSelection(applicationURL: router.choices[1].url,
                                                   scope: .fileType(outcome == .forged ? .png : .plainText))
        router.onChoose = { [weak store = f.store, weak router] in
            if outcome == .changedAfterPicker { router?.eligibleType = .png }
            if outcome == .staleOrigin { store?.activateTab(other) }
        }
        f.store.chooseApplicationAndOpen(file)
        if outcome == .staleIdentity {
            try await p18Wait { validation.pending == 1 }
            validation.release(false)
        }
        try await p18Wait { f.store.operationNotice != nil }

        #expect(router.chooserTypes == [outcome == .unavailable ? nil : .plainText])
        #expect(router.typeAssociations.isEmpty && router.associations.isEmpty && router.openAttempts.isEmpty)
    }

    enum TypeAssignmentOutcome: CaseIterable { case success, setterFailed, staleAfterSuccess, launchFailed }

    @Test(arguments: TypeAssignmentOutcome.allCases)
    func otherAssignsOnlyExactTypeBeforeOpening(_ outcome: TypeAssignmentOutcome) async throws {
        let f = try await P18Fixture.make(); defer { f.close() }
        let file = f.items[1], router = P18Router(), gate = P18Gate()
        let application = router.choices[1].url
        f.store.applications = router
        f.select([file])
        router.chosen = ApplicationPickerSelection(applicationURL: application, scope: .fileType(.plainText))
        router.associationGate = gate
        defer { gate.release(false) }
        if outcome == .launchFailed { router.openError = CocoaError(.fileReadNoPermission) }

        let controller = FileContextMenuController(store: f.store)
        try invoke(child(controller.menu(for: file), "Open With"), "Other…")
        try await p18Wait { gate.pending == 1 }
        #expect(router.chooserTypes == [.plainText])
        #expect(router.typeAssociations.count == 1 && router.typeAssociations.first?.type == .plainText)
        #expect(router.typeAssociations.first?.application == application)
        #expect(router.associations.isEmpty && router.openAttempts.isEmpty)
        if outcome == .staleAfterSuccess { f.select([f.items[2]]) }
        gate.release(outcome != .setterFailed)

        if outcome == .success {
            try await p18Wait { router.opens.count == 1 }
            #expect(router.opens.first?.0 == [file.url] && router.opens.first?.1 == application)
        } else {
            try await p18Wait { f.store.operationNotice != nil }
            let notice = try #require(f.store.operationNotice).lowercased()
            #expect(notice.contains("type") || notice.contains(".txt"))
            if outcome == .setterFailed {
                #expect(notice.contains("could not set"))
            } else {
                #expect(notice.contains("already set"))
            }
        }
        #expect(router.openAttempts == (outcome == .success || outcome == .launchFailed ? [file.url] : []))
        #expect(router.associations.isEmpty && router.typeAssociations.count == 1)
    }

    @Test func typeReservationBlocksAnotherStoreUntilTheSetterFinishesAfterTeardown() async throws {
        let reservations = OpenWithTypeReservations()
        var owner: P18Fixture? = try await P18Fixture.make(openWithTypeReservations: reservations)
        defer { owner?.close() }
        let receiver = try await P18Fixture.make(openWithTypeReservations: reservations); defer { receiver.close() }
        let first = P18Router(), second = P18Router(), gate = P18Gate()
        weak var originalStore = owner?.store
        let file = try #require(owner?.items[1])
        owner?.store.applications = first
        owner?.select([file])
        first.chosen = ApplicationPickerSelection(applicationURL: first.choices[1].url, scope: .fileType(.plainText))
        first.associationGate = gate
        defer { gate.release(false) }
        owner?.store.chooseApplicationAndOpen(file)
        try await p18Wait { gate.pending == 1 }

        owner?.close()
        owner = nil
        try await p18Wait { originalStore == nil }

        let sibling = receiver.items[1]
        receiver.store.applications = second
        receiver.select([sibling])
        let app = second.choices[1].url
        second.chosen = ApplicationPickerSelection(applicationURL: app, scope: .fileType(.plainText))
        receiver.store.chooseApplicationAndOpen(sibling)
        try await p18Wait { receiver.store.operationNotice != nil }
        #expect(receiver.store.operationNotice?.contains("already in progress for this file type") == true)
        #expect(second.typeAssociations.isEmpty && second.openAttempts.isEmpty)

        second.eligibleType = .png
        second.chosen = ApplicationPickerSelection(applicationURL: app, scope: .fileType(.png))
        receiver.store.chooseApplicationAndOpen(sibling)
        try await p18Wait { second.opens.count == 1 }
        #expect(second.typeAssociations.map(\.type) == [.png])

        second.chosen = ApplicationPickerSelection(applicationURL: app, scope: .file)
        receiver.store.chooseApplicationAndOpen(sibling)
        try await p18Wait { second.opens.count == 2 }
        #expect(second.associations.count == 1)

        gate.release(false)
        try await p18Wait { first.completedTypeAssociations == [.plainText] }
        #expect(first.openAttempts.isEmpty)

        second.eligibleType = .plainText
        second.chosen = ApplicationPickerSelection(applicationURL: app, scope: .fileType(.plainText))
        receiver.store.chooseApplicationAndOpen(sibling)
        try await p18Wait { second.opens.count == 3 }
        #expect(second.typeAssociations.map(\.type) == [.png, .plainText])
    }

    // MAC-078 (Astra review 4980d3b6 finding 6): routing commands act only on the
    // entry their menu captured, and not after the command became unavailable.
    @Test func staleRoutingTargetsAndDisabledRoutesDoNothing() async throws {
        let f = try await P18Fixture.make(); defer { f.close() }
        let router = P18Router(); f.store.applications = router
        let c = FileContextMenuController(store: f.store), folder = f.items[0], file = f.items[1]
        var checked: [String] = []
        f.store.validateRoutingTarget = { item in await MainActor.run { checked.append(item.name) }; return false }
        f.select([folder]); let folderMenu = c.menu(for: folder)
        try invoke(folderMenu, "Open in New Tab"); try invoke(folderMenu, "Open in New Window"); try invoke(folderMenu, "Open in Terminal")
        var windows: [URL] = []; f.store.onOpenWindow = { url, _ in windows.append(url) }
        try await p18Wait { checked.count == 3 && f.store.operationNotice != nil }
        #expect(f.store.tabs.count == 1 && windows.isEmpty && router.terminals.isEmpty)
        #expect(f.store.operationNotice?.contains("changed since the menu was opened") == true)
        f.select([file]); let apps = try child(c.menu(for: file), "Open With")
        try invoke(apps, "Editor (default)"); try await p18Wait { checked.count == 4 }
        f.select([file, f.items[2]]); try invoke(c.menu(for: file), "Open"); try await p18Wait { checked.count == 6 }
        #expect(router.opens.isEmpty && router.defaults.isEmpty)
        // A captured Open With target that is no longer the store's target is refused before validation.
        f.store.validateRoutingTarget = { _ in true }
        f.select([file]); let stale = try child(c.menu(for: file), "Open With"); f.select([f.items[2]])
        try invoke(stale, "Editor (default)"); try await Task.sleep(for: .milliseconds(50)); #expect(router.opens.isEmpty)
        // The same name now listing another entry is refused with a notice.
        f.store.dismissOperationNotice(); f.select([file]); let replaced = try child(c.menu(for: file), "Open With")
        f.store.tabs[0].items[1] = FileItem(url: file.url, name: file.name, isDirectory: false, isSymbolicLink: false, size: 1, modifiedAt: nil, kind: "Text", identity: P18Fixture.identity(777))
        try invoke(replaced, "Editor (default)"); #expect(router.opens.isEmpty && f.store.operationNotice?.contains("changed since the menu was opened") == true)
        // Background Open in Terminal requires the same folder identity the menu captured.
        f.select([]); let background = c.menu(for: nil)
        f.store.tabs[0].directoryIdentity = P18Fixture.identity(4242)
        try invoke(background, "Open in Terminal"); try await Task.sleep(for: .milliseconds(50)); #expect(router.terminals.isEmpty)
        // Disabled while an editor is open, through the already-built menu.
        f.select([folder]); let disabled = c.menu(for: folder); f.store.beginRename()
        menuAction(disabled, "Open in Terminal"); menuAction(disabled, "Open in New Tab")
        try await Task.sleep(for: .milliseconds(50)); #expect(router.terminals.isEmpty && f.store.tabs.count == 1)
        f.store.cancelNameEdit()
    }

    // MAC-078; FR-MENU-003/004. Explicit continuation holds progress observable until released.
    @Test(arguments: 0..<3) func archiveInvocationSuccessCancellationAndError(_ outcome: Int) async throws {
        let f = try await P18Fixture.make(); defer { f.close() }
        let archive = P18Archive(held: true); f.store.archiver = archive
        let selected = Array(f.items[1...2]); f.select(selected)
        let c = FileContextMenuController(store: f.store)
        let loadsBefore = await f.loader.snapshotCount
        try invoke(try child(c.menu(for: selected[0]), "Compress to"), "ZIP File")
        #expect(f.store.archiveProgress != nil && f.store.isPerformingOperation)
        let deadline = ContinuousClock.now + .seconds(5)
        while await archive.calls.isEmpty, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(1)) }
        let calls = await archive.calls
        try #require(calls.count == 1)
        #expect(calls[0].0.map(\.id) == selected.map(\.id) && calls[0].1 == .zip)
        if outcome == 1 {
            f.store.cancelArchive(); #expect(f.store.archiveProgress?.isCancelling == true)
            let control = try #require(await archive.control)
            #expect(throws: CancellationError.self) { try control.checkpoint() }
        }
        await archive.finish(outcome: outcome, root: f.root)
        try await p18Wait { !f.store.isPerformingOperation && !f.store.activeTab.isLoading }
        #expect(f.store.archiveProgress == nil)
        if outcome == 0 { #expect(f.store.activeTab.hasLoaded); #expect(f.store.operationNotice == "The change completed, but its result is not visible or could not be verified. Refresh to check the folder."); #expect(await f.loader.snapshotCount > loadsBefore) }
        if outcome == 1 { #expect(f.store.operationNotice == "Compression cancelled. No archive was created.") }
        if outcome == 2 { #expect(f.store.operationNotice?.contains("Could not compress") == true) }
    }

    // MAC-077; FR-MENU-007/008/009; UI-MENU-006.
    @Test func collectionTargetingAndShiftF10PreserveKeyboardSelection() async throws {
        let f = try await P18Fixture.make(); defer { f.close() }; f.mountCollection()
        let view = try #require(f.coordinator?.collection)
        let cell = try #require(view.item(at: IndexPath(item: 1, section: 0)))
        let point = view.convert(NSPoint(x: cell.view.frame.midX, y: cell.view.frame.midY), to: nil)
        f.select([f.items[2]]); _ = view.menu(for: try f.mouse(.rightMouseDown, point: point))
        #expect(f.store.currentSelection.selectedIDs == [f.items[1].id])
        f.select(Array(f.items[1...2])); _ = view.menu(for: try f.mouse(.rightMouseDown, point: point))
        #expect(f.store.currentSelection.selectedIDs.count == 2)
        var presented: NSMenu?; view.menuPresenter = { menu, _, _ in presented = menu }
        let event = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .shift, timestamp: 0, windowNumber: f.window!.windowNumber, context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: 109))
        view.keyDown(with: event); #expect(presented?.item(withTitle: "Rename") != nil && f.store.currentSelection.selectedIDs.count == 2)
        _ = view.menu(for: try f.mouse(.rightMouseDown, point: view.convert(NSPoint(x: 500, y: 280), to: nil)))
        #expect(f.store.currentSelection.selectedIDs.isEmpty)
        presented = nil; view.keyDown(with: event); #expect(presented?.item(withTitle: "New") != nil)
        // Production panel seam: existing presenter injection above remains authoritative.
        view.menuPresenter = nil
        var panelRoutes: [(String?, Bool)] = []
        view.onPresentContextMenu = { item, _, origin, keyboard in
            #expect(origin === view)
            panelRoutes.append((item?.id, keyboard))
        }
        f.select(Array(f.items[1...2]))
        view.rightMouseDown(with: try f.mouse(.rightMouseDown, point: point))
        #expect(panelRoutes.last?.0 == f.items[1].id && panelRoutes.last?.1 == false)
        #expect(f.store.currentSelection.selectedIDs.count == 2)
        view.mouseDown(with: try f.mouse(.leftMouseDown, point: point, flags: .control))
        #expect(panelRoutes.count == 2 && panelRoutes.last?.1 == false)
        #expect(view.accessibilityPerformShowMenu())
        #expect(panelRoutes.count == 3 && panelRoutes.last?.1 == true)
        view.rightMouseDown(with: try f.mouse(.rightMouseDown, point: view.convert(NSPoint(x: 500, y: 280), to: nil)))
        #expect(panelRoutes.count == 4 && panelRoutes.last?.0 == nil)
        #expect(f.store.currentSelection.selectedIDs.isEmpty)
        view.onPresentContextMenu = nil
    }

    // MAC-078; FR-MENU-003/004. Partial completion must be reported, not discarded.
    @Test func aliasInvocationReportsPartialCompletion() async throws {
        let f = try await P18Fixture.make(); defer { f.close() }
        let alias = P18Aliases(); f.store.aliasCreator = alias
        let files = Array(f.items[1...2]); f.select(files)
        let c = FileContextMenuController(store: f.store)
        try invoke(c.menu(for: files[0]), "Make Alias")
        try await p18Wait { !f.store.isPerformingOperation }
        #expect(await alias.items.map(\.id) == files.map(\.id))
        #expect(f.store.operationNotice?.contains("Made 1 of 2 aliases") == true)
    }

    // MAC-077; FR-MENU-006; UI-MENU-001/006.
    @Test func successfulRenameShowsUndoThenRedoInBackground() async throws {
        let f = try await P18Fixture.make(); defer { f.close() }
        f.select([f.items[1]]); f.store.beginRename()
        let edit = try #require(f.store.nameEdit)
        f.store.updateProposedName("Renamed.txt", sessionID: edit.id)
        f.store.commitNameEdit(sessionID: edit.id)
        try await p18Wait { !f.store.isPerformingOperation }
        let c = FileContextMenuController(store: f.store); f.select([])
        let undo = c.menu(for: nil)
        #expect(undo.item(withTitle: "Redo Rename") == nil)
        try invoke(undo, "Undo Rename")
        try await p18Wait { !f.store.isPerformingOperation }
        let redo = c.menu(for: nil)
        #expect(redo.item(withTitle: "Undo Rename") == nil)
        try invoke(redo, "Redo Rename")
        try await p18Wait { !f.store.isPerformingOperation }
        #expect(c.menu(for: nil).item(withTitle: "Undo Rename") != nil)
    }

    // MAC-077; FR-MENU-007/008/009; UI-MENU-006. Native table event routing.
    @Test func detailsTargetingAndShiftF10() async throws {
        let f = try await P18Fixture.make(); defer { f.close() }
        let source = P18Rows(), table = ExplorerTableView(frame: NSRect(x: 0, y: 0, width: 600, height: 320))
        table.addTableColumn(NSTableColumn(identifier: NSUserInterfaceItemIdentifier("name")))
        table.dataSource = source; table.itemIDs = f.items.map(\.id); table.reloadData()
        let window = NSWindow(contentRect: table.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = table; defer { window.close() }
        let c = FileContextMenuController(store: f.store)
        table.onSelectionIntent = {
            let ids = Set(table.selectedRowIndexes.map { table.itemIDs[$0] })
            f.store.setSelection(ids, focusedID: table.focusedItemID, anchorID: table.anchorItemID)
        }
        table.onContextMenu = { row in c.menu(for: f.items.indices.contains(row) ? f.items[row] : nil) }
        func context(_ row: Int) throws {
            let point = row < 0 ? NSPoint(x: 30, y: 280) : NSPoint(x: 30, y: table.rect(ofRow: row).midY)
            let event = try #require(NSEvent.mouseEvent(with: .rightMouseDown, location: table.convert(point, to: nil), modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
            _ = table.menu(for: event)
        }
        table.selectRowIndexes(IndexSet(integer: 2), byExtendingSelection: false)
        try context(1); #expect(f.store.currentSelection.selectedIDs == [f.items[1].id])
        table.selectRowIndexes(IndexSet([1, 2]), byExtendingSelection: false)
        try context(1); #expect(f.store.currentSelection.selectedIDs.count == 2)
        var presented: NSMenu?; table.menuPresenter = { menu, _, _ in presented = menu }
        let event = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .shift, timestamp: 0, windowNumber: window.windowNumber, context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: 109))
        table.keyDown(with: event)
        #expect(presented?.item(withTitle: "Rename") != nil && table.selectedRowIndexes == IndexSet([1, 2]))
        try context(-1); #expect(f.store.currentSelection.selectedIDs.isEmpty && table.selectedRowIndexes.isEmpty)
        presented = nil; table.keyDown(with: event); #expect(presented?.item(withTitle: "New") != nil)
        table.menuPresenter = nil
        var panelRoutes: [(Int, Bool)] = []
        table.onPresentContextMenu = { row, _, origin, keyboard in
            #expect(origin === table); panelRoutes.append((row, keyboard))
        }
        table.selectRowIndexes(IndexSet([1, 2]), byExtendingSelection: false)
        let clickPoint = table.convert(NSPoint(x: 30, y: table.rect(ofRow: 1).midY), to: nil)
        let click = try #require(NSEvent.mouseEvent(with: .rightMouseDown, location: clickPoint, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
        table.rightMouseDown(with: click)
        #expect(panelRoutes.last?.0 == 1 && panelRoutes.last?.1 == false)
        #expect(table.selectedRowIndexes == IndexSet([1, 2]))
        #expect(table.accessibilityPerformShowMenu())
        #expect(panelRoutes.count == 2 && panelRoutes.last?.1 == true)
        table.onPresentContextMenu = nil
        table.onSelectionIntent = nil; table.onContextMenu = nil; table.menuPresenter = nil
    }

    private func titles(_ menu: NSMenu) -> [String] { menu.items.filter { !$0.isSeparatorItem }.map(\.title) }
    private func child(_ menu: NSMenu, _ title: String) throws -> NSMenu { try #require(menu.item(withTitle: title)?.submenu) }
    private func invoke(_ menu: NSMenu, _ title: String) throws { let item = try #require(menu.item(withTitle: title)); #expect(item.isEnabled); menu.performActionForItem(at: menu.index(of: item)) }
    // MAC-078 (follow-up 029698a5 findings 8, 9 and 11): an entry replaced while its
    // validation is pending is refused with a notice; background Terminal checks the
    // folder on disk; application-launch failures are reported.
    @Test func deferredValidationReplacementBackgroundFolderAndLaunchFailures() async throws {
        let f = try await P18Fixture.make(); defer { f.close() }
        let router = P18Router(); f.store.applications = router
        let c = FileContextMenuController(store: f.store), folder = f.items[0], file = f.items[1], other = f.items[2]
        let gate = P18Gate(); f.store.validateRoutingTarget = { _ in await gate.wait() }
        // Open With: replaced in the listing while validation is pending.
        f.select([file]); try invoke(try child(c.menu(for: file), "Open With"), "Editor (default)")
        try await p18Wait { gate.pending == 1 }
        f.store.tabs[0].items[1] = FileItem(url: file.url, name: file.name, isDirectory: false, isSymbolicLink: false, size: 1, modifiedAt: nil, kind: "Text", identity: P18Fixture.identity(901))
        gate.release(true); try await p18Wait { f.store.operationNotice != nil }
        #expect(router.opens.isEmpty && f.store.operationNotice?.contains("changed since the menu was opened") == true)
        // Several items: one replaced while the others are still validating.
        f.store.dismissOperationNotice()
        let current = [f.store.tabs[0].items[1], f.store.tabs[0].items[2]]; f.select(current)
        try invoke(c.menu(for: current[0]), "Open"); try await p18Wait { gate.pending == 1 }
        f.store.tabs[0].items[2] = FileItem(url: other.url, name: other.name, isDirectory: false, isSymbolicLink: false, size: 1, modifiedAt: nil, kind: "Text", identity: P18Fixture.identity(902))
        gate.release(true); try await p18Wait { gate.pending == 1 }; gate.release(true)
        try await p18Wait { f.store.operationNotice != nil }
        #expect(router.defaults.isEmpty && f.store.operationNotice?.contains("changed since the menu was opened") == true)
        // Background Open in Terminal: the folder on disk is no longer the displayed one.
        f.store.validateRoutingTarget = { _ in true }
        var folderChecks = 0; f.store.validateRoutingFolder = { _, _ in await MainActor.run { folderChecks += 1 }; return false }
        f.store.dismissOperationNotice(); f.select([]); try invoke(c.menu(for: nil), "Open in Terminal")
        try await p18Wait { f.store.operationNotice != nil }
        #expect(folderChecks == 1 && router.terminals.isEmpty && f.store.operationNotice?.contains("changed since the menu was opened") == true)
        // Launch failures are reported, not swallowed.
        f.store.validateRoutingFolder = { _, _ in true }
        struct LaunchFailure: LocalizedError { var errorDescription: String? { "Launch refused." } }
        router.openError = LaunchFailure(); router.terminalError = LaunchFailure(); router.failsDefaults = true
        let fresh = f.store.tabs[0].items[1]
        f.store.dismissOperationNotice(); f.select([fresh]); try invoke(try child(c.menu(for: fresh), "Open With"), "Editor (default)")
        try await p18Wait { f.store.operationNotice != nil }; #expect(f.store.operationNotice?.contains("Could not open “\(fresh.name)” with Editor. Launch refused.") == true)
        f.store.dismissOperationNotice(); f.select([folder]); try invoke(c.menu(for: folder), "Open in Terminal")
        try await p18Wait { f.store.operationNotice != nil }; #expect(f.store.operationNotice?.hasPrefix("Could not open Terminal at") == true)
        let pair = [f.store.tabs[0].items[1], f.store.tabs[0].items[2]]
        f.store.dismissOperationNotice(); f.select(pair); try invoke(c.menu(for: pair[0]), "Open")
        try await p18Wait { f.store.operationNotice != nil }; #expect(f.store.operationNotice?.hasPrefix("macOS could not open") == true)
    }

    /// Performs an item's action regardless of its (stale) enabled state, as a racing route could.
    private func menuAction(_ menu: NSMenu, _ title: String) {
        guard let item = menu.item(withTitle: title), let action = item.action else { return }
        NSApp.sendAction(action, to: item.target, from: item)
    }
    private func separators(_ menu: NSMenu) {
        #expect(menu.items.first?.isSeparatorItem != true && menu.items.last?.isSeparatorItem != true)
        for pair in zip(menu.items, menu.items.dropFirst()) { #expect(!(pair.0.isSeparatorItem && pair.1.isSeparatorItem)) }
        for item in menu.items { if let submenu = item.submenu, item.title != "Share" { separators(submenu) } }
    }
}

private struct DownloadMenuLoader: DirectoryListing {
    let result: DirectorySnapshot
    func contents(of url: URL, showHidden: Bool) async throws -> [FileItem] { result.items }
    func snapshot(of url: URL, showHidden: Bool) async throws -> DirectorySnapshot { result }
}

private struct RunningRetentionMenuProvider: OneDriveRetentionProviding {
    let state: OneDriveSyncState
    var syncIsRunning: Bool { state == .running }
    var syncState: OneDriveSyncState { state }
    var isBusy: Bool { false }
    func perform(_ action: OneDriveRetentionAction, on entry: TransferEntry,
                 control: TransferControl) async throws -> OneDriveRetentionOutcome {
        Issue.record("A disabled retention command must not dispatch")
        throw OneDriveRetentionError.syncRunning
    }
}

private actor DownloadMenuProvider: ItemContentProviding {
    private(set) var count = 0
    private(set) var downloadCount = 0
    private var pending: [CheckedContinuation<any MaterializedContentLease, Error>] = []
    func materialize(_ request: ContentRequest, control: TransferControl) async throws -> any MaterializedContentLease {
        try control.checkpoint()
        if case .download = request.purpose { downloadCount += 1 }
        count += 1; request.onProgress?(.downloading)
        return try await withCheckedThrowingContinuation { pending.append($0) }
    }
    func stop() {
        let values = pending; pending.removeAll()
        for value in values { value.resume(throwing: CancellationError()) }
    }
}

@MainActor private final class ContextMenuTestPanel: FileActionsPanel {
    var pointerScreen = NSPoint(x: -1000, y: -1000)
    var ownsMainWindow = true
    override var mouseLocationOutsideOfEventStream: NSPoint { convertPoint(fromScreen: pointerScreen) }
    override var isKeyWindow: Bool { true }
    override var isMainWindow: Bool { ownsMainWindow }
    override var isVisible: Bool { true }
    override var canBecomeKey: Bool { true }
    // Exercise the actual panel controller/view lifecycle without ordering a
    // test surface on the desktop or moving the OS pointer.
    override func makeKeyAndOrderFront(_ sender: Any?) { ownsMainWindow = true }
    override func orderFront(_ sender: Any?) {}
}

@MainActor private func contextTestWindow() -> ContextMenuTestPanel {
    let panel = ContextMenuTestPanel(contentRect: NSRect(x: 40, y: 300, width: 600, height: 400),
        styleMask: [.borderless], backing: .buffered, defer: false)
    panel.isReleasedWhenClosed = false
    return panel
}

@MainActor private final class ContextShortcutSentinel: NSObject {
    var invocations = 0
    @objc func unexpectedMainCommand(_ sender: Any?) { invocations += 1 }
}

@MainActor private func contextFallbackMenu(_ character: String, target: ContextShortcutSentinel) -> NSMenu {
    let menu = NSMenu(); menu.autoenablesItems = false
    let item = NSMenuItem(title: "Unexpected main command", action: #selector(ContextShortcutSentinel.unexpectedMainCommand(_:)),
        keyEquivalent: character)
    item.keyEquivalentModifierMask = .command; item.target = target
    menu.addItem(item)
    return menu
}

@MainActor private func contextKey(_ character: String, code: UInt16,
                                  modifiers: NSEvent.ModifierFlags, window: NSWindow,
                                  isRepeat: Bool = false) throws -> NSEvent {
    try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers,
        timestamp: 1, windowNumber: window.windowNumber, context: nil, characters: character,
        charactersIgnoringModifiers: character, isARepeat: isRepeat, keyCode: code))
}

private final class ContextMenuPointerEvent: NSEvent {
    let ownerWindow: NSWindow
    init(window: NSWindow) { ownerWindow = window; super.init() }
    required init?(coder: NSCoder) { fatalError("init(coder:) is unused") }
    override var type: NSEvent.EventType { .mouseMoved }
    override var window: NSWindow? { ownerWindow }
}

@MainActor private func contextButton(_ item: NSMenuItem, in panel: NSPanel) throws -> ContextActionButton {
    return try #require(contextButtons(in: panel).first {
        $0.identifier == item.identifier && $0.accessibilityLabel() == item.title
    })
}

@MainActor private func contextButtons(in panel: NSPanel) -> [ContextActionButton] {
    func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
    let own = panel.contentView.map { descendants($0).compactMap { $0 as? ContextActionButton } } ?? []
    return own + (panel.childWindows ?? []).compactMap { $0 as? NSPanel }.flatMap { contextButtons(in: $0) }
}

@MainActor private func contextCellInk(_ button: NSButton, region: NSRect, dark: Bool,
                                      draw: () -> Void) throws -> (bounds: NSRect, contrast: CGFloat, saturation: CGFloat) {
    let width = Int(ceil(region.width)), height = Int(ceil(region.height))
    let bitmap = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
    let context = try #require(NSGraphicsContext(bitmapImageRep: bitmap))
    NSGraphicsContext.saveGraphicsState()
    defer { NSGraphicsContext.restoreGraphicsState() }
    NSGraphicsContext.current = context
    button.effectiveAppearance.performAsCurrentDrawingAppearance {
        (dark ? NSColor.black : NSColor.white).setFill()
        NSRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height)).fill()
        context.cgContext.translateBy(x: -region.minX, y: -region.minY)
        draw()
    }
    context.flushGraphics()
    var ink = NSRect.null, contrast: CGFloat = 0, saturation: CGFloat = 0
    for y in 0..<height {
        for x in 0..<width {
            guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
            let brightness = (color.redComponent + color.greenComponent + color.blueComponent) / 3
            let difference = dark ? brightness : 1 - brightness
            contrast += difference
            saturation = max(saturation, max(color.redComponent, color.greenComponent, color.blueComponent)
                - min(color.redComponent, color.greenComponent, color.blueComponent))
            if difference > 0.04 { ink = ink.union(NSRect(x: CGFloat(x), y: CGFloat(y), width: 1, height: 1)) }
        }
    }
    #expect(!ink.isNull, "The actual cell drawing must produce visible content")
    return (ink.isNull ? .zero : ink, contrast, saturation)
}

@MainActor private func contextCallbacksSettled() async {
    await withCheckedContinuation { continuation in
        DispatchQueue.main.async { continuation.resume() }
    }
}

@MainActor final class P18Gate {
    private var waiters: [CheckedContinuation<Bool, Never>] = []
    var pending: Int { waiters.count }
    func wait() async -> Bool { await withCheckedContinuation { waiters.append($0) } }
    func release(_ value: Bool) { guard !waiters.isEmpty else { return }; waiters.removeFirst().resume(returning: value) }
}
@MainActor final class P18Router: ApplicationRouting {
    var choices = [ApplicationChoice(url: URL(fileURLWithPath: "/tmp/Editor.app"), name: "Editor", isDefault: true), ApplicationChoice(url: URL(fileURLWithPath: "/tmp/Viewer.app"), name: "Viewer", isDefault: false)]
    var chosen: ApplicationPickerSelection?, opens: [([URL], URL)] = [], terminals: [URL] = [], revealed: [URL] = [], defaults: [URL] = []
    var openError: (any Error)?, terminalError: (any Error)?, failsDefaults = false
    var failedDefaultURLs = Set<URL>()
    var chooserDocuments: [URL] = []
    var chooserAllowsAssociation: [Bool] = []
    var onChoose: (() -> Void)?
    var associations: [(file: URL, application: URL)] = []
    var associationGate: P18Gate?
    var associationError: (any Error)?
    var eligibleType: UTType? = .plainText
    var chooserTypes: [UTType?] = []
    var typeAssociations: [(type: UTType, application: URL)] = []
    var completedTypeAssociations: [UTType] = []
    var openAttempts: [URL] = []
    var applicationQueries: [URL] = []
    var applicationIconQueries: [URL] = []
    func applications(toOpen url: URL) -> [ApplicationChoice] {
        applicationQueries.append(url)
        return choices
    }
    func open(_ urls: [URL], withApplicationAt application: URL) async throws {
        openAttempts += urls
        if let openError { throw openError }
        opens.append((urls, application))
    }
    func openInTerminal(_ folder: URL) async throws { if let terminalError { throw terminalError }; terminals.append(folder) }
    func revealInFinder(_ urls: [URL]) { revealed = urls }
    func eligibleOpenWithType(for file: URL) -> UTType? { eligibleType }
    func chooseApplication(for document: URL, title: String, allowsDefaultAssociation: Bool,
                           eligibleType: UTType?) -> ApplicationPickerSelection? {
        chooserDocuments.append(document)
        chooserTypes.append(eligibleType)
        chooserAllowsAssociation.append(allowsDefaultAssociation)
        onChoose?()
        return chosen
    }
    func setDefaultApplication(at application: URL, forFile file: URL) async throws {
        associations.append((file, application))
        if let associationGate, !(await associationGate.wait()) { throw CocoaError(.userCancelled) }
        if let associationError { throw associationError }
    }
    func setDefaultApplication(at application: URL, forType type: UTType) async throws {
        typeAssociations.append((type, application))
        defer { completedTypeAssociations.append(type) }
        if let associationGate, !(await associationGate.wait()) { throw CocoaError(.userCancelled) }
        if let associationError { throw associationError }
    }
    func icon(forApplicationAt url: URL) -> NSImage {
        applicationIconQueries.append(url)
        return NSImage(size: NSSize(width: 16, height: 16))
    }
    func openWithDefaultApplications(_ urls: [URL]) -> [URL] {
        defaults = urls
        return failsDefaults ? urls : urls.filter { failedDefaultURLs.contains($0) }
    }
}
actor P18Creator: FileCreating {
    var calls: [(String, NewFileTemplate)] = []
    func createFile(named name: String, template: NewFileTemplate, in context: FileOperationContext) async throws -> FileOperationResult {
        calls.append((name, template)); return FileOperationResult(url: context.directoryURL.appendingPathComponent(name), identity: context.directoryIdentity, warning: nil)
    }
}
actor P18Archive: ArchiveCreating {
    var calls: [([FileItem], ArchiveFormat)] = []; var control: TransferControl?
    let held: Bool; var continuation: CheckedContinuation<FileOperationResult, Error>?
    init(held: Bool = false) { self.held = held }
    func compress(_ items: [FileItem], in context: FileOperationContext, format: ArchiveFormat, control: TransferControl) async throws -> FileOperationResult {
        self.control = control; calls.append((items, format))
        if held { return try await withCheckedThrowingContinuation { continuation = $0 } }
        throw CancellationError()
    }
    func finish(outcome: Int, root: URL) {
        if outcome == 0 { continuation?.resume(returning: FileOperationResult(url: root.appendingPathComponent("Archive.zip"), identity: nil, warning: nil)) }
        else { continuation?.resume(throwing: outcome == 1 ? CancellationError() : FileOperationError.unsupported("Synthetic archive failure")) }
        continuation = nil
    }
}

actor P18Aliases: AliasCreating {
    var items: [FileItem] = []
    func makeAliases(for items: [FileItem], in context: FileOperationContext) async throws -> [FileOperationResult] {
        self.items = items
        throw AliasCreationError(completed: [FileOperationResult(url: context.directoryURL.appendingPathComponent("Alpha.txt alias"), identity: context.directoryIdentity, warning: nil)], failedName: items[1].name, cause: "Synthetic partial failure")
    }
}
