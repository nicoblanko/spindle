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
    /// Selected tracks (Organize and Mix keep their own).
    var selection: Binding<Set<URL>>? = nil
    /// Double-click: by default load into the free deck.
    var onOpen: ((Record) -> Void)? = nil
    /// Rows drawn greyed (e.g. already in the open set).
    var dimmed: ((Record) -> Bool)? = nil
    /// Ticked off: played already (Mix).
    var played: ((Record) -> Bool)? = nil
    /// Controls before the row number (Mix: played box, A and B).
    var leading: ((Record) -> AnyView)? = nil
    var leadingWidth: CGFloat = 0
    /// The listen column's cell (Organize); without it there's no such column.
    var listen: ((Record) -> AnyView)? = nil
    var listenWidth: CGFloat = 0
    /// Row to keep scrolled into view (the keyboard's place).
    var follow: URL? = nil
    /// Width of the Track column (narrower on Prep).
    var nameWidth: CGFloat = 300
    @State private var anchor: URL?
    @State private var addingField = false
    @State private var managing: FieldRef?
    @State private var renaming: UUID?
    @State private var renameText = ""
    @State private var deleting: CustomField?
    @State private var dropTarget: FieldRef?

    private var context: RecordContext { model.records }
    /// Option lists for this redraw (each cell used to rebuild them).
    @State private var optionCache = OptionCache()

    final class OptionCache {
        var map: [FieldRef: [OptionInfo]] = [:]
        func get(_ f: FieldRef, _ make: () -> [OptionInfo]) -> [OptionInfo] {
            if let v = map[f] { return v }
            let v = make()
            map[f] = v
            return v
        }
    }

    private func options(_ f: FieldRef) -> [OptionInfo] { optionCache.get(f) { context.options(f) } }
    private var selected: Set<URL> {
        get { selection?.wrappedValue ?? model.organizeSelection }
        nonmutating set { if let selection { selection.wrappedValue = newValue } else { model.organizeSelection = newValue } }
    }

    /// Visible columns, worked out once per redraw (rows used to recompute them).
    @State private var columnCache = ColumnCache()
    final class ColumnCache {
        var columns: [FieldRef] = []
        func refresh(_ c: [FieldRef]) { columns = c }
    }
    private var columns: [FieldRef] { columnCache.columns }

    private func width(_ f: FieldRef) -> CGFloat {
        switch f {
        case .name: nameWidth
        case .listen: listenWidth
        case .index: 36
        case .folder: 100
        case .bpm: 58
        case .key: 86
        case .mood: 70
        case .color: 64
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

    private var totalWidth: CGFloat { (leading != nil ? leadingWidth : 0) + columns.reduce(0) { $0 + width($1) } + 44 }

    private var groups: [RecordContext.Group]? {
        view.groupBy.map { context.group(records, by: $0) }
    }

    /// Rows in display order, for shift-click ranges.
    private var flat: [Record] {
        guard let groups else { return records }
        return groups.filter { !view.collapsed.contains($0.id) }.flatMap(\.records)
    }

    var body: some View {
        let _ = optionCache.map.removeAll(keepingCapacity: true)
        let _ = columnCache.refresh(context.orderedFields(view).filter { !view.hidden.contains($0) && ($0 != .listen || listen != nil) })
        GeometryReader { geo in
            ScrollView(.horizontal) {
                VStack(spacing: 0) {
                    header
                    Rectangle().fill(Theme.line).frame(height: 1)
                    ScrollViewReader { proxy in
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
                    .onChange(of: follow) { _, url in
                        if let url { proxy.scrollTo(url) }
                    }
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
            if leading != nil { Color.clear.frame(width: leadingWidth) }
            ForEach(columns, id: \.self) { f in headerCell(f) }
            Button { addingField = true } label: {
                Image(systemName: "plus").font(.system(size: 11, weight: .semibold)).frame(width: 44, height: 28)
            }
            .buttonStyle(.plain)
            .help("Add a column")
            .popover(isPresented: $addingField) {
                VStack(alignment: .leading, spacing: 0) {
                    let removed = context.orderedFields(view)
                        .filter { view.hidden.contains($0) && ($0 != .listen || listen != nil) }
                    if !removed.isEmpty {
                        LabelText("Put back").padding([.horizontal, .top], Theme.space3)
                        FlowLayout(spacing: 4) {
                            ForEach(removed, id: \.self) { f in
                                Button(context.name(f)) { view.hidden.remove(f); addingField = false }
                                    .buttonStyle(SmallButtonStyle())
                            }
                        }
                        .frame(width: 260, alignment: .leading)
                        .padding(Theme.space3)
                        Rectangle().fill(Theme.line).frame(height: 1)
                    }
                    AddFieldView { name, type in
                        let id = model.fields.addField(name: name, type: type)
                        view.hidden.remove(.custom(id))
                    }
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
            } else if f != .listen {
                Text(context.name(f)).lineLimit(1)
            }
            if f.locked && f != .name && f != .folder && f != .index && f != .listen {
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
            guard f != .listen else { return }
            // Click: sort ascending, again descending, again off.
            if view.sortField != f { view.sortField = f; view.sortAscending = true }
            else if view.sortAscending { view.sortAscending = false }
            else { view.sortField = nil }
        }
        // Drag a header onto another to move the column there.
        .draggable(Self.dragKey(f)) { Text(context.name(f)).font(Theme.label).padding(6).background(Theme.control) }
        .dropDestination(for: String.self) { items, _ in
            guard let key = items.first, let moved = context.orderedFields(view).first(where: { Self.dragKey($0) == key }),
                  moved != f else { return false }
            var order = context.orderedFields(view)
            order.removeAll { $0 == moved }
            let target = order.firstIndex(of: f) ?? order.count
            let from = columns.firstIndex(of: moved) ?? 0, to = columns.firstIndex(of: f) ?? 0
            order.insert(moved, at: from < to ? target + 1 : target)
            view.fieldOrder = order
            return true
        } isTargeted: { on in dropTarget = on ? f : (dropTarget == f ? nil : dropTarget) }
        .overlay(alignment: .leading) {
            if dropTarget == f { Rectangle().fill(Theme.accent).frame(width: 2) }
        }
        .contextMenu { headerMenu(f) }
    }

    private static func dragKey(_ f: FieldRef) -> String { "spindle.column:\(f)" }

    @ViewBuilder
    private func headerMenu(_ f: FieldRef) -> some View {
        if f == .listen || f == .index {
            if f == .index { Button("Sort by list order") { view.sortField = nil } }
            Button("Remove column") { view.hidden.insert(f) }
        } else {
            fieldMenu(f)
        }
    }

    @ViewBuilder
    private func fieldMenu(_ f: FieldRef) -> some View {
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
        if f != .name { Button("Remove column") { view.hidden.insert(f) } }
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
        let isSelected = selected.contains(r.id)
        return HStack(spacing: 0) {
            if let leading { leading(r).frame(width: leadingWidth) }
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
        .background {
            ZStack {
                Theme.panel
                if let c = context.meta.color(r.path) { c.color.opacity(isSelected ? 0.45 : 0.28) }
                else if isSelected { Theme.accentSoft }
                if isSelected { Rectangle().strokeBorder(Theme.ink.opacity(0.5), lineWidth: 1) }
            }
        }
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.line.opacity(0.5)).frame(height: 1) }
        .contentShape(Rectangle())
        // Select on the first click straight away; a second click opens.
        // (onTapGesture(count: 2) made every single click wait ~0.3 s.)
        .onTapGesture { click(r) }
        .simultaneousGesture(TapGesture(count: 2).onEnded {
            if let onOpen { onOpen(r) } else { Task { await model.load(url: r.id, into: model.freeDeck) } }
        })
        .draggable(r.track.url)
        .contextMenu { menu(selected.contains(r.id) ? selected : [r.id]) }
    }

    private func click(_ r: Record) {
        // Clicking a row takes the keyboard back from the search field, so
        // space plays instead of typing.
        if NSApp.keyWindow?.firstResponder is NSText { NSApp.keyWindow?.makeFirstResponder(nil) }
        let flags = NSEvent.modifierFlags
        if flags.contains(.command) {
            var s = selected
            if s.contains(r.id) { s.remove(r.id) } else { s.insert(r.id) }
            selected = s
            anchor = r.id
        } else if flags.contains(.shift), let anchor, let a = flat.firstIndex(where: { $0.id == anchor }),
                  let b = flat.firstIndex(where: { $0.id == r.id }) {
            selected = Set(flat[min(a, b)...max(a, b)].map(\.id))
        } else {
            selected = [r.id]
            anchor = r.id
        }
    }

    // MARK: Cells

    @ViewBuilder
    private func cell(_ r: Record, _ f: FieldRef) -> some View {
        switch f {
        case .listen:
            if let listen { listen(r).padding(.horizontal, -Theme.space2) }
        case .index:
            Text("\(r.index)").font(Theme.readoutSm).foregroundStyle(Theme.inkFaint)
                .frame(maxWidth: .infinity, alignment: .center)
        case .name:
            HStack(spacing: 4) {
                if mixes(r) { Circle().fill(Theme.match).frame(width: 6, height: 6) }
                let wasPlayed = played?(r) == true
                Text(r.track.name).font(Theme.body)
                    .foregroundStyle(wasPlayed || dimmed?(r) == true ? Theme.inkFaint : Theme.ink).lineLimit(1)
            }
        case .folder:
            Text(r.track.crate).font(Theme.body).foregroundStyle(Theme.inkMuted).lineLimit(1)
        case .bpm:
            Text(r.analysis.map { String(format: "%.1f", $0.bpm) } ?? "—").font(Theme.readoutSm).foregroundStyle(Theme.ink)
        case .key:
            Text(r.analysis.map { "\($0.camelotNumber) \(KeyStyle.mood(minor: $0.keyMinor))" } ?? "—")
                .font(Theme.readoutSm).foregroundStyle(Theme.ink)
                .opacity(r.analysis.map { $0.keyConfidence < 0.02 ? 0.55 : 1 } ?? 1)
        case .mood:
            if let a = r.analysis {
                let o = options(.mood).first { $0.id == (a.keyMinor ? "A" : "B") }!
                Pill(name: o.name, color: o.color)
            }
        case .energy:
            EnergyBar(energy: r.analysis?.energy ?? 0)
        case .color:
            RowColorButton(color: context.meta.color(r.path)) { picked in
                let paths = selected.contains(r.id) ? selected.map(\.path) : [r.path]
                context.meta.update(paths) { $0.color = picked?.rawValue }
            }
        case .intro:
            Text(r.analysis?.intro.rawValue ?? "").font(Theme.body).foregroundStyle(Theme.inkMuted)
        case .outro:
            Text(r.analysis?.outro.rawValue ?? "").font(Theme.body).foregroundStyle(Theme.inkMuted)
        case .length:
            Text(r.analysis.map { OrganizeView.length($0.duration) } ?? "—").font(Theme.readoutSm).foregroundStyle(Theme.ink)
        case .tempoGroup:
            let keys = context.optionKeys(r, .tempoGroup)
            pills(options(.tempoGroup).filter { keys.contains($0.id) })
        case .mixReady:
            checkbox(context.checked(r, .mixReady), enabled: model.prep.prep(for: r.id) != nil) { on in
                model.prep.update(r.id) { $0.mixReady = on }
            }
        case .tags:
            SelectCell(options: options(.tags), selected: context.optionKeys(r, .tags), multi: true,
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
                SelectCell(options: options(.custom(id)), selected: context.optionKeys(r, .custom(id)), multi: multi,
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

    var body: some View {
        HStack(spacing: 3) {
            ForEach(options.filter { selected.contains($0.id) }) { Pill(name: $0.name, color: $0.color) }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .contentShape(Rectangle())
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


/// A track's row colour: a swatch that opens the soft colours (and none).
struct RowColorButton: View {
    let color: DeckColor?
    let onPick: (DeckColor?) -> Void
    @State private var open = false

    var body: some View {
        Button { open = true } label: {
            RoundedRectangle(cornerRadius: Theme.radiusSm)
                .fill(color?.color ?? Color.clear)
                .overlay(RoundedRectangle(cornerRadius: Theme.radiusSm).strokeBorder(color == nil ? Theme.inkFaint.opacity(0.35) : Color.clear, style: StrokeStyle(lineWidth: 1, dash: [2, 2])))
                .frame(width: 14, height: 14)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Row colour")
        .popover(isPresented: $open, arrowEdge: .bottom) {
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(22), spacing: 6), count: 6), spacing: 6) {
                Button { onPick(nil); open = false } label: {
                    RoundedRectangle(cornerRadius: Theme.radiusSm).strokeBorder(Theme.inkFaint)
                        .overlay(Image(systemName: "xmark").font(.system(size: 9)).foregroundStyle(Theme.inkMuted))
                        .frame(width: 22, height: 22)
                }
                .buttonStyle(.plain).help("No colour")
                ForEach(DeckColor.Group.soft.colors) { c in
                    Button { onPick(c); open = false } label: {
                        RoundedRectangle(cornerRadius: Theme.radiusSm).fill(c.color)
                            .frame(width: 22, height: 22)
                            .overlay(RoundedRectangle(cornerRadius: Theme.radiusSm + 2)
                                .stroke(color == c ? Theme.ink : Color.clear, lineWidth: 2).padding(-3))
                    }
                    .buttonStyle(.plain).help(c.rawValue)
                }
            }
            .padding(Theme.space3)
        }
    }
}
