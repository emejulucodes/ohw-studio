import SwiftUI
import Contacts

struct ContactsView: View {
    @EnvironmentObject var store: WatchStore
    @EnvironmentObject var book: ContactsStore
    @State private var picking = false
    @State private var newName = ""
    @State private var newPhone = ""
    @State private var confirmClear = false

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            SectionHeader(title: "Contacts", subtitle: "Choose who appears in the watch's Contacts and Phone apps. The watch holds up to \(ContactsStore.limit) people.")
            HStack(alignment: .top, spacing: 18) {
                onWatch
                VStack(spacing: 18) { syncCard; manualCard }.frame(width: 360)
            }
        }
        .sheet(isPresented: $picking) { ContactPicker().environmentObject(book) }
        .confirmationDialog("Remove every contact from the watch?", isPresented: $confirmClear) {
            Button("Clear watch contacts", role: .destructive) { Task { await book.send() } }
        }
    }

    // MARK: list

    var onWatch: some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Label("On the watch", systemImage: "person.2.fill").font(.headline)
                    Text("\(book.contacts.count)/\(ContactsStore.limit)").font(.callout.monospacedDigit())
                        .foregroundStyle(book.full ? Color.orange : .secondary)
                    Spacer()
                    Button { picking = true } label: { Label("Add from Contacts", systemImage: "person.crop.circle.badge.plus") }
                        .disabled(book.full)
                }
                if book.contacts.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: "person.crop.circle.dashed").font(.system(size: 40)).foregroundStyle(.tertiary)
                        Text("No contacts yet. Add people from your Contacts app or type one in.").foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, minHeight: 220)
                } else {
                    List {
                        ForEach($book.contacts) { $c in row($c) }
                            .onMove { book.contacts.move(fromOffsets: $0, toOffset: $1) }
                            .onDelete { book.contacts.remove(atOffsets: $0) }
                    }
                    .listStyle(.plain).scrollContentBackground(.hidden)
                    .frame(minHeight: 300, idealHeight: CGFloat(book.contacts.count) * 46 + 10, maxHeight: 520)
                }
                Divider()
                HStack(spacing: 12) {
                    if book.uploading {
                        ProgressView(value: book.progress).frame(width: 140)
                        Text("Sending…").foregroundStyle(.secondary)
                    } else {
                        Image(systemName: book.dirty ? "circle.dashed" : "checkmark.circle.fill")
                            .foregroundStyle(book.dirty ? Color.orange : Color.ok)
                        Text(statusText).font(.callout).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if !book.contacts.isEmpty {
                        Button("Clear", role: .destructive) { book.contacts = [] }.controlSize(.small)
                    }
                    if book.contacts.isEmpty {
                        Button { confirmClear = true } label: { Label("Clear watch contacts", systemImage: "trash") }
                            .disabled(!store.ready || book.uploading || !book.dirty)
                    } else {
                        Button { Task { await book.send() } } label: { Label("Send to watch", systemImage: "applewatch.and.arrow.forward") }
                            .buttonStyle(PrimaryButtonStyle())
                            .disabled(!store.ready || book.uploading || (!book.dirty && book.lastUpload != nil))
                    }
                }
                Text("Sending replaces the whole contact list on the watch. Drag to reorder; the watch shows them in this order.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    var statusText: String {
        if book.dirty { return store.ready ? "Changes not on the watch yet" : "Changes will need sending once the watch connects" }
        if let d = book.lastUpload { return "On the watch · sent \(d.formatted(.relative(presentation: .named)))" }
        return "Nothing sent yet"
    }

    func row(_ c: Binding<WatchContact>) -> some View {
        let v = c.wrappedValue
        return HStack(spacing: 10) {
            ZStack {
                Circle().fill(Color.brand.opacity(0.25)).frame(width: 30, height: 30)
                Text(initials(v.name)).font(.system(size: 12, weight: .semibold))
            }
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 4) {
                    TextField("Name", text: c.name).textFieldStyle(.plain).font(.body)
                    if v.nameTrimmed { warn("Shown as “\(v.watchName)” — the watch keeps 24 bytes of a name") }
                }
                HStack(spacing: 4) {
                    TextField("Phone", text: c.phone).textFieldStyle(.plain).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    if v.phoneTrimmed { warn("Sent as \(v.watchPhone)") }
                    if let l = v.phoneLabel { Text(l).font(.caption2).foregroundStyle(.tertiary) }
                }
            }
            Spacer()
            if v.sourceID != nil {
                Image(systemName: "link").font(.caption).foregroundStyle(.tertiary).help("Linked to the Contacts app; syncing updates it")
            }
            Button { book.contacts.removeAll { $0.id == v.id } } label: { Image(systemName: "minus.circle.fill") }
                .buttonStyle(.plain).foregroundStyle(.secondary)
        }
        .padding(.vertical, 3)
        .listRowBackground(Color.clear)
    }

    func warn(_ s: String) -> some View {
        Image(systemName: "scissors").font(.caption2).foregroundStyle(.orange).help(s)
    }

    func initials(_ n: String) -> String {
        let parts = n.split(separator: " ").prefix(2).compactMap(\.first)
        return parts.isEmpty ? "?" : String(parts).uppercased()
    }

    // MARK: sync

    var syncCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                Label("Sync with the Contacts app", systemImage: "arrow.triangle.2.circlepath").font(.headline)
                if !book.hasAccess {
                    Text(book.access == .notDetermined ? "Allow OHW Studio to read your contacts to pick people and keep them up to date."
                         : "Contacts access is off. Turn it on in System Settings › Privacy & Security › Contacts.")
                        .font(.caption).foregroundStyle(.secondary)
                    if book.access == .notDetermined {
                        Button("Allow access") { Task { await book.requestAccess() } }.buttonStyle(PrimaryButtonStyle())
                    } else {
                        Button("Open Privacy settings") {
                            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Contacts")!)
                        }
                    }
                } else {
                    Picker("Keep in sync", selection: $book.mode) { ForEach(ContactSyncMode.allCases) { Text($0.title).tag($0) } }
                    if book.mode == .group {
                        if book.groups.isEmpty {
                            Text("You have no groups in Contacts. Make one (File › New Group) and put up to \(ContactsStore.limit) people in it.")
                                .font(.caption).foregroundStyle(.orange)
                        } else {
                            Picker("Group", selection: $book.groupID) {
                                Text("Choose…").tag(String?.none)
                                ForEach(book.groups, id: \.identifier) { g in
                                    let n = book.people.filter { $0.groups.contains(g.identifier) }.count
                                    Text("\(g.name) (\(n))").tag(Optional(g.identifier))
                                }
                            }
                            if let g = book.groupID, book.people.filter({ $0.groups.contains(g) }).count > ContactsStore.limit {
                                Text("That group has more than \(ContactsStore.limit) people with numbers; only the first \(ContactsStore.limit) fit.")
                                    .font(.caption).foregroundStyle(.orange)
                            }
                        }
                    }
                    Toggle("Sync automatically", isOn: $book.autoSync)
                    Text(book.mode == .group
                         ? "The watch list follows the group. People you typed in here stay too."
                         : "Names and numbers follow edits in Contacts; people you delete there are removed.")
                        .font(.caption).foregroundStyle(.secondary)
                    Text(book.autoSync ? "Changes are sent to the watch when it's connected." : "Turn this on to send changes without pressing Sync.")
                        .font(.caption).foregroundStyle(.secondary)
                    HStack {
                        Button {
                            Task {
                                let changed = await book.syncFromAddressBook(upload: false)
                                if book.dirty && store.ready { await book.send() }
                                else if !changed { store.show("Already up to date", "checkmark.circle") }
                            }
                        } label: { Label("Sync now", systemImage: "arrow.triangle.2.circlepath") }
                            .disabled(book.uploading || (book.mode == .group && book.groupID == nil))
                        Spacer()
                        if let d = book.lastSync {
                            Text("Checked \(d.formatted(date: .omitted, time: .shortened))").font(.caption2).foregroundStyle(.tertiary)
                        }
                    }
                }
            }
        }
    }

    var manualCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                Label("Add someone by hand", systemImage: "square.and.pencil").font(.headline)
                TextField("Name", text: $newName).textFieldStyle(.roundedBorder)
                TextField("Phone number", text: $newPhone).textFieldStyle(.roundedBorder).onSubmit(addManual)
                HStack {
                    Text("Up to 24 letters and 16 digits.").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Add", action: addManual)
                        .disabled(book.full || newName.trimmingCharacters(in: .whitespaces).isEmpty || WatchContact.cleanPhone(newPhone).isEmpty)
                }
            }
        }
    }

    func addManual() {
        guard !book.full, !newName.isEmpty, !WatchContact.cleanPhone(newPhone).isEmpty else { return }
        book.addManual(name: newName, phone: newPhone); newName = ""; newPhone = ""
    }
}

// MARK: - picker sheet

struct ContactPicker: View {
    @EnvironmentObject var book: ContactsStore
    @Environment(\.dismiss) var dismiss
    @State private var query = ""

    var filtered: [AddressBookPerson] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return book.people }
        let digits = WatchContact.cleanPhone(q)
        return book.people.filter { p in
            p.name.lowercased().contains(q) || (!digits.isEmpty && p.numbers.contains { WatchContact.cleanPhone($0.value).contains(digits) })
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Add from Contacts").font(.title2.bold())
                Spacer()
                Text("\(book.contacts.count)/\(ContactsStore.limit) on the watch").foregroundStyle(book.full ? Color.orange : .secondary)
            }
            if !book.hasAccess {
                VStack(alignment: .leading, spacing: 10) {
                    Text("OHW Studio needs permission to read your contacts.").foregroundStyle(.secondary)
                    if book.access == .notDetermined {
                        Button("Allow access") { Task { await book.requestAccess() } }.buttonStyle(PrimaryButtonStyle())
                    } else {
                        Text("Access was turned off. Turn it on in System Settings › Privacy & Security › Contacts.").font(.caption).foregroundStyle(.orange)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                TextField("Search names or numbers", text: $query).textFieldStyle(.roundedBorder)
                if book.people.isEmpty {
                    Text("No contacts with phone numbers were found.").foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List(filtered) { p in PickerRow(person: p) }
                        .listStyle(.inset)
                }
            }
            HStack { Spacer(); Button("Done") { dismiss() }.keyboardShortcut(.defaultAction) }
        }
        .padding(20)
        .frame(width: 520, height: 600)
        .task { if book.hasAccess && book.people.isEmpty { await book.loadAddressBook() } }
    }
}

private struct PickerRow: View {
    @EnvironmentObject var book: ContactsStore
    let person: AddressBookPerson

    var body: some View {
        let added = book.contacts.first { $0.sourceID == person.id }
        HStack(spacing: 10) {
            Button {
                if added != nil { book.remove(personID: person.id) } else { book.add(person) }
            } label: {
                Image(systemName: added != nil ? "checkmark.circle.fill" : "circle")
                    .font(.title3).foregroundStyle(added != nil ? Color.brand : .secondary)
            }
            .buttonStyle(.plain)
            .disabled(added == nil && book.full)
            VStack(alignment: .leading, spacing: 2) {
                Text(person.name)
                if person.numbers.count == 1 || added == nil {
                    Text((added.map { ($0.phoneLabel ?? "", $0.phone) } ?? person.pick(label: nil).map { ($0.label, $0.value) } ?? ("", "")).1)
                        .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
            }
            Spacer()
            if person.numbers.count > 1 {
                Menu {
                    ForEach(Array(person.numbers.enumerated()), id: \.offset) { _, n in
                        Button("\(n.label): \(n.value)") { book.add(person, number: n) }
                    }
                } label: {
                    Text(added.map { "\($0.phoneLabel ?? "number"): \($0.phone)" } ?? "\(person.numbers.count) numbers")
                        .font(.caption)
                }
                .menuStyle(.borderlessButton).fixedSize()
                .disabled(added == nil && book.full)
            }
        }
        .padding(.vertical, 2)
    }
}
