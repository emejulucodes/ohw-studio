import Foundation
import Contacts

// Contacts on the watch — CONTACT 0x0704 via sendStream (CO FIT ContactListActivity.syncContact).
// Each contact is 40 bytes: name UTF-8 (24 B, zero-padded) + phone ASCII (16 B, zero-padded).
// An upload replaces the whole list; this firmware holds 20 (DeviceInfo ContactSize 0 → 20).
// Verified on the OHW-11 (2026-11-05): the watch acks with status 0 once it has settled after connecting.

struct WatchContact: Codable, Identifiable, Hashable {
    var id = UUID()
    var name: String
    var phone: String
    /// CNContact identifier when it came from the Contacts app; nil for contacts typed in here.
    var sourceID: String? = nil
    /// Which number was picked, so a sync keeps the same one (label like "mobile").
    var phoneLabel: String? = nil

    static let nameBytes = 24, phoneBytes = 16

    /// Name cut to 24 UTF-8 bytes without splitting a character.
    var watchName: String {
        var out = ""
        for ch in name.trimmingCharacters(in: .whitespaces) {
            if (out + String(ch)).utf8.count > Self.nameBytes { break }
            out.append(ch)
        }
        return out
    }
    /// Phone reduced to dial characters, at most 16.
    var watchPhone: String { String(Self.cleanPhone(phone).prefix(Self.phoneBytes)) }
    var nameTrimmed: Bool { watchName != name.trimmingCharacters(in: .whitespaces) }
    var phoneTrimmed: Bool { watchPhone != Self.cleanPhone(phone) }

    static func cleanPhone(_ s: String) -> String {
        var out = ""
        for (i, c) in s.enumerated() where c.isNumber || c == "*" || c == "#" || (c == "+" && i == 0 && out.isEmpty) {
            out.append(c.isASCII ? c : Character(String(c.wholeNumberValue ?? 0)))
        }
        return out
    }

    var record: [UInt8] {
        func pad(_ b: [UInt8], _ n: Int) -> [UInt8] { Array(b.prefix(n)) + [UInt8](repeating: 0, count: max(0, n - b.count)) }
        return pad(Array(watchName.utf8), Self.nameBytes) + pad(Array(watchPhone.utf8), Self.phoneBytes)
    }
}

/// One person in the Contacts app, with all their numbers.
struct AddressBookPerson: Identifiable, Hashable {
    let id: String
    let name: String
    let numbers: [(label: String, value: String)]
    let groups: Set<String>
    static func == (a: Self, b: Self) -> Bool { a.id == b.id }
    func hash(into h: inout Hasher) { h.combine(id) }

    func pick(label: String?) -> (label: String, value: String)? {
        if let l = label, let n = numbers.first(where: { $0.label == l }) { return n }
        return numbers.first(where: { $0.label.lowercased().contains("mobile") || $0.label.lowercased().contains("iphone") }) ?? numbers.first
    }
}

enum ContactSyncMode: String, Codable, CaseIterable, Identifiable {
    case chosen, group
    var id: String { rawValue }
    var title: String { self == .chosen ? "The contacts I picked" : "A group from Contacts" }
}

@MainActor
final class ContactsStore: ObservableObject {
    unowned let store: WatchStore
    var link: WatchLink { store.link }
    static let limit = 20

    @Published var contacts: [WatchContact] = ExtrasStore.load("watchContacts") ?? [] { didSet { ExtrasStore.save(contacts, "watchContacts"); dirty = contacts != uploaded } }
    /// What the watch has now (as far as we know), to show "not sent yet".
    @Published private(set) var uploaded: [WatchContact] = ExtrasStore.load("watchContactsUploaded") ?? []
    @Published private(set) var dirty = false
    @Published var lastUpload: Date? = UserDefaults.standard.object(forKey: "watchContactsDate") as? Date
    @Published var uploading = false
    @Published var progress: Double = 0

    @Published var autoSync: Bool = UserDefaults.standard.bool(forKey: "contactsAutoSync") { didSet { UserDefaults.standard.set(autoSync, forKey: "contactsAutoSync"); if autoSync { Task { await syncFromAddressBook(upload: true) } } } }
    @Published var mode: ContactSyncMode = ContactSyncMode(rawValue: UserDefaults.standard.string(forKey: "contactsSyncMode") ?? "") ?? .chosen { didSet { UserDefaults.standard.set(mode.rawValue, forKey: "contactsSyncMode") } }
    @Published var groupID: String? = UserDefaults.standard.string(forKey: "contactsGroup") { didSet { UserDefaults.standard.set(groupID, forKey: "contactsGroup") } }

    @Published var access: CNAuthorizationStatus = CNContactStore.authorizationStatus(for: .contacts)
    @Published var people: [AddressBookPerson] = []
    @Published var groups: [CNGroup] = []
    @Published var lastSync: Date?

    private let cn = CNContactStore()
    private var observer: NSObjectProtocol?
    private var syncWork: Task<Void, Never>?

    init(store: WatchStore) {
        self.store = store
        dirty = contacts != uploaded
        observer = NotificationCenter.default.addObserver(forName: .CNContactStoreDidChange, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.addressBookChanged() }
        }
        if hasAccess { Task { await loadAddressBook() } }
    }

    var hasAccess: Bool { access == .authorized || access.rawValue == 4 /* .limited */ }
    var full: Bool { contacts.count >= Self.limit }

    // MARK: Contacts app

    func requestAccess() async {
        let ok = (try? await cn.requestAccess(for: .contacts)) ?? false
        access = CNContactStore.authorizationStatus(for: .contacts)
        if ok { await loadAddressBook() }
    }

    func loadAddressBook() async {
        guard hasAccess else { return }
        let cn = self.cn
        let result: ([AddressBookPerson], [CNGroup]) = await Task.detached {
            let keys: [CNKeyDescriptor] = [CNContactFormatter.descriptorForRequiredKeys(for: .fullName),
                                           CNContactPhoneNumbersKey as CNKeyDescriptor, CNContactOrganizationNameKey as CNKeyDescriptor]
            let groups = (try? cn.groups(matching: nil)) ?? []
            var memberOf: [String: Set<String>] = [:]
            for g in groups {
                let req = CNContactFetchRequest(keysToFetch: [CNContactIdentifierKey as CNKeyDescriptor])
                req.predicate = CNContact.predicateForContactsInGroup(withIdentifier: g.identifier)
                try? cn.enumerateContacts(with: req) { c, _ in memberOf[c.identifier, default: []].insert(g.identifier) }
            }
            var out: [AddressBookPerson] = []
            let req = CNContactFetchRequest(keysToFetch: keys)
            req.sortOrder = .userDefault
            try? cn.enumerateContacts(with: req) { c, _ in
                let nums = c.phoneNumbers.map { (label: CNLabeledValue<NSString>.localizedString(forLabel: $0.label ?? "phone"), value: $0.value.stringValue) }
                guard !nums.isEmpty else { return }
                var name = CNContactFormatter.string(from: c, style: .fullName) ?? ""
                if name.isEmpty { name = c.organizationName }
                guard !name.isEmpty else { return }
                out.append(AddressBookPerson(id: c.identifier, name: name, numbers: nums, groups: memberOf[c.identifier] ?? []))
            }
            return (out, groups)
        }.value
        people = result.0
        groups = result.1
    }

    private func addressBookChanged() {
        guard hasAccess else { return }
        syncWork?.cancel()
        syncWork = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard !Task.isCancelled, let self else { return }
            await self.syncFromAddressBook(upload: self.autoSync)
        }
    }

    /// Refresh linked contacts (or the chosen group) from the Contacts app. Uploads when something changed and `upload` is set.
    @discardableResult
    func syncFromAddressBook(upload: Bool) async -> Bool {
        guard hasAccess else { return false }
        await loadAddressBook()
        // A failed or empty read must never wipe the list.
        guard !people.isEmpty else { return false }
        let byID = Dictionary(uniqueKeysWithValues: people.map { ($0.id, $0) })
        var next: [WatchContact]
        switch mode {
        case .chosen:
            next = contacts.compactMap { c in
                guard let sid = c.sourceID else { return c }          // typed in here: keep
                guard let p = byID[sid], let n = p.pick(label: c.phoneLabel) else { return nil }  // deleted in Contacts: drop
                var u = c; u.name = p.name; u.phone = n.value; u.phoneLabel = n.label
                return u
            }
        case .group:
            guard let g = groupID else { return false }
            let manual = contacts.filter { $0.sourceID == nil }
            let old = Dictionary(contacts.compactMap { c in c.sourceID.map { ($0, c) } }, uniquingKeysWith: { a, _ in a })
            let members = people.filter { $0.groups.contains(g) }.compactMap { p -> WatchContact? in
                guard let n = p.pick(label: old[p.id]?.phoneLabel) else { return nil }
                return WatchContact(id: old[p.id]?.id ?? UUID(), name: p.name, phone: n.value, sourceID: p.id, phoneLabel: n.label)
            }
            guard !members.isEmpty else { return false }
            next = Array((members + manual).prefix(Self.limit))
        }
        lastSync = Date()
        let changed = next != contacts
        if changed { contacts = next }
        if upload && dirty && store.ready && !contacts.isEmpty { await send() }
        return changed
    }

    // MARK: editing

    func add(_ p: AddressBookPerson, number: (label: String, value: String)? = nil) {
        guard !full, let n = number ?? p.pick(label: nil) else { return }
        if let i = contacts.firstIndex(where: { $0.sourceID == p.id }) {
            contacts[i].phone = n.value; contacts[i].phoneLabel = n.label
        } else {
            contacts.append(WatchContact(name: p.name, phone: n.value, sourceID: p.id, phoneLabel: n.label))
        }
    }
    func remove(personID: String) { contacts.removeAll { $0.sourceID == personID } }
    func isAdded(_ p: AddressBookPerson) -> Bool { contacts.contains { $0.sourceID == p.id } }

    func addManual(name: String, phone: String) {
        guard !full else { return }
        contacts.append(WatchContact(name: name, phone: phone))
    }

    // MARK: watch

    var payload: [UInt8] { contacts.prefix(Self.limit).flatMap(\.record) }

    func send() async {
        guard store.ready else { store.show("Connect the watch first", "exclamationmark.triangle.fill", error: true); return }
        uploading = true; progress = 0
        defer { uploading = false }
        do {
            let list = Array(contacts.prefix(Self.limit))
            if list.isEmpty {
                link.send(BleKey.contact, BleFlag.delete)
                try await Task.sleep(nanoseconds: 800_000_000)
            } else {
                try await link.uploadStream(BleKey.contact, payload, settle: 2) { [weak self] p in self?.progress = p }
            }
            uploaded = list
            ExtrasStore.save(uploaded, "watchContactsUploaded")
            dirty = contacts != uploaded
            lastUpload = Date(); UserDefaults.standard.set(lastUpload, forKey: "watchContactsDate")
            store.show(list.isEmpty ? "Contacts cleared on the watch" : "\(list.count) contact\(list.count == 1 ? "" : "s") on the watch", "person.crop.circle.badge.checkmark")
        } catch {
            store.show("Contacts upload failed: \(error.localizedDescription)", "exclamationmark.triangle.fill", error: true)
        }
    }

    /// After connecting: catch up on changes made while the watch was away.
    func onConnected() async {
        if autoSync { _ = await syncFromAddressBook(upload: false) }
        if autoSync && dirty && !contacts.isEmpty { await send() }
    }
}
