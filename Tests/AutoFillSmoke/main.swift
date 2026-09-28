import AppKit
import PDFKit

/// Filling a form in from the reader's own details.
@main
@MainActor
struct AutoFillSmoke {
    static func main() {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("zzpdf-autofill-smoke-\(UUID().uuidString)", isDirectory: true)
        try! FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        matching()
        filling(in: directory)
        print("Form auto-fill smoke test passed.")
    }

    // MARK: - Reading what a field is asking for

    private static func matching() {
        var profile = PersonalProfile()
        profile[.givenName] = "Luca"
        profile[.familyName] = "Lazzaroni"
        profile[.email] = "luca.lazzaroni@unige.it"
        profile[.taxCode] = "LZZLCU95M06G605Z"
        profile[.city] = "Genova"
        profile.custom = [PersonalProfile.CustomEntry(name: "Matricola", value: "4567890")]

        // The pairs that matter: a surname must not be read as a name, and a field asking
        // for both must not be read as either.
        expect(["Cognome"], in: profile, is: "Lazzaroni")
        expect(["Nome"], in: profile, is: "Luca")
        expect(["Nome e cognome"], in: profile, is: "Luca Lazzaroni")
        expect(["Surname"], in: profile, is: "Lazzaroni")
        expect(["First Name"], in: profile, is: "Luca")

        // Written however the form happens to write it.
        expect(["CODICE FISCALE"], in: profile, is: "LZZLCU95M06G605Z")
        expect(["codice_fiscale"], in: profile, is: "LZZLCU95M06G605Z")
        expect(["Cod. Fiscale"], in: profile, is: "LZZLCU95M06G605Z")
        expect(["Città"], in: profile, is: "Genova")
        expect(["E-mail:"], in: profile, is: "luca.lazzaroni@unige.it")

        // A field of the reader's own is looked for by the name they gave it.
        expect(["Matricola"], in: profile, is: "4567890")

        // A full name the reader never typed is put together from the two halves, but only
        // where the form asks for the whole thing.
        var halves = PersonalProfile()
        halves[.givenName] = "Luca"
        halves[.familyName] = "Lazzaroni"
        expect(["Nominativo"], in: halves, is: "Luca Lazzaroni")

        // The field's own name is trusted over the words printed near it, since a label can
        // belong to the box above or below just as easily.
        expect(["Cognome", "Nome"], in: profile, is: "Lazzaroni")

        // Nothing is invented for a field about something the reader never gave.
        check(
            FormFieldMatcher.detail(for: ["Targa del veicolo"], in: profile) == nil,
            "A field with no matching detail was filled anyway"
        )
        check(
            FormFieldMatcher.detail(for: ["Nome"], in: PersonalProfile()) == nil,
            "An empty profile produced a value"
        )
    }

    private static func expect(_ candidates: [String], in profile: PersonalProfile, is value: String) {
        guard let detail = FormFieldMatcher.detail(for: candidates, in: profile) else {
            fail("\(candidates) matched nothing")
        }
        check(detail.value == value, "\(candidates) filled in \"\(detail.value)\" instead of \"\(value)\"")
    }

    // MARK: - Filling a real form in

    private static func filling(in directory: URL) {
        let suiteName = "it.lucalazzaroni.zzpdf.tests.autofill.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let preferences = AppPreferences(defaults: defaults)
        var profile = PersonalProfile()
        profile[.givenName] = "Luca"
        profile[.familyName] = "Lazzaroni"
        profile[.email] = "luca.lazzaroni@unige.it"
        profile[.phone] = "0100000000"
        preferences.personalProfile = profile

        // The profile survives being written and read back, or the details would have to be
        // typed again every launch.
        let reloaded = AppPreferences(defaults: defaults)
        check(
            reloaded.personalProfile[.email] == "luca.lazzaroni@unige.it",
            "The stored details came back as \(reloaded.personalProfile[.email])"
        )

        let workspace = PDFWorkspace(
            preferences: preferences,
            recoveryStore: TemporaryRecoveryStore(directoryURL: directory.appendingPathComponent("R"))
        )
        workspace.load(makeForm(in: directory))
        guard let page = workspace.pdfDocument?.page(at: 0) else { fail("The fixture has no page") }

        let matches = workspace.autoFillMatches()
        let byValue = Dictionary(uniqueKeysWithValues: matches.map { ($0.newValue, $0) })
        check(matches.count == 3, "\(matches.count) fields matched instead of 3: \(matches.map(\.fieldLabel))")

        // A field whose name says nothing is matched on the words printed beside it, which
        // is how most forms produced by Acrobat's wizard have to be read.
        guard let name = byValue["Luca"] else { fail("The first-name field was not matched") }
        check(name.fieldLabel == "Nome", "The unnamed field is shown as \"\(name.fieldLabel)\"")
        check(name.detailLabel == "First name", "It was matched to \(name.detailLabel)")

        guard let surname = byValue["Lazzaroni"] else { fail("The surname field was not matched") }
        check(surname.currentValue.isEmpty, "The surname field already held \(surname.currentValue)")
        check(byValue["luca.lazzaroni@unige.it"] != nil, "The email field was not matched")

        // A tick box asks something a stored detail cannot answer, and a field the form
        // locked is not the reader's to change.
        check(
            !matches.contains { $0.fieldLabel.contains("Telefono") },
            "A read-only field was going to be written to"
        )
        check(
            !matches.contains { $0.annotation.widgetFieldType == .button },
            "A tick box was going to be filled in"
        )

        // Only what the reader agreed to is written.
        let chosen = Array(matches.prefix(2))
        check(workspace.applyAutoFill(chosen) == 2, "Filling in two fields did not report two")
        let written = values(on: page)
        for match in chosen {
            check(
                written[match.annotation.fieldName ?? ""] == match.newValue,
                "\(match.fieldLabel) holds \(written[match.annotation.fieldName ?? ""] ?? "nothing")"
            )
        }
        check(workspace.isDirty, "Filling the form in left the document unchanged")

        // It goes back in one step, and comes back in one.
        workspace.undo()
        check(values(on: page).values.allSatisfy(\.isEmpty), "Undo left \(values(on: page))")
        workspace.redo()
        check(
            values(on: page).values.contains(where: { !$0.isEmpty }),
            "Redo did not put the details back"
        )

        // Once a field holds what it should, there is nothing left to offer for it.
        let remaining = workspace.autoFillMatches()
        check(
            remaining.count == matches.count - chosen.count,
            "\(remaining.count) fields were still offered after \(chosen.count) were filled"
        )
    }

    private static func values(on page: PDFPage) -> [String: String] {
        var result: [String: String] = [:]
        for annotation in page.annotations
        where annotation.isSubtype(.widget) && annotation.widgetFieldType == .text {
            result[annotation.fieldName ?? ""] = annotation.widgetStringValue ?? ""
        }
        return result
    }

    /// A form with the labels printed on the page and the boxes beside them, the way a
    /// form actually reaches a reader.
    private static func makeForm(in directory: URL) -> URL {
        let url = directory.appendingPathComponent("modulo.pdf")
        var mediaBox = CGRect(x: 0, y: 0, width: 320, height: 400)
        guard let context = CGContext(url as CFURL, mediaBox: &mediaBox, nil) else {
            fail("The test PDF context could not be created")
        }
        context.beginPDFPage(nil)
        let font = CTFontCreateWithName("Helvetica" as CFString, 11, nil)
        for (label, y) in [("Nome", 340), ("Cognome", 300), ("E-mail", 260), ("Telefono", 220)] {
            let line = NSAttributedString(string: label, attributes: [.font: font])
            context.textPosition = CGPoint(x: 24, y: CGFloat(y))
            CTLineDraw(CTLineCreateWithAttributedString(line), context)
        }
        context.endPDFPage()
        context.closePDF()

        guard let document = PDFDocument(url: url), let page = document.page(at: 0) else {
            fail("The fixture could not be read back")
        }
        // Named nothing useful: only the word printed beside it says what it wants.
        page.addAnnotation(textField(named: "topmostSubform[0].Page1[0].f1_07[0]", at: 336))
        page.addAnnotation(textField(named: "Cognome", at: 296))
        page.addAnnotation(textField(named: "email_1", at: 256))

        let locked = textField(named: "Telefono", at: 216)
        locked.isReadOnly = true
        page.addAnnotation(locked)

        let box = PDFAnnotation(bounds: CGRect(x: 100, y: 176, width: 14, height: 14), forType: .widget, withProperties: nil)
        box.widgetFieldType = .button
        box.widgetControlType = .checkBoxControl
        box.fieldName = "Nome"
        page.addAnnotation(box)

        document.write(to: url)
        return url
    }

    private static func textField(named name: String, at y: CGFloat) -> PDFAnnotation {
        let annotation = PDFAnnotation(
            bounds: CGRect(x: 100, y: y, width: 180, height: 18),
            forType: .widget,
            withProperties: nil
        )
        annotation.widgetFieldType = .text
        annotation.fieldName = name
        return annotation
    }

    private static func check(_ condition: Bool, _ message: @autoclosure () -> String) {
        guard condition else { fail(message()) }
    }

    private static func fail(_ message: String) -> Never {
        FileHandle.standardError.write(Data("Form auto-fill smoke test failed: \(message)\n".utf8))
        exit(1)
    }
}
