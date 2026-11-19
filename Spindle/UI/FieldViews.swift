//
//  FieldViews.swift
//  Spindle
//
//  The Airtable-style pieces of the Organize grid: option pills, the
//  option picker (search, add, remove), the option manager, the new-field
//  popover, star ratings, and the Filter, Group and Hide fields popovers.
//

import SwiftUI

/// A select option: pastel capsule with dark text, as in Airtable.
struct Pill: View {
    let name: String
    let color: Color
    var onRemove: (() -> Void)? = nil

    var body: some View {
        HStack(spacing: 3) {
            Text(name).lineLimit(1)
            if let onRemove {
                Button(action: onRemove) {
                    Image(systemName: "xmark").font(.system(size: 8, weight: .bold))
                }
                .buttonStyle(.plain)
            }
        }
        .font(Theme.caption)
        .foregroundStyle(TagDef.textColor)
        .padding(.horizontal, 7)
        .padding(.vertical, 1.5)
        .background(color)
        .clipShape(Capsule())
    }
}

/// The dropdown of a select cell: chosen options on top (× removes), a
/// "Find an option" box, matching options below; Enter picks the
/// highlighted one, or adds a new option when nothing matches.
struct OptionPicker: View {
    let options: [OptionInfo]
    let selected: [String]
    let multi: Bool
    let onToggle: (String) -> Void
    /// Creates an option and returns its id.
    let onCreate: (String) -> String?
    var onManage: (() -> Void)? = nil
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var highlight = 0
    @FocusState private var focused: Bool

    private var matches: [OptionInfo] {
        let q = query.trimmingCharacters(in: .whitespaces)
        return options.filter { (multi ? !selected.contains($0.id) : true)
            && (q.isEmpty || $0.name.localizedCaseInsensitiveContains(q)) }
    }

    private var canAdd: Bool {
        let q = query.trimmingCharacters(in: .whitespaces)
        return !q.isEmpty && !options.contains { $0.name.compare(q, options: .caseInsensitive) == .orderedSame }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if !selected.isEmpty {
                FlowLayout(spacing: 4) {
                    ForEach(selected, id: \.self) { id in
                        if let o = options.first(where: { $0.id == id }) {
                            Pill(name: o.name, color: o.color) { onToggle(id) }
                        }
                    }
                }
                .padding(Theme.space2)
                Divider()
            }
            TextField("Find an option", text: $query)
                .textFieldStyle(.plain)
                .font(Theme.body)
                .focused($focused)
                .padding(Theme.space2)
                .onSubmit(pick)
                .onKeyPress(.downArrow) { highlight = min(highlight + 1, rowCount - 1); return .handled }
                .onKeyPress(.upArrow) { highlight = max(highlight - 1, 0); return .handled }
                .onChange(of: query) { highlight = 0 }
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 1) {
                    ForEach(Array(matches.enumerated()), id: \.element.id) { i, o in
                        HStack {
                            Pill(name: o.name, color: o.color)
                            Spacer()
                            if !multi && selected.contains(o.id) { Image(systemName: "checkmark").font(.system(size: 10)) }
                        }
                        .padding(.horizontal, Theme.space2).padding(.vertical, 3)
                        .background(i == highlight ? Theme.control : Color.clear)
                        .contentShape(Rectangle())
                        .onTapGesture { choose(o.id) }
                        .onHover { if $0 { highlight = i } }
                    }
                    if canAdd {
                        HStack(spacing: 4) {
                            Image(systemName: "plus").font(.system(size: 10))
                            Text("Add option").foregroundStyle(Theme.inkMuted)
                            Pill(name: query.trimmingCharacters(in: .whitespaces), color: TagStore.palette[options.count % TagStore.palette.count])
                        }
                        .font(Theme.caption)
                        .padding(.horizontal, Theme.space2).padding(.vertical, 4)
                        .background(highlight == matches.count ? Theme.control : Color.clear)
                        .contentShape(Rectangle())
                        .onTapGesture(perform: add)
                    }
                    if matches.isEmpty && !canAdd {
                        Text(options.isEmpty ? "Type to add the first option" : "No more options")
                            .font(Theme.caption).foregroundStyle(Theme.inkFaint).padding(Theme.space2)
                    }
                }
                .padding(.vertical, 2)
            }
            .frame(maxHeight: 240)
            if let onManage {
                Divider()
                Button("Edit options…") { dismiss(); onManage() }
                    .buttonStyle(.plain)
                    .font(Theme.caption).foregroundStyle(Theme.inkMuted)
                    .padding(Theme.space2)
            }
        }
        .frame(width: 260)
        .background(Theme.panel)
        .onAppear { focused = true }
        .onExitCommand { dismiss() }
    }

    private var rowCount: Int { matches.count + (canAdd ? 1 : 0) }

    private func pick() {
        if highlight < matches.count { choose(matches[highlight].id) } else if canAdd { add() }
    }

    private func choose(_ id: String) {
        onToggle(id)
        query = ""
        if !multi { dismiss() }
    }

    private func add() {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty, let id = onCreate(q) else { return }
        onToggle(id)
        query = ""
        if !multi { dismiss() }
    }
}

/// Wraps pills onto new lines.
struct FlowLayout: Layout {
    var spacing: CGFloat = 4

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 240
        var x: CGFloat = 0, y: CGFloat = 0, row: CGFloat = 0
        for s in subviews {
            let size = s.sizeThatFits(.unspecified)
            if x + size.width > width && x > 0 { x = 0; y += row + spacing; row = 0 }
            x += size.width + spacing
            row = max(row, size.height)
        }
        return CGSize(width: width, height: y + row)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, row: CGFloat = 0
        for s in subviews {
            let size = s.sizeThatFits(.unspecified)
            if x + size.width > bounds.maxX && x > bounds.minX { x = bounds.minX; y += row + spacing; row = 0 }
            s.place(at: CGPoint(x: x, y: y), proposal: .unspecified)
            x += size.width + spacing
            row = max(row, size.height)
        }
    }
}

/// Airtable's field editor for a select field: drag to reorder, colour,
/// rename, delete, add.
struct ManageOptionsView: View {
    struct Item: Identifiable, Equatable { let id: String; var name: String; var colorIndex: Int }

    let title: String
    let items: [Item]
    let onRename: (String, String) -> Void
    let onRecolor: (String, Int) -> Void
    let onDelete: (String) -> Void
    let onMove: (IndexSet, Int) -> Void
    let onAdd: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var newName = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(title).font(Theme.title).foregroundStyle(Theme.ink)
                Spacer()
                Button("Done") { dismiss() }.buttonStyle(FlatButtonStyle(primary: true)).keyboardShortcut(.defaultAction)
            }
            .padding(Theme.space3)
            List {
                ForEach(items) { item in
                    OptionRow(item: item, onRename: onRename, onRecolor: onRecolor, onDelete: onDelete)
                }
                .onMove(perform: onMove)
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .frame(minHeight: 220)
            HStack {
                TextField("New option", text: $newName).textFieldStyle(.roundedBorder).onSubmit(add)
                Button("Add option", action: add).buttonStyle(FlatButtonStyle())
            }
            .padding(Theme.space3)
            Text("Drag to reorder. Pills show in this order everywhere.")
                .font(Theme.caption).foregroundStyle(Theme.inkFaint)
                .padding([.horizontal, .bottom], Theme.space3)
        }
        .frame(width: 400, height: 460)
        .background(Theme.panel)
        .preferredColorScheme(.dark)
    }

    private func add() {
        let n = newName.trimmingCharacters(in: .whitespaces)
        guard !n.isEmpty else { return }
        onAdd(n)
        newName = ""
    }

    private struct OptionRow: View {
        let item: Item
        let onRename: (String, String) -> Void
        let onRecolor: (String, Int) -> Void
        let onDelete: (String) -> Void
        @State private var name = ""
        @State private var picking = false

        var body: some View {
            HStack(spacing: Theme.space2) {
                Image(systemName: "line.3.horizontal").foregroundStyle(Theme.inkFaint)
                Button { picking = true } label: {
                    Circle().fill(TagStore.palette[item.colorIndex % TagStore.palette.count]).frame(width: 14, height: 14)
                }
                .buttonStyle(.plain)
                .popover(isPresented: $picking) {
                    HStack(spacing: 6) {
                        ForEach(0..<TagStore.palette.count, id: \.self) { i in
                            Circle().fill(TagStore.palette[i]).frame(width: 18, height: 18)
                                .overlay(Circle().stroke(Theme.ink, lineWidth: i == item.colorIndex % TagStore.palette.count ? 2 : 0))
                                .onTapGesture { onRecolor(item.id, i); picking = false }
                                .help(TagStore.paletteNames[i])
                        }
                    }
                    .padding(Theme.space2)
                }
                TextField("Name", text: $name)
                    .textFieldStyle(.plain)
                    .onSubmit { onRename(item.id, name) }
                    .onAppear { name = item.name }
                    .onChange(of: item.name) { name = item.name }
                Pill(name: name.isEmpty ? item.name : name, color: TagStore.palette[item.colorIndex % TagStore.palette.count])
                Button { onDelete(item.id) } label: { Image(systemName: "trash").font(.system(size: 11)) }
                    .buttonStyle(.plain).foregroundStyle(Theme.inkMuted)
                    .help("Delete this option (removes it from every track)")
            }
            .padding(.vertical, 2)
        }
    }
}

/// "+" at the end of the header: name and type of a new field.
struct AddFieldView: View {
    let onCreate: (String, FieldType) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var type: FieldType = .singleSelect

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.space2) {
            TextField("Field name", text: $name).textFieldStyle(.roundedBorder).onSubmit(create)
            ForEach(FieldType.allCases) { t in
                HStack {
                    Image(systemName: t.icon).frame(width: 16)
                    Text(t.rawValue)
                    Spacer()
                    if t == type { Image(systemName: "checkmark").font(.system(size: 10)) }
                }
                .font(Theme.body)
                .foregroundStyle(t == type ? Theme.ink : Theme.inkMuted)
                .padding(.vertical, 3).padding(.horizontal, 4)
                .background(t == type ? Theme.control : Color.clear)
                .contentShape(Rectangle())
                .onTapGesture { type = t }
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.buttonStyle(FlatButtonStyle())
                Button("Create field", action: create).buttonStyle(FlatButtonStyle(primary: true))
            }
        }
        .padding(Theme.space3)
        .frame(width: 260)
        .background(Theme.panel)
    }

    private func create() {
        let n = name.trimmingCharacters(in: .whitespaces)
        onCreate(n.isEmpty ? type.rawValue : n, type)
        dismiss()
    }
}

/// Five stars; click one to set, click the same again to clear.
struct RatingView: View {
    let value: Int
    let onSet: (Int) -> Void
    var body: some View {
        HStack(spacing: 1) {
            ForEach(1...5, id: \.self) { i in
                Image(systemName: i <= value ? "star.fill" : "star")
                    .font(.system(size: 10))
                    .foregroundStyle(i <= value ? Color(hex: 0xe6c229) : Theme.inkFaint.opacity(0.5))
                    .onTapGesture { onSet(i == value ? 0 : i) }
            }
        }
    }
}

// MARK: Toolbar popovers

/// Airtable's Filter: conditions on any field, joined by and/or.
struct FilterView: View {
    @Binding var view: ViewSettings
    let context: RecordContext

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.space2) {
            Text(view.conditions.isEmpty ? "No filter conditions are applied" : "In this view, show tracks")
                .font(Theme.caption).foregroundStyle(Theme.inkMuted)
            ForEach(Array(view.conditions.enumerated()), id: \.element.id) { i, condition in
                row(i, condition)
            }
            Button {
                view.conditions.append(FilterCondition(field: .tags, op: .hasAny))
            } label: {
                Label("Add condition", systemImage: "plus").font(Theme.caption)
            }
            .buttonStyle(.plain)
            .foregroundStyle(Theme.ink)
        }
        .padding(Theme.space3)
        .frame(minWidth: 560, alignment: .leading)
        .background(Theme.panel)
    }

    private func binding(_ i: Int) -> Binding<FilterCondition> {
        Binding(get: { view.conditions[i] }, set: { view.conditions[i] = $0 })
    }

    @ViewBuilder
    private func row(_ i: Int, _ c: FilterCondition) -> some View {
        HStack(spacing: Theme.space2) {
            if i == 0 {
                Text("Where").font(Theme.caption).foregroundStyle(Theme.inkMuted).frame(width: 56, alignment: .leading)
            } else if i == 1 {
                Picker("", selection: $view.matchAll) {
                    Text("and").tag(true)
                    Text("or").tag(false)
                }
                .labelsHidden().frame(width: 56)
            } else {
                Text(view.matchAll ? "and" : "or").font(Theme.caption).foregroundStyle(Theme.inkMuted).frame(width: 56, alignment: .leading)
            }
            Picker("", selection: Binding(get: { c.field }, set: { f in
                var n = c
                n.field = f
                n.op = FilterOp.ops(for: context.kind(f)).first!
                n.options = []
                view.conditions[i] = n
            })) {
                ForEach(context.allFields, id: \.self) { f in Text(context.name(f)).tag(f) }
            }
            .labelsHidden().frame(width: 130)
            Picker("", selection: binding(i).op) {
                ForEach(FilterOp.ops(for: context.kind(c.field)), id: \.self) { Text($0.rawValue).tag($0) }
            }
            .labelsHidden().frame(width: 130)
            valueEditor(i, c)
            Spacer(minLength: 0)
            Button { view.conditions.remove(at: i) } label: { Image(systemName: "trash").font(.system(size: 11)) }
                .buttonStyle(.plain).foregroundStyle(Theme.inkMuted)
        }
        .font(Theme.caption)
    }

    @ViewBuilder
    private func valueEditor(_ i: Int, _ c: FilterCondition) -> some View {
        if c.op.needsText {
            TextField("Enter a value", text: binding(i).text).textFieldStyle(.roundedBorder).frame(width: 160)
        } else if c.op.needsNumber {
            TextField("Enter a number", value: binding(i).number, format: .number).textFieldStyle(.roundedBorder).frame(width: 100)
        } else if c.op.needsOptions {
            let options = context.options(c.field)
            Menu {
                ForEach(options) { o in
                    Button {
                        var n = c
                        if let k = n.options.firstIndex(of: o.id) { n.options.remove(at: k) } else { n.options.append(o.id) }
                        view.conditions[i] = n
                    } label: {
                        Label(o.name, systemImage: c.options.contains(o.id) ? "checkmark.circle.fill" : "circle")
                    }
                }
            } label: {
                HStack(spacing: 3) {
                    if c.options.isEmpty { Text("Select options").foregroundStyle(Theme.inkMuted) }
                    ForEach(options.filter { c.options.contains($0.id) }.prefix(3)) { Pill(name: $0.name, color: $0.color) }
                    if c.options.count > 3 { Text("+\(c.options.count - 3)") }
                }
            }
            .menuStyle(.borderlessButton)
            .frame(maxWidth: 220, alignment: .leading)
        }
    }
}

/// Airtable's Group: pick a field to group tracks by.
struct GroupView: View {
    @Binding var view: ViewSettings
    let context: RecordContext
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Group by").font(Theme.caption).foregroundStyle(Theme.inkMuted).padding(.bottom, 4)
            ForEach([FieldRef?.none] + context.allFields.filter { $0 != .name }.map(Optional.some), id: \.self) { f in
                HStack {
                    Text(f.map(context.name) ?? "None")
                    Spacer()
                    if view.groupBy == f { Image(systemName: "checkmark").font(.system(size: 10)) }
                }
                .font(Theme.body)
                .padding(.vertical, 3).padding(.horizontal, 4)
                .background(view.groupBy == f ? Theme.control : Color.clear)
                .contentShape(Rectangle())
                .onTapGesture { view.groupBy = f; view.collapsed = []; dismiss() }
            }
        }
        .padding(Theme.space3)
        .frame(width: 220)
        .background(Theme.panel)
    }
}

/// Airtable's Hide fields: switch fields on or off, drag ≡ to change the
/// column order. The track name always comes first.
struct HideFieldsView: View {
    @Binding var view: ViewSettings
    let context: RecordContext

    private var arranged: [FieldRef] { Array(context.orderedFields(view).dropFirst()) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Switch fields on or off. Drag ≡ to change the order.")
                .font(Theme.caption).foregroundStyle(Theme.inkMuted)
                .padding([.horizontal, .top], Theme.space3)
                .padding(.bottom, Theme.space1)
            List {
                ForEach(arranged, id: \.self) { f in
                    HStack(spacing: Theme.space2) {
                        Toggle("", isOn: Binding(get: { !view.hidden.contains(f) },
                                                 set: { if $0 { view.hidden.remove(f) } else { view.hidden.insert(f) } }))
                            .toggleStyle(.switch)
                            .controlSize(.mini)
                            .labelsHidden()
                        Text(context.name(f))
                            .font(Theme.body)
                            .foregroundStyle(view.hidden.contains(f) ? Theme.inkMuted : Theme.ink)
                        Spacer()
                        Image(systemName: "line.3.horizontal")
                            .foregroundStyle(Theme.inkFaint)
                            .help("Drag to move")
                    }
                    .padding(.vertical, 1)
                }
                .onMove { from, to in
                    var list = arranged
                    list.move(fromOffsets: from, toOffset: to)
                    view.fieldOrder = list
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .frame(height: min(CGFloat(arranged.count) * 26 + 12, 420))
            HStack(spacing: Theme.space3) {
                Button("Show all") { view.hidden = [] }
                Button("Hide all") { view.hidden = Set(arranged) }
                Spacer()
                Button("Reset order") { view.fieldOrder = nil }
                    .disabled(view.fieldOrder == nil)
            }
            .buttonStyle(.plain).font(Theme.caption).foregroundStyle(Theme.inkMuted)
            .padding(Theme.space3)
        }
        .frame(width: 260)
        .background(Theme.panel)
    }
}
