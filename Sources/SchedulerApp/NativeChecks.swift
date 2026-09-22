import AppKit
import Carbon
import PDFKit
import SchedulerCore

enum NativeChecks {
    @MainActor static func run() -> Int32 {
        var passed = 0, failed = 0
        func check(_ name: String, _ test: () throws -> Bool) {
            do { if try test() { passed += 1; print("PASS \(name)") } else { failed += 1; print("FAIL \(name)") } }
            catch { failed += 1; print("FAIL \(name): \(error.localizedDescription)") }
        }
        check("login launch stays in background while explicit launch opens") {
            let login = NSAppleEventDescriptor(eventClass: AEEventClass(kCoreEventClass), eventID: AEEventID(kAEOpenApplication), targetDescriptor: nil, returnID: AEReturnID(kAutoGenerateReturnID), transactionID: AETransactionID(kAnyTransactionID))
            login.setParam(NSAppleEventDescriptor(enumCode: OSType(keyAELaunchedAsLogInItem)), forKeyword: AEKeyword(keyAEPropData))
            let manual = NSAppleEventDescriptor(eventClass: AEEventClass(kCoreEventClass), eventID: AEEventID(kAEOpenApplication), targetDescriptor: nil, returnID: AEReturnID(kAutoGenerateReturnID), transactionID: AETransactionID(kAnyTransactionID))
            return AppDelegate.isBackgroundLaunch(login) && !AppDelegate.isBackgroundLaunch(manual) && !AppDelegate.isBackgroundLaunch(nil)
        }
        let directory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("dist/validation/native-fixtures", isDirectory: true)
        func returnKey(_ flags: NSEvent.ModifierFlags = []) -> NSEvent {
            NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: 0,
                            context: nil, characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36)!
        }
        check("Enter submission dispatches one commit") {
            let input = CaptureTextView(); input.enterSubmits = true; var commits = 0
            input.commit = { commits += 1 }; input.keyDown(with: returnKey())
            return commits == 1 && input.string.isEmpty
        }
        check("Shift Enter inserts a newline in Enter submission mode") {
            let input = CaptureTextView(); input.enterSubmits = true; var commits = 0
            input.commit = { commits += 1 }; input.keyDown(with: returnKey(.shift))
            return commits == 0 && input.string == "\n"
        }
        check("Command Enter mode leaves plain Enter for newline") {
            let input = CaptureTextView(); var commits = 0
            input.commit = { commits += 1 }; input.keyDown(with: returnKey())
            input.keyDown(with: returnKey(.command))
            return commits == 1 && input.string == "\n"
        }
        let screen = NSRect(x: 0, y: 0, width: 1440, height: 900)
        check("window restores dragged top-left position") {
            let frame = PanelPlacement.frame(size: NSSize(width: 480, height: 285), anchor: NSPoint(x: 180, y: 760), screens: [screen], fallback: screen)
            return frame.minX == 180 && frame.maxY == 760
        }
        check("content height changes preserve window top edge") {
            let frame = PanelPlacement.frame(size: NSSize(width: 480, height: 610), anchor: NSPoint(x: 180, y: 760), screens: [screen], fallback: screen)
            return frame.minX == 180 && frame.maxY == 760
        }
        check("removed monitor restores window inside available display") {
            let frame = PanelPlacement.frame(size: NSSize(width: 480, height: 285), anchor: NSPoint(x: -1000, y: 800), screens: [screen], fallback: screen)
            return screen.contains(frame)
        }
        check("negative-coordinate monitor placement is preserved") {
            let left = NSRect(x: -1440, y: 0, width: 1440, height: 900)
            let frame = PanelPlacement.frame(size: NSSize(width: 480, height: 285), anchor: NSPoint(x: -1000, y: 800), screens: [left, screen], fallback: screen)
            return frame.minX == -1000 && frame.maxY == 800
        }
        check("window at display edge remains fully accessible") {
            let frame = PanelPlacement.frame(size: NSSize(width: 480, height: 610), anchor: NSPoint(x: 1400, y: 200), screens: [screen], fallback: screen)
            return screen.contains(frame)
        }
        do { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true) }
        catch { print("Cannot create task-owned validation fixtures."); return 1 }
        let batch = UUID()
        let draft = Draft(event: .init(title: "Synthetic native check", startLocal: "2030-06-18T14:00:00", endLocal: "2030-06-18T15:00:00", timeZone: "Asia/Shanghai"), calendarID: "test-not-a-real-calendar")
        var receipt = OperationReceipt(batchID: batch, draft: draft)
        check("durable prepared record survives reopen") {
            do { let store = try LocalStore(directory: directory); try store.record(receipt) }
            let reopened = try LocalStore(directory: directory)
            return try reopened.receipts().first { $0.id == receipt.id }?.status == "prepared"
        }
        check("receipt updates preserve operation identity") {
            let store = try LocalStore(directory: directory)
            receipt.status = "saved"; receipt.eventID = "synthetic-event-id"; receipt.message = "synthetic-only"
            try store.record(receipt)
            let records = try store.receipts().filter { $0.id == receipt.id }
            return records.count == 1 && records[0].status == "saved" && records[0].eventID == "synthetic-event-id"
        }
        check("preferences survive atomic round trip") {
            let store = try LocalStore(directory: directory)
            var preferences = AppPreferences(); preferences.reminderMinutes = 47; preferences.appearance = "dark"
            try store.savePreferences(preferences)
            return try store.loadPreferences().reminderMinutes == 47
        }
        check("private configuration file permissions") {
            let permissions = try FileManager.default.attributesOfItem(atPath: directory.appendingPathComponent("preferences.json").path)[.posixPermissions] as? NSNumber
            return permissions?.intValue == 0o600
        }
        check("draft persistence and app-owned clearing") {
            let store = try LocalStore(directory: directory)
            try store.saveDraft(.init(text: "synthetic text", drafts: [draft], questions: []))
            guard try store.loadDraft()?.drafts.first?.id == draft.id else { return false }
            try store.clearDraft(); return try store.loadDraft() == nil
        }
        check("unresolved operations are not expired") {
            let store = try LocalStore(directory: directory)
            var unresolved = OperationReceipt(batchID: batch, draft: draft)
            unresolved.createdAt = Date(timeIntervalSince1970: 0); try store.record(unresolved); try store.prune()
            return try store.receipts().contains { $0.id == unresolved.id }
        }
        check("completed old receipts are expired") {
            let store = try LocalStore(directory: directory)
            var old = OperationReceipt(batchID: batch, draft: draft, status: "saved")
            old.createdAt = Date(timeIntervalSince1970: 0); try store.record(old); try store.prune()
            return try !store.receipts().contains { $0.id == old.id }
        }
        func board(_ name: String) -> NSPasteboard {
            let pasteboard = NSPasteboard(name: NSPasteboard.Name("dev.icloudscheduler.check.\(name)"))
            pasteboard.clearContents(); return pasteboard
        }
        check("input-method composition is reported so the placeholder can step aside") {
            let input = CaptureTextView(); var states: [Bool] = []
            input.compositionChanged = { states.append($0) }
            input.setMarkedText("ban hui", selectedRange: NSRange(location: 7, length: 0), replacementRange: NSRange(location: 0, length: 0))
            guard states == [true], input.string == "ban hui" else { return false }
            input.insertText("班会", replacementRange: input.markedRange())
            return states == [true, false] && input.string == "班会"
        }
        check("a dropped file becomes an attachment instead of a pasted path") {
            let input = CaptureTextView(); var dropped: [URL] = []
            input.dropFiles = { dropped = $0 }
            let file = directory.appendingPathComponent("synthetic-drop.txt")
            try Data("synthetic".utf8).write(to: file)
            let pasteboard = board("drop"); pasteboard.writeObjects([file as NSURL])
            let handled = input.readSelection(from: pasteboard)
            return handled && dropped == [file] && input.string.isEmpty
        }
        check("ordinary text keeps pasting as text") {
            let input = CaptureTextView(); var dropped: [URL] = []
            input.dropFiles = { dropped = $0 }
            let pasteboard = board("text"); pasteboard.setString("明天下午三点开会", forType: .string)
            let handled = input.readSelection(from: pasteboard)
            return handled && dropped.isEmpty && input.string == "明天下午三点开会"
        }
        var jpeg = Data()
        check("native image encoding and normalization") {
            jpeg = try AttachmentProcessor.probeImage(code: "A42F19")
            let normalized = try AttachmentProcessor.normalizeImage(jpeg)
            return !normalized.isEmpty && normalized.count < 1_000_000
        }
        check("text and image input retain attachment labels") {
            let input = try AttachmentProcessor.prepare(text: "synthetic", attachments: [Attachment(name: "probe.jpg", data: jpeg, kind: "image")])
            return input.images.count == 1 && input.images[0].label == "probe.jpg" && input.text == "synthetic"
        }
        check("transparent images get a readable white background") {
            guard let context = CGContext(data: nil, width: 20, height: 20, bitsPerComponent: 8, bytesPerRow: 0,
                                          space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
                  let transparent = context.makeImage() else { return false }
            let data = try AttachmentProcessor.jpeg(transparent)
            guard let bitmap = NSBitmapImageRep(data: data), let color = bitmap.colorAt(x: 10, y: 10)?.usingColorSpace(.deviceRGB) else { return false }
            return color.redComponent > 0.95 && color.greenComponent > 0.95 && color.blueComponent > 0.95
        }
        var pdfData = Data()
        check("PDF selected pages render without OCR") {
            guard let image = NSImage(data: jpeg), let page = PDFPage(image: image), let second = PDFPage(image: image) else { return false }
            let document = PDFDocument(); document.insert(page, at: 0); document.insert(second, at: 1)
            guard let data = document.dataRepresentation() else { return false }; pdfData = data
            let attachment = Attachment(name: "test.pdf", data: data, kind: "pdf", pageCount: 2, firstPage: 2, lastPage: 2)
            let result = try AttachmentProcessor.prepare(text: "", attachments: [attachment])
            if let image = result.images.first { try image.jpeg.write(to: directory.appendingPathComponent("rendered-pdf-page.jpg")) }
            try data.write(to: directory.appendingPathComponent("synthetic-two-page.pdf"))
            return result.images.count == 1 && result.images[0].label == "test.pdf 第 2 页" && !result.images[0].jpeg.isEmpty
        }
        check("rotated PDF pages retain orientation") {
            guard let document = PDFDocument(data: pdfData), let page = document.page(at: 0) else { return false }
            page.rotation = 90
            guard let data = document.dataRepresentation() else { return false }
            let attachment = Attachment(name: "rotated.pdf", data: data, kind: "pdf", pageCount: 2, firstPage: 1, lastPage: 1)
            let result = try AttachmentProcessor.prepare(text: "", attachments: [attachment])
            guard let imageData = result.images.first?.jpeg, let bitmap = NSBitmapImageRep(data: imageData) else { return false }
            try imageData.write(to: directory.appendingPathComponent("rotated-pdf-page.jpg"))
            return bitmap.pixelsHigh > bitmap.pixelsWide
        }
        check("a text PDF is read as text and needs no vision model") {
            let view = NSTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
            view.string = "教务通知：请各班在本周内完成学业指导会的报名登记，逾期不再受理。"
            let data = view.dataWithPDF(inside: view.bounds)
            guard let document = PDFDocument(data: data), AttachmentProcessor.hasUsableText(document) else { return false }
            let attachment = Attachment(name: "notice.pdf", data: data, kind: "pdf", pageCount: 1, firstPage: 1, lastPage: 1,
                                        hasTextLayer: true, sendAsText: true)
            let result = try AttachmentProcessor.prepare(text: "", attachments: [attachment])
            return result.images.isEmpty && result.text.contains("学业指导会") && result.text.contains("【附件：notice.pdf 第 1 页】")
                && !attachment.requiresVision
        }
        check("a scanned PDF keeps the rendered page and its vision requirement") {
            guard let document = PDFDocument(data: pdfData) else { return false }
            let scanned = Attachment(name: "scan.pdf", data: pdfData, kind: "pdf", pageCount: 2, firstPage: 1, lastPage: 1)
            return !AttachmentProcessor.hasUsableText(document) && scanned.requiresVision
        }
        check("text mode is refused when the selected pages hold no words") {
            let empty = Attachment(name: "scan.pdf", data: pdfData, kind: "pdf", pageCount: 2, firstPage: 1, lastPage: 1,
                                   hasTextLayer: true, sendAsText: true)
            do { _ = try AttachmentProcessor.prepare(text: "", attachments: [empty]); return false }
            catch { return true }
        }
        check("text attachments carry the documented marker") {
            let result = try AttachmentProcessor.prepare(text: "原文", attachments: [Attachment(name: "notice.txt", data: Data("下周一交材料".utf8), kind: "txt")])
            return result.images.isEmpty && result.text.contains("【附件：notice.txt】") && result.text.contains("下周一交材料")
        }
        check("invalid PDF page range is rejected") {
            do { _ = try AttachmentProcessor.prepare(text: "", attachments: [Attachment(name: "test.pdf", data: pdfData, kind: "pdf", pageCount: 2, firstPage: 0, lastPage: 2)]); return false }
            catch { return true }
        }
        check("input character budget is enforced") {
            do { _ = try AttachmentProcessor.prepare(text: String(repeating: "字", count: 20001), attachments: []); return false }
            catch { return true }
        }
        check("image count budget is enforced") {
            do { _ = try AttachmentProcessor.prepare(text: "", attachments: (0..<11).map { Attachment(name: "\($0).jpg", data: jpeg, kind: "image") }); return false }
            catch { return true }
        }
        check("malformed image is rejected") {
            do { _ = try AttachmentProcessor.normalizeImage(Data("not an image".utf8)); return false }
            catch { return true }
        }
        check("invalid UTF-8 is rejected") {
            do { _ = try AttachmentProcessor.prepare(text: "", attachments: [Attachment(name: "bad.txt", data: Data([0xff, 0xfe, 0xfd]), kind: "txt")]); return false }
            catch { return true }
        }
        print("\n\(passed) native checks passed, \(failed) failed. Synthetic local fixtures only; no Keychain, model calls or EventKit access.")
        return failed == 0 ? 0 : 1
    }
}
