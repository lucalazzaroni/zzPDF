import AppKit
import PDFKit

/// One thing a form is likely to ask for.
///
/// The aliases are what forms call it, in Italian and in English, because the same form
/// field turns up under both and a reader should not have to care which.
enum ProfileField: String, CaseIterable, Codable, Identifiable {
    case givenName, familyName, fullName
    case email, phone
    case address, city, province, postalCode, country
    case birthDate, birthPlace
    case taxCode, vatNumber
    case organization, department, jobTitle
    case website

    var id: String { rawValue }

    var label: String {
        switch self {
        case .givenName: return "First name"
        case .familyName: return "Last name"
        case .fullName: return "Full name"
        case .email: return "Email"
        case .phone: return "Phone"
        case .address: return "Address"
        case .city: return "City"
        case .province: return "Province or state"
        case .postalCode: return "Postcode"
        case .country: return "Country"
        case .birthDate: return "Date of birth"
        case .birthPlace: return "Place of birth"
        case .taxCode: return "Tax code"
        case .vatNumber: return "VAT number"
        case .organization: return "Organisation"
        case .department: return "Department"
        case .jobTitle: return "Role"
        case .website: return "Website"
        }
    }

    /// Roughly what a form has to say for this to be the field it is asking for.
    ///
    /// Longer aliases win over shorter ones, which is what keeps "cognome" from being read
    /// as "nome" and "surname" from being read as "name".
    var aliases: [String] {
        switch self {
        case .givenName:
            return ["nome", "firstname", "givenname", "forename", "nomeproprio", "prenome"]
        case .familyName:
            return ["cognome", "lastname", "surname", "familyname", "secondname"]
        case .fullName:
            return ["nomeecognome", "nomecognome", "cognomeenome", "cognomenome", "fullname",
                    "nominativo", "nomecompleto", "name", "intestatario", "richiedente",
                    "sottoscritto", "applicantname"]
        case .email:
            return ["email", "mail", "emailaddress", "indirizzoemail", "postaelettronica", "pec"]
        case .phone:
            return ["telefono", "tel", "phone", "phonenumber", "telephone", "cellulare",
                    "mobile", "numeroditelefono", "recapitotelefonico", "recapito"]
        case .address:
            return ["indirizzo", "address", "street", "streetaddress", "via", "residenza",
                    "indirizzodiresidenza", "domicilio"]
        case .city:
            return ["citta", "city", "comune", "localita", "town", "comunediresidenza"]
        case .province:
            return ["provincia", "prov", "state", "region", "regione", "county"]
        case .postalCode:
            return ["cap", "zip", "zipcode", "postalcode", "postcode", "codicepostale"]
        case .country:
            return ["paese", "country", "nazione", "stato", "nationality", "nazionalita",
                    "cittadinanza"]
        case .birthDate:
            return ["datadinascita", "dateofbirth", "dob", "birthdate", "natoil", "natail",
                    "dataluogodinascita"]
        case .birthPlace:
            return ["luogodinascita", "placeofbirth", "birthplace", "natoa", "nataa",
                    "comunedinascita"]
        case .taxCode:
            return ["codicefiscale", "cf", "taxcode", "fiscalcode", "taxidentificationnumber",
                    "codfisc"]
        case .vatNumber:
            return ["partitaiva", "piva", "vat", "vatnumber", "partiva"]
        case .organization:
            return ["ente", "organizzazione", "azienda", "societa", "company", "organisation",
                    "organization", "affiliation", "affiliazione", "universita", "university",
                    "istituto", "institution", "employer", "datoredilavoro"]
        case .department:
            return ["dipartimento", "department", "dept", "reparto", "ufficio", "facolta"]
        case .jobTitle:
            return ["ruolo", "qualifica", "jobtitle", "position", "posizione", "occupation",
                    "professione", "titolo"]
        case .website:
            return ["sito", "sitoweb", "website", "homepage", "web", "url", "orcid"]
        }
    }
}

/// The reader's own details, kept so a form can be filled in from them.
///
/// Deliberately no bank or card details: those belong in a password manager, not in an
/// app's preferences, and a reader who wants one anyway can add it as an entry of their own.
struct PersonalProfile: Codable, Equatable {
    var values: [String: String] = [:]
    /// Anything the standard fields do not cover, named by the reader.
    var custom: [CustomEntry] = []

    struct CustomEntry: Codable, Equatable, Identifiable {
        var id = UUID()
        var name: String = ""
        var value: String = ""
    }

    subscript(field: ProfileField) -> String {
        get { values[field.rawValue] ?? "" }
        set { values[field.rawValue] = newValue }
    }

    var isEmpty: Bool {
        values.values.allSatisfy { $0.trimmingCharacters(in: .whitespaces).isEmpty }
            && custom.allSatisfy { $0.value.trimmingCharacters(in: .whitespaces).isEmpty }
    }

    /// Every detail that has something in it, as a name the matcher can look for and the
    /// value to write. A full name the reader has not given is put together from the two
    /// halves, since plenty of forms ask for it that way round.
    var entries: [(key: String, label: String, aliases: [String], value: String)] {
        var result: [(key: String, label: String, aliases: [String], value: String)] = []
        for field in ProfileField.allCases {
            var value = self[field].trimmingCharacters(in: .whitespacesAndNewlines)
            if field == .fullName, value.isEmpty {
                let joined = [self[.givenName], self[.familyName]]
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }
                    .joined(separator: " ")
                value = joined
            }
            guard !value.isEmpty else { continue }
            result.append((field.rawValue, field.label, field.aliases, value))
        }
        for entry in custom {
            let name = entry.name.trimmingCharacters(in: .whitespacesAndNewlines)
            let value = entry.value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty, !value.isEmpty else { continue }
            result.append((entry.id.uuidString, name, [FormFieldMatcher.normalise(name)], value))
        }
        return result
    }
}

/// Works out which of the reader's details a form field is asking for.
enum FormFieldMatcher {
    /// A field, and the detail that belongs in it.
    struct Match {
        let annotation: PDFAnnotation
        let pageIndex: Int
        /// What to call the field when showing the reader what will be filled in.
        let fieldLabel: String
        /// The detail it was matched to.
        let detailLabel: String
        let currentValue: String
        let newValue: String
    }

    /// Lower case, no accents, letters and digits only, so that "Cod. Fiscale",
    /// "codice_fiscale" and "CodiceFiscale" are all the same thing.
    static func normalise(_ text: String) -> String {
        text.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "en"))
            .unicodeScalars
            .filter { CharacterSet.alphanumerics.contains($0) }
            .reduce(into: "") { $0.unicodeScalars.append($1) }
    }

    /// What a form field is known by: its own name, the description the form gives it, and
    /// whatever is printed beside it on the page.
    ///
    /// Plenty of forms — anything produced by Acrobat's form wizard, every US government
    /// PDF — name their fields `topmostSubform[0].Page1[0].f1_07[0]`, which says nothing.
    /// The words printed next to the box are then the only thing that does.
    static func candidates(for annotation: PDFAnnotation, on page: PDFPage) -> [String] {
        var result: [String] = []
        if let name = annotation.fieldName, !name.isEmpty {
            // Field names are paths; the last step is the part that means something.
            let leaf = name.split(whereSeparator: { $0 == "." }).last.map(String.init) ?? name
            result.append(leaf)
            if leaf != name { result.append(name) }
        }
        if let described = annotation.contents, !described.isEmpty { result.append(described) }
        result.append(contentsOf: printedLabels(for: annotation, on: page))
        return result
    }

    /// The text printed immediately left of a field, and immediately above it, which is
    /// where a form puts the question it is asking.
    private static func printedLabels(for annotation: PDFAnnotation, on page: PDFPage) -> [String] {
        let box = annotation.bounds
        guard box.width > 1, box.height > 1 else { return [] }
        // A little taller than the box, not shorter: a label is set in its own type and
        // sits on its own baseline, so its glyphs routinely fall outside the field's
        // rectangle. Reading only the middle of the band found nothing at all.
        let margin = box.height * 0.35
        let toTheLeft = CGRect(
            x: box.minX - 260,
            y: box.minY - margin,
            width: 260,
            height: box.height + margin * 2
        )
        let above = CGRect(
            x: box.minX - 20,
            y: box.maxY,
            width: max(box.width, 160) + 40,
            height: box.height
        )
        return [toTheLeft, above].compactMap { rect in
            guard let text = page.selection(for: rect)?.string else { return nil }
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
    }

    /// The detail that belongs in a field described by `candidates`, if any does.
    ///
    /// The field's own name is trusted over the words printed near it, and a longer alias
    /// over a shorter one, so "Cognome" is a surname rather than a name and "Nome e
    /// cognome" is the whole thing rather than either half.
    static func detail(
        for candidates: [String],
        in profile: PersonalProfile
    ) -> (label: String, value: String)? {
        let entries = profile.entries
        guard !entries.isEmpty else { return nil }

        var best: (score: Int, label: String, value: String)?
        for (position, candidate) in candidates.enumerated() {
            let text = normalise(candidate)
            guard !text.isEmpty else { continue }
            // The field's own name is the most reliable, the words on the page the least.
            let trust = max(0, 3 - position) * 10
            for entry in entries {
                for alias in entry.aliases where !alias.isEmpty {
                    let score: Int
                    if text == alias {
                        score = 1000 + alias.count * 2 + trust
                    } else if text.contains(alias) {
                        score = 100 + alias.count * 2 + trust
                    } else {
                        continue
                    }
                    if score > (best?.score ?? 0) {
                        best = (score, entry.label, entry.value)
                    }
                }
            }
        }
        guard let best else { return nil }
        return (best.label, best.value)
    }
}
