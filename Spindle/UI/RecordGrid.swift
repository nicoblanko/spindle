//
//  RecordGrid.swift
//  Spindle
//
//  The Organize grid, built like an Airtable grid view: a header you can
//  click to sort and right-click for field actions, "+" to add a field,
//  rows grouped into collapsible sections, and cells you edit in place
//  (select pills, text, numbers, checkboxes, star ratings). Analysed
//  fields are locked.
//

import AppKit
import SwiftUI

struct RecordGrid: View {
    let model: AppModel
    let records: [Record]
    @Binding var view: ViewSettings
    /// Green dot on the name: mixes with the selected track.
    let mixes: (Record) -> Bool
    let menu: (Set<URL>) -> AnyView
    @State private var anchor: URL?
    @State private var addingField = false
    @State private var managing: FieldRef?
    @State private var renaming: UUID?
    @State private var renameText = ""
    @State private var deleting: CustomField?

    private var context: RecordContext { model.records }
    private var selection: Set<URL> { model.organizeSelection }

    private var columns: [FieldRef] { context.orderedFields(view).filter { !view.hidden.contains($0) } }

    private func width(_ f: FieldRef) -> CGFloat {
        switch f {
        case .name: 300
        case .folder: 100
        case .bpm: 58
        case .key: 86
        case .mood: 70
        case .energy: 70
        case .tags: 210
        case .mixReady: 74
        case .tempoGroup: 110
        case .intro, .outro: 80
        case .length: 56
        case .custom(let id):
            switch model.fields.field(id)?.type ?? .text {
            case .multiSelect: 200
            case .singleSelect: 130
            case .text: 180
            case .number: 80
            case .checkbox: 74
            case .rating: 90
            }
        }
    }

    private var totalWidth: CGFloat { 36 + columns.reduce(0) { $0 + width($1) } + 44 }

    private var groups: [RecordContext.Group]? {
        view.groupBy.map { context.group(records, by: $0) }
    }

    /// Rows in display order, for shift-click ranges.
    private var flat: [Record] {
        guard let groups else { return records }
        return groups.filter { !view.collapsed.contains($0.id) }.flatMap(\.records)
    }

    var body: some View {
        GeometryReader { geo in
            ScrollView(.horizontal) {
                VStack(spacing: 0) {
                    header
                    Rectangle().fill(Theme.line).frame(height: 1)
                    ScrollView(.vertical) {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            if let groups {
                                ForEach(groups) { g in groupSection(g) }
                            } else {
                                ForEach(records) { row($0) }
                            }
                            Text("\(records.count) tracks")
                                .font(Theme.caption).foregroundStyle(Theme.inkFaint)
                                .padding(Theme.space2)
                        }
                        // Rebuild rows when the columns change, so no row keeps an old layout.
                        .id(columns.map { "\($0)" }.joined(separator: "|"))
                    }
                }
                .frame(width: max(totalWidth, geo.size.width), height: geo.size.height, alignment: .topLeading)
            }
        }
        .background(Theme.panel)
        .sheet(item: Binding(get: { managing.map(ManagingRef.init) }, set: { managing = $0?.ref })) { m in
            manageSheet(m.ref)
        }
        .confirmationDialog("Delete the field \(deleting?.name ?? "")?", isPresented: Binding(
            get: { deleting != nil }, set: { if !$0 { deleting = nil } })) {
            Button("Delete field", role: .destructive) {
                if let f = deleting {
                    view.hidden.remove(.custom(f.id))
                    view.conditions.removeAll { $0.field == .custom(f.id) }
                    if view.groupBy == .custom(f.id) { view.groupBy = nil }
                    if view.sortField == .custom(f.id) { view.sortField = nil }
                    model.fields.deleteField(f.id)
                }
                deleting = nil
            }
        } message: {
            Text("Its values are removed from every track. Your audio files are not touched.")
        }
    }

    private struct ManagingRef: Identifiable { let ref: FieldRef; var id: String { "\(ref)" } }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 0) {
            Text("#").frame(width: 36)
            ForEach(columns, id: \.self) { f in headerCell(f) }
            Button { addingField = true } label: {
                Image(systemName: "plus").font(.system(size: 11, weight: .semibold)).frame(width: 44, height: 28)
            }
            .buttonStyle(.plain)
            .help("Add a field")
            .popover(isPresented: $addingField) {
                AddFieldView { name, type in
                    let id = model.fields.addField(name: name, type: type)
                    view.hidden.remove(.custom(id))
                }
            }
            Spacer(minLength: 0)
        }
        .font(Theme.label)
        .foregroundStyle(Theme.inkMuted)
        .frame(height: 28)
        .background(Theme.panelRaised)
    }

    private func headerCell(_ f: FieldRef) -> some View {
        HStack(spacing: 4) {
            if case .custom(let id) = f, let field = model.fields.field(id) {
                Image(systemName: field.type.icon).font(.system(size: 9))
            }
            if renaming != nil, case .custom(let id) = f, renaming == id {
                TextField("Name", text: $renameText)
                    .textFieldStyle(.plain)
                    .onSubmit {
                        if var field = model.fields.field(id), !renameText.trimmingCharacters(in: .whitespaces).isEmpty {
                            field.name = renameText.trimmingCharacters(in: .whitespaces)
                            model.fields.update(field)
                        }
                        renaming = nil
                    }
                    .onExitCommand { renaming = nil }
            } else {
                Text(context.name(f)).lineLimit(1)
            }
            if f.locked && f != .name && f != .folder {
                Image(systemName: "lock.fill").font(.system(size: 7)).foregroundStyle(Theme.inkFaint)
                    .help("Filled in by analysis")
            }
            if view.sortField == f {
                Image(systemName: view.sortAscending ? "arrow.up" : "arrow.down").font(.system(size: 8, weight: .bold))
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Theme.space2)
        .frame(width: width(f), height: 28, alignment: .leading)
        .overlay(alignment: .trailing) { Rectangle().fill(Theme.line).frame(width: 1) }
        .contentShape(Rectangle())
        .onTapGesture {
            // Click: sort ascending, again descending, again off.
            if view.sortField != f { view.sortField = f; view.sortAscending = true }
            else if view.sortAscending { view.sortAscending = false }
            else { view.sortField = nil }
        }
        .contextMenu { headerMenu(f) }
    }

    @ViewBuilder
    private func headerMenu(_ f: FieldRef) -> some View {
        if case .custom(let id) = f, let field = model.fields.field(id) {
            Button("Rename field") { renameText = field.name; renaming = id }
            if field.type == .multiSelect || field.type == .singleSelect {
                Button("Edit options…") { managing = f }
            }
            Divider()
        }
        if f == .tags { Button("Edit options…") { managing = .tags }; Divider() }
        Button("Sort first → last") { view.sortField = f; view.sortAscending = true }
        Button("Sort last → first") { view.sortField = f; view.sortAscending = false }
        if f != .name { Button("Group by this field") { view.groupBy = f; view.collapsed = [] } }
        Button("Filter by this field") {
            view.conditions.append(FilterCondition(field: f, op: FilterOp.ops(for: context.kind(f)).first!))
        }
        if f != .name { Button("Hide field") { view.hidden.insert(f) } }
        if case .custom(let id) = f, let field = model.fields.field(id) {
            Divider()
            Button("Delete field…", role: .destructive) { deleting = field }
        }
    }

    // MARK: Groups and rows

    @ViewBuilder
    private func groupSection(_ g: RecordContext.Group) -> some View {
        let collapsed = view.collapsed.contains(g.id)
        HStack(spacing: Theme.space2) {
            Image(systemName: collapsed ? "chevron.right" : "chevron.down").font(.system(size: 9, weight: .bold))
            Text(view.groupBy.map(context.name) ?? "").font(Theme.caption).foregroundStyle(Theme.inkMuted)
            if g.options.isEmpty {
                Text(g.title).font(Theme.body).foregroundStyle(Theme.ink)
            } else {
                ForEach(g.options) { Pill(name: $0.name, color: $0.color) }
            }
            Text("\(g.records.count)").font(Theme.readoutSm).foregroundStyle(Theme.inkFaint)
            Spacer()
        }
        .padding(.horizontal, Theme.space2)
        .frame(height: 30)
        .background(Theme.panelRaised)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.line).frame(height: 1) }
        .contentShape(Rectangle())
        .onTapGesture {
            if collapsed { view.collapsed.remove(g.id) } else { view.collapsed.insert(g.id) }
        }
        if !collapsed {
            ForEach(g.records) { row($0) }
        }
    }

    private func row(_ r: Record) -> some View {
        let selected = selection.contains(r.id)
        return HStack(spacing: 0) {
            Text("\(r.index)").font(Theme.readoutSm).foregroundStyle(Theme.inkFaint).frame(width: 36)
            ForEach(columns, id: \.self) { f in
                cell(r, f)
                    .padding(.horizontal, Theme.space2)
                    .frame(width: width(f), height: 30, alignment: .leading)
                    .clipped()
                    .overlay(alignment: .trailing) { Rectangle().fill(Theme.line.opacity(0.5)).frame(width: 1) }
            }
            Spacer(minLength: 0)
        }
        .frame(height: 30)
        .background(selected ? Theme.accentSoft : Theme.panel)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.line.opacity(0.5)).frame(height: 1) }
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { Task { await model.load(url: r.id, into: model.freeDeck) } }
        .onTapGesture { click(r) }
        .draggable(r.track.url)
        .contextMenu { menu(selection.contains(r.id) ? selection : [r.id]) }
    }

    private func click(_ r: Record) {
        let flags = NSEvent.modifierFlags
        if flags.contains(.command) {
            var s = selection
            if s.contains(r.id) { s.remove(r.id) } else { s.insert(r.id) }
            model.organizeSelection = s
            anchor = r.id
        } else if flags.contains(.shift), let anchor, let a = flat.firstIndex(where: { $0.id == anchor }),
                  let b = flat.firstIndex(where: { $0.id == r.id }) {
            model.organizeSelection = Set(flat[min(a, b)...max(a, b)].map(\.id))
        } else {
            model.organizeSelection = [r.id]
            anchor = r.id
        }
    }

    // MARK: Cells

    @ViewBuilder
    private func cell(_ r: Record, _ f: FieldRef) -> some View {
        switch f {
        case .name:
            HStack(spacing: 4) {
                if mixes(r) { Circle().fill(Theme.match).frame(width: 6, height: 6) }
                Text(r.track.name).font(Theme.body).foregroundStyle(Theme.ink).lineLimit(1)
            }
        case .folder:
            Text(r.track.crate).font(Theme.body).foregroundStyle(Theme.inkMuted).lineLimit(1)
        case .bpm:
            Text(r.analysis.map { String(format: "%.1f", $0.bpm) } ?? "—").font(Theme.readoutSm).foregroundStyle(Theme.ink)
        case .key:
            KeyChip(analysis: r.analysis)
        case .mood:
            if let a = r.analysis {
                let o = context.options(.mood).first { $0.id == (a.keyMinor ? "A" : "B") }!
                Pill(name: o.name, color: o.color)
            }
        case .energy:
            EnergyBar(energy: r.analysis?.energy ?? 0)
        case .intro:
            Text(r.analysis?.intro.rawValue ?? "").font(Theme.body).foregroundStyle(Theme.inkMuted)
        case .outro:
            Text(r.analysis?.outro.rawValue ?? "").font(Theme.body).foregroundStyle(Theme.inkMuted)
        case .length:
            Text(r.analysis.map { OrganizeView.length($0.duration) } ?? "—").font(Theme.readoutSm).foregroundStyle(Theme.ink)
        case .tempoGroup:
            pills(context.options(.tempoGroup).filter { context.optionKeys(r, .tempoGroup).contains($0.id) })
        case .mixReady:
            checkbox(context.checked(r, .mixReady), enabled: model.prep.prep(for: r.id) != nil) { on in
                model.prep.update(r.id) { $0.mixReady = on }
            }
        case .tags:
            SelectCell(options: context.options(.tags), selected: context.optionKeys(r, .tags), multi: true,
                       onToggle: { id in
                           guard let uuid = UUID(uuidString: id) else { return }
                           let has = model.library.tags.ids(for: r.path).contains(uuid)
                           model.library.tags.set(uuid, on: [r.path], !has)
                       },
                       onCreate: { name in
                           (model.library.tags.tag(named: name)?.id ?? model.library.tags.create(name: name)).uuidString
                       },
                       onManage: { managing = .tags })
        case .custom(let id):
            customCell(r, id)
        }
    }

    @ViewBuilder
    private func customCell(_ r: Record, _ id: UUID) -> some View {
        if let field = model.fields.field(id) {
            let value = model.fields.value(r.path, id)
            switch field.type {
            case .multiSelect, .singleSelect:
                let multi = field.type == .multiSelect
                SelectCell(options: context.options(.custom(id)), selected: context.optionKeys(r, .custom(id)), multi: multi,
                           onToggle: { option in
                               guard let uuid = UUID(uuidString: option) else { return }
                               var ids: [UUID] = { if case .options(let x)? = model.fields.value(r.path, id) { return x }; return [] }()
                               if multi {
                                   if let k = ids.firstIndex(of: uuid) { ids.remove(at: k) } else { ids.append(uuid) }
                               } else {
                                   ids = ids == [uuid] ? [] : [uuid]
                               }
                               model.fields.set(r.path, id, ids.isEmpty ? nil : .options(ids))
                           },
                           onCreate: { name in model.fields.addOption(id, name: name)?.uuidString },
                           onManage: { managing = .custom(id) })
            case .text:
                TextCell(text: { if case .text(let t)? = value { return t }; return "" }()) { t in
                    model.fields.set(r.path, id, t.isEmpty ? nil : .text(t))
                }
            case .number:
                TextCell(text: { if case .number(let n)? = value { return n == n.rounded() ? "\(Int(n))" : "\(n)" }; return "" }(),
                         numeric: true) { t in
                    let n = Double(t.replacingOccurrences(of: ",", with: "."))
                    model.fields.set(r.path, id, n.map { .number($0) })
                }
            case .checkbox:
                checkbox({ if case .bool(let b)? = value { return b }; return false }(), enabled: true) { on in
                    model.fields.set(r.path, id, on ? .bool(true) : nil)
                }
            case .rating:
                RatingView(value: { if case .rating(let n)? = value { return n }; return 0 }()) { n in
                    model.fields.set(r.path, id, n > 0 ? .rating(n) : nil)
                }
            }
        }
    }

    private func pills(_ options: [OptionInfo]) -> some View {
        HStack(spacing: 3) { ForEach(options) { Pill(name: $0.name, color: $0.color) } }
    }

    private func checkbox(_ on: Bool, enabled: Bool, set: @escaping (Bool) -> Void) -> some View {
        Button { set(!on) } label: {
            Image(systemName: on ? "checkmark.square.fill" : "square")
                .font(.system(size: 13))
                .foregroundStyle(on ? Theme.match : Theme.inkFaint)
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
    }

    // MARK: Option manager

    @ViewBuilder
    private func manageSheet(_ ref: FieldRef) -> some View {
        if ref == .tags {
            let tags = model.library.tags
            ManageOptionsView(
                title: "Tags",
                items: tags.manualTags.map { .init(id: $0.id.uuidString, name: $0.name, colorIndex: $0.colorIndex) },
                onRename: { id, name in
                    if var t = tags.tag(UUID(uuidString: id)), !name.isEmpty { t.name = name; tags.update(t) }
                },
                onRecolor: { id, c in if var t = tags.tag(UUID(uuidString: id)) { t.colorIndex = c; tags.update(t) } },
                onDelete: { id in if let u = UUID(uuidString: id) { tags.delete(u) } },
                onMove: { tags.moveOptions(from: $0, to: $1) },
                onAdd: { name in _ = tags.create(name: name) })
        } else if case .custom(let fid) = ref, let field = model.fields.field(fid) {
            let fields = model.fields
            ManageOptionsView(
                title: field.name,
                items: field.options.map { .init(id: $0.id.uuidString, name: $0.name, colorIndex: $0.colorIndex) },
                onRename: { id, name in
                    guard var f = fields.field(fid), let k = f.options.firstIndex(where: { $0.id.uuidString == id }), !name.isEmpty else { return }
                    f.options[k].name = name
                    fields.update(f)
                },
                onRecolor: { id, c in
                    guard var f = fields.field(fid), let k = f.options.firstIndex(where: { $0.id.uuidString == id }) else { return }
                    f.options[k].colorIndex = c
                    fields.update(f)
                },
                onDelete: { id in if let u = UUID(uuidString: id) { fields.deleteOption(fid, u) } },
                onMove: { from, to in
                    guard var f = fields.field(fid) else { return }
                    f.options.move(fromOffsets: from, toOffset: to)
                    fields.update(f)
                },
                onAdd: { name in _ = fields.addOption(fid, name: name) })
        }
    }
}

/// A select cell: pills; click opens the option picker.
private struct SelectCell: View {
    let options: [OptionInfo]
    let selected: [String]
    let multi: Bool
    let onToggle: (String) -> Void
    let onCreate: (String) -> String?
    let onManage: () -> Void
    @State private var open = false
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 3) {
            ForEach(options.filter { selected.contains($0.id) }) { Pill(name: $0.name, color: $0.color) }
            Spacer(minLength: 0)
            if hovering && selected.isEmpty {
                Image(systemName: "plus").font(.system(size: 9)).foregroundStyle(Theme.inkFaint)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture { open = true }
        .popover(isPresented: $open, arrowEdge: .bottom) {
            OptionPicker(options: options, selected: selected, multi: multi,
                         onToggle: onToggle, onCreate: onCreate, onManage: onManage)
        }
    }
}

/// Text or number: double-click to edit, Enter to save, Escape to cancel.
private struct TextCell: View {
    let text: String
    var numeric = false
    let onCommit: (String) -> Void
    @State private var editing = false
    @State private var draft = ""
    @FocusState private var focused: Bool

    var body: some View {
        Group {
            if editing {
                TextField("", text: $draft)
                    .textFieldStyle(.plain)
                    .focused($focused)
                    .onSubmit { onCommit(draft.trimmingCharacters(in: .whitespaces)); editing = false }
                    .onExitCommand { editing = false }
                    .onChange(of: focused) { if !focused && editing { onCommit(draft.trimmingCharacters(in: .whitespaces)); editing = false } }
                    .onAppear { focused = true }
            } else {
                Text(text.isEmpty ? " " : text)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                    .onTapGesture(count: 2) { draft = text; editing = true }
            }
        }
        .font(numeric ? Theme.readoutSm : Theme.body)
        .foregroundStyle(Theme.ink)
    }
}
