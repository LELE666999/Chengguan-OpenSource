import AppKit
import SwiftUI

/// Native outline rows provide the same selection, disclosure and keyboard behavior as macOS tables.
struct ProcessOutline: NSViewRepresentable {
  @ObservedObject var model: MonitorModel
  func makeCoordinator() -> Coordinator { Coordinator(model: model) }
  func makeNSView(context: Context) -> NSScrollView {
    let scroll = NSScrollView()
    scroll.hasVerticalScroller = true
    scroll.hasHorizontalScroller = false
    scroll.drawsBackground = false
    let table = NSOutlineView()
    table.delegate = context.coordinator
    table.dataSource = context.coordinator
    table.headerView = NSTableHeaderView()
    table.rowHeight = 26
    table.intercellSpacing = .zero
    table.usesAlternatingRowBackgroundColors = true
    table.backgroundColor = .clear
    table.allowsMultipleSelection = false
    table.allowsEmptySelection = true
    table.selectionHighlightStyle = .regular
    table.indentationPerLevel = 14
    table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
    table.autoresizesOutlineColumn = false
    scroll.documentView = table
    context.coordinator.table = table
    context.coordinator.update(model)
    return scroll
  }
  func updateNSView(_ view: NSScrollView, context: Context) { context.coordinator.update(model) }
  final class Node: NSObject {
    var group: AppGroup
    var process: ProcessSample?
    var children: [Node] = []
    var identity: String { process?.identity ?? group.id }
    init(group: AppGroup, process: ProcessSample? = nil) {
      self.group = group
      self.process = process
    }
  }
  final class Coordinator: NSObject, NSOutlineViewDataSource, NSOutlineViewDelegate {
    var model: MonitorModel
    weak var table: NSOutlineView?
    var roots: [Node] = []
    var cache: [String: Node] = [:]
    var columns: [String] = []
    var reloading = false
    init(model: MonitorModel) { self.model = model }
    private var desiredColumns: [String] {
      let extras: [String]
      switch model.tab {
      case .disk: extras = ["写入", "读取"]
      case .network: extras = ["下载", "上传"]
      case .gpu: extras = ["GPU"]
      case .battery: extras = ["唤醒/s"]
      default: extras = []
      }
      return ["名称"] + extras + ["CPU", "内存", "进程"]
    }
    func update(_ model: MonitorModel) {
      self.model = model
      guard let table else { return }
      reloading = true
      defer { reloading = false }
      if columns != desiredColumns {
        columns = desiredColumns
        for c in table.tableColumns { table.removeTableColumn(c) }
        let total = max(1100, table.enclosingScrollView?.contentSize.width ?? 1100)
        for name in columns {
          let c = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(name))
          c.title = name
          let ratio: CGFloat =
            name == "名称"
            ? 0.37
            : (columns.count == 4
              ? (name == "CPU" ? 0.24 : 0.195) : 0.63 / CGFloat(columns.count - 1))
          c.width = total * ratio
          c.minWidth = name == "名称" ? 160 : 85
          c.resizingMask = .autoresizingMask
          table.addTableColumn(c)
        }
        table.outlineTableColumn = table.tableColumns.first
      }
      let groups = model.sortedGroups()
      var next: [String: Node] = [:]
      roots = groups.map { group in
        let node = cache[group.id] ?? Node(group: group)
        node.group = group
        node.children = group.processes.map { p in
          let child = cache[p.identity] ?? Node(group: group, process: p)
          child.group = group
          child.process = p
          next[p.identity] = child
          return child
        }
        next[group.id] = node
        return node
      }
      cache = next
      let origin = table.enclosingScrollView?.contentView.bounds.origin ?? .zero
      table.rowHeight = UserDefaults.standard.bool(forKey: "compact") ? 22 : 26
      table.reloadData()
      for root in roots where model.expanded.contains(root.group.id) { table.expandItem(root) }
      if let id = model.selection, let node = cache[id] {
        let row = table.row(forItem: node)
        if row >= 0 { table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false) }
      } else {
        table.deselectAll(nil)
      }
      table.enclosingScrollView?.contentView.scroll(to: origin)
      for column in table.tableColumns {
        table.setIndicatorImage(
          column.identifier.rawValue == model.sortColumn
            ? NSImage(
              systemSymbolName: model.ascending ? "chevron.up" : "chevron.down",
              accessibilityDescription: nil) : nil, in: column)
      }
    }
    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
      (item as? Node)?.children.count ?? roots.count
    }
    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
      if let node = item as? Node { return node.children[index] }
      return roots[index]
    }
    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
      (item as? Node)?.process == nil
    }
    func outlineView(
      _ outlineView: NSOutlineView, objectValueFor tableColumn: NSTableColumn?, byItem item: Any?
    ) -> Any? { (item as? Node)?.process?.name ?? (item as? Node)?.group.name }
    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any)
      -> NSView?
    {
      guard let node = item as? Node, let column = tableColumn else { return nil }
      let identifier = column.identifier
      let cell =
        (outlineView.makeView(withIdentifier: identifier, owner: self) as? NSHostingView<AnyView>)
        ?? NSHostingView(rootView: AnyView(EmptyView()))
      cell.identifier = identifier
      cell.rootView = AnyView(cellContent(node, column: identifier.rawValue))
      return cell
    }
    @ViewBuilder private func cellContent(_ node: Node, column: String) -> some View {
      if column == "名称" {
        HStack(spacing: 8) {
          if node.process == nil { AppIcon(path: node.group.bundlePath, size: 18) }
          Text(node.process?.name ?? node.group.name).font(.system(size: 13)).foregroundStyle(
            node.process == nil ? .primary : .secondary
          ).lineLimit(1)
          Spacer(minLength: 0)
        }.padding(.leading, 2)
      } else {
        HStack(spacing: 10) {
          Spacer(minLength: 0)
          if column == "CPU", model.tab == .cpu {
            GaugeBar(
              value: (node.process?.cpu ?? node.group.cpu)
                / max(100, model.snapshot.groups.map(\.cpu).max() ?? 100), color: Theme.accent
            ).frame(width: 44)
          }
          Text(value(node, column: column)).font(Theme.number(13, .regular)).monospacedDigit()
            .foregroundStyle(column == "进程" ? .secondary : .primary).lineLimit(1)
        }.padding(.trailing, 6)
      }
    }
    private func value(_ node: Node, column: String) -> String {
      let g = node.group
      let p = node.process
      let measured = p?.measured ?? (g.measuredCount > 0)
      switch column {
      case "CPU": return measured ? Format.appCPU(p?.cpu ?? g.cpu) : "—"
      case "内存": return measured ? Format.memory(p?.memory ?? g.memory) : "—"
      case "进程": return p.map { String($0.pid) } ?? String(g.processes.count)
      case "读取": return measured ? Format.rate(p?.readRate ?? g.readRate) : "—"
      case "写入": return measured ? Format.rate(p?.writeRate ?? g.writeRate) : "—"
      case "下载": return Format.networkRate(p?.networkIn ?? g.networkIn)
      case "上传": return Format.networkRate(p?.networkOut ?? g.networkOut)
      case "唤醒/s":
        return measured
          ? String(format: "%.0f", p?.wakeups ?? g.processes.reduce(0) { $0 + $1.wakeups }) : "—"
      default: return "—"
      }
    }
    func outlineViewSelectionDidChange(_ notification: Notification) {
      guard !reloading, let table, let node = table.item(atRow: table.selectedRow) as? Node else {
        return
      }
      model.selection = node.group.id
    }
    func outlineViewItemDidExpand(_ notification: Notification) {
      guard !reloading, let node = notification.userInfo?["NSObject"] as? Node else { return }
      model.expanded.insert(node.group.id)
    }
    func outlineViewItemDidCollapse(_ notification: Notification) {
      guard !reloading, let node = notification.userInfo?["NSObject"] as? Node else { return }
      model.expanded.remove(node.group.id)
    }
    func outlineView(_ outlineView: NSOutlineView, didClick tableColumn: NSTableColumn) {
      model.sort(tableColumn.identifier.rawValue)
    }
  }
}
