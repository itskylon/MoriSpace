import XCTest

final class MoriPhotosUITests: XCTestCase {
    func testDesktopFileBrowserHistoryViewsInspectorAndPreview() {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .landscapeLeft
        defer { XCUIDevice.shared.orientation = .portrait }
        let app = XCUIApplication()
        app.launchArguments = ["--nas-connection-fixture", "--reset-nas-connection-fixture", "--desktop-files-fixture"]
        app.launch()
        let files = app.descendants(matching: .any)["sidebar_files"].firstMatch
        XCTAssertTrue(files.waitForExistence(timeout: 15)); files.tap()
        let icons = app.buttons["filesView_icons"]
        XCTAssertTrue(icons.waitForExistence(timeout: 10)); icons.tap()
        let share = app.descendants(matching: .any)["nasFolder_测试共享"].firstMatch
        XCTAssertTrue(share.waitForExistence(timeout: 10)); share.tap()
        XCTAssertFalse(app.buttons["filesBack"].isEnabled, "Single click selects without navigating")
        XCTAssertTrue(XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == true"), object: app.buttons["filesOpen"]).waitForFulfillment(timeout: 5))
        app.buttons["filesOpen"].tap()
        let textFile = app.descendants(matching: .any)["nasFile_说明 + 中文.txt"].firstMatch
        XCTAssertTrue(textFile.waitForExistence(timeout: 10))
        let search = app.textFields["desktopFileSearch"]
        search.tap(); search.typeText("说明")
        textFile.tap()
        app.buttons["filesInspector"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["fileInspectorPanel"].firstMatch.waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["96 bytes"].exists || app.staticTexts["96字节"].exists || app.staticTexts["位置"].exists)
        app.buttons["filesOpen"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["quickLookContent"].firstMatch.waitForExistence(timeout: 15))
        let previewShot = XCTAttachment(screenshot: app.screenshot()); previewShot.name = "51-desktop-quick-look"; previewShot.lifetime = .keepAlways; add(previewShot)
        app.buttons["完成"].firstMatch.tap()
        app.buttons["filesBack"].tap()
        XCTAssertTrue(share.waitForExistence(timeout: 5))
        app.buttons["filesForward"].tap()
        XCTAssertTrue(textFile.waitForExistence(timeout: 5))
        XCTAssertEqual(search.value as? String, "说明")
        app.descendants(matching: .any)["sidebar_photos"].firstMatch.tap()
        files.tap()
        XCTAssertTrue(textFile.waitForExistence(timeout: 5)); XCTAssertEqual(search.value as? String, "说明")
        app.buttons["清除搜索"].tap()
        app.buttons["filesInspector"].tap()
        let empty = app.descendants(matching: .any)["nasFolder_空文件夹"].firstMatch
        XCTAssertTrue(empty.waitForExistence(timeout: 5)); empty.doubleTap()
        XCTAssertTrue(app.staticTexts["空文件夹"].firstMatch.waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["breadcrumb_空文件夹"].exists)
        app.buttons["filesUp"].tap()
        XCTAssertTrue(textFile.waitForExistence(timeout: 5))
        app.buttons["filesView_list"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["desktopFileTable"].firstMatch.waitForExistence(timeout: 5))
        app.buttons["filesView_icons"].tap()
        let shot = XCTAttachment(screenshot: app.screenshot()); shot.name = "50-desktop-file-browser"; shot.lifetime = .keepAlways; add(shot)
        app.buttons["filesRoot"].tap()
        XCTAssertTrue(share.waitForExistence(timeout: 5))
    }

    func testIPadLandscapeSidebarAndDirectoryNavigation() {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .landscapeLeft
        defer { XCUIDevice.shared.orientation = .portrait }
        let app = XCUIApplication()
        app.launchArguments = ["--nas-connection-fixture", "--reset-nas-connection-fixture"]
        app.launch()
        XCTAssertTrue(app.buttons.matching(identifier: "nasPhotoCell").firstMatch.waitForExistence(timeout: 15))
        let sidebar = app.descendants(matching: .any)["sidebar_files"].firstMatch
        XCTAssertTrue(sidebar.waitForExistence(timeout: 5))
        XCTAssertFalse(app.tabBars.firstMatch.exists)
        sidebar.tap()
        XCTAssertTrue(app.buttons["nasFolder_测试共享"].waitForExistence(timeout: 10))
        app.buttons["nasFolder_测试共享"].tap()
        XCTAssertTrue(app.buttons["nasFile_说明 + 中文.txt"].waitForExistence(timeout: 10))
        app.descendants(matching: .any)["sidebar_photos"].firstMatch.tap()
        XCTAssertTrue(app.buttons.matching(identifier: "nasPhotoCell").firstMatch.waitForExistence(timeout: 5))
        app.descendants(matching: .any)["sidebar_files"].firstMatch.tap()
        XCTAssertTrue(app.buttons["nasFile_说明 + 中文.txt"].waitForExistence(timeout: 5))
        let shot = XCTAttachment(screenshot: app.screenshot()); shot.name = "41-ipad-landscape"; shot.lifetime = .keepAlways; add(shot)
    }

    func testNewPhotoBackupSettingsAreOffByDefaultAndRequireSavedConnection() {
        let app = XCUIApplication()
        app.launchArguments = ["--empty-connection-fixture"]
        app.launch()
        XCTAssertEqual(app.tabBars.buttons.allElementsBoundByIndex.map(\.label), ["照片", "群晖", "设置"])
        app.tabBars.buttons["设置"].tap()
        app.buttons["newPhotoBackupSettings"].tap()
        XCTAssertTrue(app.navigationBars["新照片备份"].waitForExistence(timeout: 5))
        let toggle = app.switches["enableNewPhotoBackup"]
        XCTAssertEqual(toggle.value as? String, "0")
        XCTAssertTrue(app.buttons["chooseBackupFolder"].label.contains("/home/Photos/MoriBackup"))
        XCTAssertFalse(app.textFields["photoBackupFolder"].exists)
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "34-new-photo-backup-settings"; shot.lifetime = .keepAlways; add(shot)
        toggle.switches.firstMatch.tap()
        XCTAssertEqual(toggle.value as? String, "0", "No destination verification means no automatic uploads")
        XCTAssertTrue(app.staticTexts["请先连接 File Station，并保存登录信息。"].waitForExistence(timeout: 5))
    }

    func testBackupFolderCanBeChosenWithoutTypingAndSurvivesRelaunch() {
        let app = XCUIApplication()
        app.launchArguments = ["--nas-connection-fixture", "--reset-nas-connection-fixture"]
        app.launch()
        app.tabBars.buttons["设置"].tap()
        app.buttons["newPhotoBackupSettings"].tap()
        app.buttons["chooseBackupFolder"].tap()
        XCTAssertTrue(app.buttons["backupFolder_测试共享"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["useBackupFolder"].isEnabled)
        XCTAssertFalse(app.keyboards.firstMatch.exists)
        app.buttons["backupFolder_测试共享"].tap()
        XCTAssertTrue(app.buttons["backupFolder_空文件夹"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.staticTexts["说明 + 中文.txt"].exists)
        app.buttons["backupFolder_空文件夹"].tap()
        XCTAssertTrue(app.staticTexts["这个文件夹没有子文件夹，可以直接选用"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["useBackupFolder"].isEnabled)
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "35-graphical-backup-folder-picker"; shot.lifetime = .keepAlways; add(shot)
        app.buttons["useBackupFolder"].tap()
        let selected = app.buttons["chooseBackupFolder"]
        XCTAssertTrue(XCTNSPredicateExpectation(predicate: NSPredicate(format: "label CONTAINS %@", "/测试共享/空文件夹"), object: selected).waitForFulfillment(timeout: 10))
        XCTAssertEqual(app.switches["enableNewPhotoBackup"].value as? String, "0")
        app.terminate()
        app.launchArguments = ["--nas-connection-fixture"]
        app.launch()
        app.tabBars.buttons["设置"].tap()
        app.buttons["newPhotoBackupSettings"].tap()
        XCTAssertTrue(selected.label.contains("/测试共享/空文件夹"))
        XCTAssertFalse(app.keyboards.firstMatch.exists)
    }

    func testBackupFolderPermissionErrorCannotBeSelectedAndCancelClosesNestedPicker() {
        let app = XCUIApplication()
        app.launchArguments = ["--nas-connection-fixture", "--reset-nas-connection-fixture"]
        app.launch()
        app.tabBars.buttons["设置"].tap(); app.buttons["newPhotoBackupSettings"].tap()
        app.buttons["chooseBackupFolder"].tap()
        XCTAssertTrue(app.buttons["backupFolder_测试共享"].waitForExistence(timeout: 10))
        app.buttons["backupFolder_测试共享"].tap()
        XCTAssertTrue(app.buttons["backupFolder_无权限"].waitForExistence(timeout: 5))
        app.buttons["backupFolder_无权限"].tap()
        XCTAssertTrue(app.staticTexts["errorBanner"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["useBackupFolder"].isEnabled)
        app.buttons["cancelBackupFolder"].tap()
        XCTAssertTrue(app.buttons["chooseBackupFolder"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["chooseBackupFolder"].label.contains("/home/Photos/MoriBackup"))
    }

    func testNASSectionSwitchingKeepsTabPositionsAndPhotoFilter() {
        let app = XCUIApplication()
        app.launchArguments = ["--nas-connection-fixture", "--reset-nas-connection-fixture"]
        app.launch(); app.tabBars.buttons["群晖"].tap()
        let photos = app.buttons.matching(identifier: "nasPhotoCell")
        XCTAssertTrue(photos.firstMatch.waitForExistence(timeout: 10))
        let ids = ["nasSectionPhotos", "nasSectionFiles", "nasSectionMonitor"]
        let positions = ids.map { app.buttons[$0].frame }
        app.buttons["toggleNASSearch"].tap()
        let search = app.textFields["nasPhotoSearch"]
        search.tap(); search.typeText("测试照片-1.\n")
        XCTAssertEqual(photos.count, 1)
        for target in ["nasSectionFiles", "nasSectionMonitor", "nasSectionPhotos"] {
            app.buttons[target].tap()
            if target == "nasSectionFiles" { XCTAssertTrue(app.buttons["nasFolder_测试共享"].waitForExistence(timeout: 10)) }
            if target == "nasSectionMonitor" { XCTAssertTrue(app.staticTexts["monitorCPU"].waitForExistence(timeout: 10)) }
            for (index, id) in ids.enumerated() {
                XCTAssertEqual(app.buttons[id].frame.midX, positions[index].midX, accuracy: 1, "The \(id) tab must stay in place on \(target)")
                XCTAssertEqual(app.buttons[id].frame.midY, positions[index].midY, accuracy: 1)
            }
            let shot = XCTAttachment(screenshot: app.screenshot())
            shot.name = "stable-" + target; shot.lifetime = .keepAlways; add(shot)
        }
        XCTAssertTrue(search.exists, "Switching tabs must retain the photo search")
        XCTAssertEqual(photos.count, 1)

        app.buttons["nasSectionFiles"].tap()
        app.buttons["fileOptions"].tap()
        app.buttons["openDownloads"].tap()
        XCTAssertTrue(app.navigationBars["下载"].waitForExistence(timeout: 5))
        app.navigationBars.buttons["BackButton"].tap()
        XCTAssertTrue(app.buttons["nasFolder_测试共享"].waitForExistence(timeout: 5))

        app.buttons["nasSectionMonitor"].tap()
        app.buttons["monitorAutoRefresh"].tap()
        XCTAssertTrue(app.buttons["monitorAutoRefresh"].label.contains("手动刷新"))
        let lastUpdate = app.staticTexts["monitorUpdated"].label
        app.buttons["nasSectionPhotos"].tap()
        XCTAssertEqual(photos.count, 1)
        app.buttons["nasSectionMonitor"].tap()
        XCTAssertTrue(app.buttons["monitorAutoRefresh"].label.contains("手动刷新"))
        XCTAssertEqual(app.staticTexts["monitorUpdated"].label, lastUpdate)
        for (index, id) in ids.enumerated() {
            XCTAssertEqual(app.buttons[id].frame.midX, positions[index].midX, accuracy: 1)
            XCTAssertEqual(app.buttons[id].frame.midY, positions[index].midY, accuracy: 1)
        }
    }

    func testNASMonitorDisplaysRefreshesAndRestoresSession() {
        let app = XCUIApplication()
        app.launchArguments = ["--nas-connection-fixture", "--reset-nas-connection-fixture"]
        app.launch()
        app.tabBars.buttons["群晖"].tap()
        XCTAssertTrue(app.buttons.matching(identifier: "nasPhotoCell").firstMatch.waitForExistence(timeout: 10))
        app.buttons["nasSectionMonitor"].tap()
        let cpu = app.staticTexts["monitorCPU"]
        XCTAssertTrue(cpu.waitForExistence(timeout: 10)); XCTAssertEqual(cpu.label, "18%")
        XCTAssertEqual(app.staticTexts["monitorMemory"].label, "36%")
        XCTAssertEqual(app.staticTexts["monitorStatus"].label, "已连接")
        let dashboard = XCTAttachment(screenshot: app.screenshot())
        dashboard.name = "21-NAS状态总览"; dashboard.lifetime = .keepAlways; add(dashboard)
        let updated = app.staticTexts["monitorUpdated"]
        let firstUpdate = updated.label
        XCTAssertTrue(XCTNSPredicateExpectation(predicate: NSPredicate(format: "label != %@", firstUpdate), object: updated).waitForFulfillment(timeout: 20), "The visible status page should refresh automatically")
        app.buttons["monitorAutoRefresh"].tap()
        XCTAssertTrue(app.buttons["monitorAutoRefresh"].label.contains("手动刷新"))
        app.buttons["refreshMonitor"].tap()
        XCTAssertTrue(app.otherElements["monitorTrend"].waitForExistence(timeout: 5))
        app.swipeUp()
        XCTAssertTrue(app.staticTexts["硬盘 1"].waitForExistence(timeout: 5))
        let storage = XCTAttachment(screenshot: app.screenshot())
        storage.name = "22-NAS存储与健康"; storage.lifetime = .keepAlways; add(storage)
        app.terminate()
        app.launchArguments = ["--nas-connection-fixture", "--require-resumed-sessions"]
        app.launch()
        app.tabBars.buttons["群晖"].tap()
        app.buttons["nasSectionMonitor"].tap()
        XCTAssertTrue(cpu.waitForExistence(timeout: 10))
        XCTAssertEqual(cpu.label, "18%")
        XCTAssertFalse(app.buttons["loginNAS"].exists)
    }

    func testNASMonitorKeepsAvailableDataWhenPermissionsArePartial() {
        let app = XCUIApplication()
        app.launchArguments = ["--nas-connection-fixture", "--reset-nas-connection-fixture", "--monitor-partial-permission"]
        app.launch()
        app.tabBars.buttons["群晖"].tap()
        app.buttons["nasSectionMonitor"].tap()
        XCTAssertTrue(app.staticTexts["DS923+"].waitForExistence(timeout: 10))
        XCTAssertEqual(app.staticTexts["monitorStatus"].label, "部分数据不可用")
        XCTAssertFalse(app.staticTexts["monitorCPU"].exists)
        XCTAssertTrue(app.staticTexts["实时负载暂不可用"].exists)
        let partial = XCTAttachment(screenshot: app.screenshot())
        partial.name = "23-NAS部分权限提示"; partial.lifetime = .keepAlways; add(partial)
    }

    func testNASPhotoSearchSpaceAndFolderNavigation() {
        let app = XCUIApplication()
        app.launchArguments = ["--nas-connection-fixture", "--reset-nas-connection-fixture"]
        app.launch()
        app.tabBars.buttons["群晖"].tap()
        let photos = app.buttons.matching(identifier: "nasPhotoCell")
        XCTAssertTrue(photos.firstMatch.waitForExistence(timeout: 10))
        app.buttons["toggleNASSearch"].tap()
        let search = app.textFields["nasPhotoSearch"]
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        search.tap(); search.typeText("测试照片-1.")
        XCTAssertTrue(XCTNSPredicateExpectation(predicate: NSPredicate(format: "count == 1"), object: photos).waitForFulfillment(timeout: 5))
        app.buttons["clearNASSearch"].tap()
        XCTAssertEqual(photos.count, 12)
        app.buttons["toggleNASSearch"].tap()
        XCTAssertFalse(search.exists)

        let space = app.buttons["nasSpaceMenu"]
        space.tap(); app.buttons["共享空间"].tap()
        XCTAssertTrue(XCTNSPredicateExpectation(predicate: NSPredicate(format: "label CONTAINS %@", "共享空间"), object: space).waitForFulfillment(timeout: 5))
        let folder = app.buttons["nasPhotoFolder_101"]
        XCTAssertTrue(folder.waitForExistence(timeout: 5)); folder.tap()
        XCTAssertTrue(app.navigationBars["MobileBackup"].waitForExistence(timeout: 5))
        XCTAssertTrue(photos.firstMatch.waitForExistence(timeout: 5))
        app.navigationBars.buttons.firstMatch.tap()
        XCTAssertTrue(app.buttons["nasSpaceMenu"].waitForExistence(timeout: 5))
    }

    func testNASAutomaticallyRestoresBothServicesAfterRelaunch() {
        let app = XCUIApplication()
        app.launchArguments = ["--nas-connection-fixture", "--reset-nas-connection-fixture"]
        app.launch()
        app.tabBars.buttons["群晖"].tap()
        let photos = app.buttons.matching(identifier: "nasPhotoCell")
        XCTAssertTrue(photos.firstMatch.waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["loginNAS"].exists)
        let grid = XCTAttachment(screenshot: app.screenshot())
        grid.name = "13-群晖照片贴边与自动连接"; grid.lifetime = .keepAlways; add(grid)
        app.buttons["nasSectionFiles"].tap()
        XCTAssertTrue(app.buttons["nasFolder_测试共享"].waitForExistence(timeout: 10))
        let files = XCTAttachment(screenshot: app.screenshot())
        files.name = "群晖文件列表样式"; files.lifetime = .keepAlways; add(files)
        app.terminate()
        // The fixture now rejects every password login. Only persisted sessions can succeed.
        app.launchArguments = ["--nas-connection-fixture", "--require-resumed-sessions"]
        app.launch()
        app.tabBars.buttons["群晖"].tap()
        XCTAssertTrue(photos.firstMatch.waitForExistence(timeout: 10))
        app.buttons["nasSectionFiles"].tap()
        XCTAssertTrue(app.buttons["nasFolder_测试共享"].waitForExistence(timeout: 10))
        app.buttons["nasSectionPhotos"].tap()
        XCTAssertTrue(photos.firstMatch.waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["loginNAS"].exists)
    }

    func testVideoPlaybackAndSeek() {
        let app = XCUIApplication()
        app.launchArguments = ["--files-fixture", "--video-fixture", "--reset-video-progress"]
        app.launch()
        app.tabBars.buttons["群晖"].tap()
        app.buttons["nasSectionFiles"].tap()
        let share = app.buttons["nasFolder_测试共享"]
        XCTAssertTrue(share.waitForExistence(timeout: 10)); share.tap()
        app.buttons["nasFile_测试视频.mp4"].tap()
        app.buttons["playVideo"].tap()
        let elapsed = app.staticTexts["videoElapsed"]
        XCTAssertTrue(elapsed.waitForExistence(timeout: 10))
        XCTAssertTrue(XCTNSPredicateExpectation(predicate: NSPredicate(format: "value.intValue >= 1"), object: elapsed).waitForFulfillment(timeout: 15))
        app.buttons["videoForward"].tap()
        XCTAssertTrue(XCTNSPredicateExpectation(predicate: NSPredicate(format: "value.intValue >= 15"), object: elapsed).waitForFulfillment(timeout: 10))
        let playback = XCTAttachment(screenshot: app.screenshot())
        playback.name = "09-视频在线播放与进度跳转"; playback.lifetime = .keepAlways; add(playback)
        app.buttons["videoToggle"].tap()
        app.buttons["closeVideo"].tap()
        XCTAssertTrue(app.buttons["playVideo"].waitForExistence(timeout: 5))
        app.buttons["playVideo"].tap()
        XCTAssertTrue(app.staticTexts["videoResumed"].waitForExistence(timeout: 10))
        XCTAssertTrue(XCTNSPredicateExpectation(predicate: NSPredicate(format: "value.intValue >= 15"), object: elapsed).waitForFulfillment(timeout: 10))
        app.buttons["closeVideo"].tap()
        app.terminate()
        app.launchArguments = ["--files-fixture", "--video-fixture"]
        app.launch()
        app.tabBars.buttons["群晖"].tap(); app.buttons["nasSectionFiles"].tap()
        XCTAssertTrue(share.waitForExistence(timeout: 10)); share.tap()
        app.buttons["nasFile_测试视频.mp4"].tap(); app.buttons["playVideo"].tap()
        XCTAssertTrue(app.staticTexts["videoResumed"].waitForExistence(timeout: 10))
        XCTAssertTrue(XCTNSPredicateExpectation(predicate: NSPredicate(format: "value.intValue >= 15"), object: elapsed).waitForFulfillment(timeout: 10))
        let resumed = XCTAttachment(screenshot: app.screenshot()); resumed.name = "42-video-resume"; resumed.lifetime = .keepAlways; add(resumed)
        app.buttons["videoRestart"].tap()
        XCTAssertTrue(XCTNSPredicateExpectation(predicate: NSPredicate(format: "value.intValue < 3"), object: elapsed).waitForFulfillment(timeout: 10))
        XCTAssertFalse(app.staticTexts["videoResumed"].exists)
        app.buttons["closeVideo"].tap()
    }

    func testFileBrowserDownloadAndOfflineExport() {
        let app = XCUIApplication()
        app.launchArguments = ["--files-fixture", "--reset-files-fixture"]
        app.launch()
        app.tabBars.buttons["群晖"].tap()
        app.buttons["nasSectionFiles"].tap()
        let share = app.buttons["nasFolder_测试共享"]
        XCTAssertTrue(share.waitForExistence(timeout: 10)); share.tap()
        let file = app.buttons["nasFile_说明 + 中文.txt"]
        XCTAssertTrue(file.waitForExistence(timeout: 5))
        let directory = XCTAttachment(screenshot: app.screenshot())
        directory.name = "06-群晖文件目录"; directory.lifetime = .keepAlways; add(directory)
        file.tap()
        app.buttons["downloadFile"].tap()
        app.buttons["detailDownloads"].tap()
        app.segmentedControls.buttons["已下载"].tap()
        XCTAssertTrue(app.buttons["exportFile"].waitForExistence(timeout: 15))
        let downloaded = XCTAttachment(screenshot: app.screenshot())
        downloaded.name = "07-群晖文件已下载"; downloaded.lifetime = .keepAlways; add(downloaded)
        app.terminate()
        app.launchArguments = ["--files-fixture", "--files-fixture-offline"]
        app.launch()
        app.tabBars.buttons["群晖"].tap()
        app.buttons["nasSectionFiles"].tap()
        app.buttons["openDownloads"].tap()
        app.segmentedControls.buttons["已下载"].tap()
        XCTAssertTrue(app.buttons["exportFile"].waitForExistence(timeout: 5))
        app.buttons["exportFile"].tap()
        XCTAssertTrue(app.buttons["Save"].waitForExistence(timeout: 5))
        let exported = XCTAttachment(screenshot: app.screenshot())
        exported.name = "08-离线导出到系统文件"; exported.lifetime = .keepAlways; add(exported)
        app.buttons["Save"].tap()
        // The system file provider may present its conflict alert outside this app.
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline && !app.descendants(matching: .any)["exportSuccess"].exists {
            let replace = springboard.buttons["Replace"].exists ? springboard.buttons["Replace"] : app.buttons["Replace"]
            if replace.waitForExistence(timeout: 1) {
                replace.tap()
                _ = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: replace).waitForFulfillment(timeout: 1)
            }
        }
        XCTAssertTrue(app.descendants(matching: .any)["exportSuccess"].waitForExistence(timeout: 5))
    }

    func testPhotoPreviewSupportsZoomAndPaging() {
        let app = XCUIApplication()
        app.launch()
        let cells = app.buttons.matching(identifier: "localPhotoCell")
        XCTAssertTrue(cells.firstMatch.waitForExistence(timeout: 10), "Use the authorized MoriPhotos QA photo library")
        XCTAssertGreaterThanOrEqual(cells.count, 3)
        cells.element(boundBy: 0).tap()
        let position = app.staticTexts["photoPosition"]
        XCTAssertTrue(position.waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["localPhotoFileSize"].waitForExistence(timeout: 5))
        let sizeShot = XCTAttachment(screenshot: app.screenshot())
        sizeShot.name = "30-手机照片文件大小"; sizeShot.lifetime = .keepAlways; add(sizeShot)
        func waitForPage(_ page: Int, file: StaticString = #filePath, line: UInt = #line) {
            let predicate = NSPredicate(format: "label BEGINSWITH %@", "\(page) / ")
            XCTAssertTrue(XCTNSPredicateExpectation(predicate: predicate, object: position).waitForFulfillment(timeout: 5), file: file, line: line)
        }
        func visibleImage() -> XCUIElement {
            app.scrollViews.matching(identifier: "photoZoom").allElementsBoundByIndex.first { $0.isHittable } ?? app.scrollViews["photoZoom"].firstMatch
        }
        waitForPage(1)
        XCTAssertFalse(app.buttons["previousPhoto"].isEnabled)
        app.buttons["nextPhoto"].tap()
        waitForPage(2)
        visibleImage().swipeLeft()
        waitForPage(3)

        let image = visibleImage()
        image.doubleTap()
        XCTAssertTrue(XCTNSPredicateExpectation(predicate: NSPredicate(format: "value != %@", "100%"), object: image).waitForFulfillment(timeout: 5))
        image.swipeLeft()
        waitForPage(3)
        let enlarged = XCTAttachment(screenshot: app.screenshot())
        enlarged.name = "04-照片放大与连续浏览"; enlarged.lifetime = .keepAlways; add(enlarged)
        image.doubleTap()
        XCTAssertTrue(XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", "100%"), object: image).waitForFulfillment(timeout: 5))

        image.pinch(withScale: 2, velocity: 1)
        XCTAssertTrue(XCTNSPredicateExpectation(predicate: NSPredicate(format: "value != %@", "100%"), object: image).waitForFulfillment(timeout: 5))
        image.pinch(withScale: 0.1, velocity: -1)
        XCTAssertTrue(XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", "100%"), object: image).waitForFulfillment(timeout: 5))
        image.swipeRight()
        waitForPage(2)
        app.buttons["previousPhoto"].tap()
        waitForPage(1)
        XCTAssertFalse(app.buttons["previousPhoto"].isEnabled)
        let normal = XCTAttachment(screenshot: app.screenshot())
        normal.name = "05-照片预览与翻页按钮"; normal.lifetime = .keepAlways; add(normal)

        visibleImage().swipeRight()
        waitForPage(1)
        guard let total = Int(position.label.components(separatedBy: " / ").last ?? ""), total > 1 else {
            return XCTFail("Expected the QA photo library's page count")
        }
        for page in 2...total {
            app.buttons["nextPhoto"].tap()
            waitForPage(page)
        }
        XCTAssertFalse(app.buttons["nextPhoto"].isEnabled)
        visibleImage().swipeLeft()
        waitForPage(total)
    }

    func testNASPhotoDetailsShowOriginalSizeAndUnknownValue() {
        let app = XCUIApplication()
        app.launchArguments = ["--nas-connection-fixture", "--reset-nas-connection-fixture"]
        app.launch(); app.tabBars.buttons["群晖"].tap()
        let photos = app.buttons.matching(identifier: "nasPhotoCell")
        XCTAssertTrue(photos.firstMatch.waitForExistence(timeout: 10))
        for (index, expected) in ["原图 3.2 MB", "原图 850 KB", "大小暂不可用"].enumerated() {
            photos.element(boundBy: index).tap()
            let size = app.staticTexts["nasPhotoFileSize"]
            XCTAssertTrue(size.waitForExistence(timeout: 5)); XCTAssertEqual(size.label, expected)
            if index == 0 {
                let image = app.scrollViews.matching(identifier: "photoZoom").firstMatch
                XCTAssertTrue(image.waitForExistence(timeout: 5))
                let shot = XCTAttachment(screenshot: app.screenshot())
                shot.name = "31-群晖照片文件大小"; shot.lifetime = .keepAlways; add(shot)
            }
            app.navigationBars.buttons["完成"].tap()
        }
    }

    func testNavigationAndConnectionValidation() {
        let app = XCUIApplication()
        app.launchArguments = ["--empty-connection-fixture"]
        app.launch()
        XCTAssertTrue(app.navigationBars["森空间"].waitForExistence(timeout: 10))
        let home = XCTAttachment(screenshot: app.screenshot())
        home.name = "01-照片首页"; home.lifetime = .keepAlways; add(home)
        app.tabBars.buttons["群晖"].tap()
        XCTAssertTrue(app.buttons["connectNAS"].waitForExistence(timeout: 5))
        let nas = XCTAttachment(screenshot: app.screenshot())
        nas.name = "02-群晖图库"; nas.lifetime = .keepAlways; add(nas)
        app.buttons["nasSectionFiles"].tap()
        let files = XCTAttachment(screenshot: app.screenshot())
        files.name = "14-群晖文件连接入口"; files.lifetime = .keepAlways; add(files)
        app.buttons["nasSectionPhotos"].tap()
        app.buttons["connectNAS"].tap()
        XCTAssertTrue(app.textFields["nasAddress"].waitForExistence(timeout: 5))
        app.textFields["nasAddress"].tap()
        app.textFields["nasAddress"].typeText("http://nas.example.com")
        app.buttons["收起键盘"].tap()
        app.textFields["nasUsername"].tap()
        app.textFields["nasUsername"].typeText("testuser")
        app.buttons["收起键盘"].tap()
        app.secureTextFields["nasPassword"].tap()
        app.secureTextFields["nasPassword"].typeText("test-password")
        app.buttons["收起键盘"].tap()
        app.swipeUp()
        app.buttons["loginNAS"].tap()
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "请使用 HTTPS")).firstMatch.waitForExistence(timeout: 5))
        app.navigationBars.buttons["完成"].tap()
        XCTAssertEqual(app.tabBars.buttons.allElementsBoundByIndex.map(\.label), ["照片", "群晖", "设置"])
        app.tabBars.buttons["设置"].tap()
        let version = app.descendants(matching: .any)["appVersion"]
        if !version.waitForExistence(timeout: 2) { app.swipeUp() }
        XCTAssertTrue(version.waitForExistence(timeout: 5))
        let settings = XCTAttachment(screenshot: app.screenshot())
        settings.name = "03-设置"; settings.lifetime = .keepAlways; add(settings)
        app.swipeDown()
        let brand = XCTAttachment(screenshot: app.screenshot())
        brand.name = "28-森空间设置"; brand.lifetime = .keepAlways; add(brand)
        XCUIDevice.shared.press(.home)
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        XCTAssertTrue(springboard.icons["森空间"].waitForExistence(timeout: 5))
        let icon = XCTAttachment(screenshot: springboard.screenshot())
        icon.name = "29-森空间桌面图标"; icon.lifetime = .keepAlways; add(icon)
    }
}

private extension XCTNSPredicateExpectation {
    func waitForFulfillment(timeout: TimeInterval) -> Bool {
        XCTWaiter.wait(for: [self], timeout: timeout) == .completed
    }
}
