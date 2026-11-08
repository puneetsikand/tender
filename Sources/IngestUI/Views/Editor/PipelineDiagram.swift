import PhotoFerryCore
import SwiftUI

/// The workflow as a pipeline: card → routes (in match order) → destinations.
///
/// Connections are edited by dragging: drag from a route's port (the dot on its right edge)
/// onto a destination to copy that route's files there; drag onto a destination it already
/// copies to, to disconnect. Click a node to edit it.
struct PipelineDiagram: View {
    let draft: WorkflowDraft
    @State private var frames: [Node: CGRect] = [:]
    @State private var drag: (route: String, point: CGPoint)?

    enum Node: Hashable {
        case source, settings, route(String), destination(String), notCopied
    }

    static let space = "pipeline"

    var body: some View {
        HStack(alignment: .top, spacing: 52) {
            VStack(alignment: .leading, spacing: 16) {
                NodeBox(title: draft.previewSource?.title ?? "Card", subtitle: sourceSubtitle, icon: "sdcard", selected: false)
                    .frameTag(.source)
                NodeBox(title: "Settings", subtitle: settingsSubtitle, icon: "gearshape", selected: draft.selection == .settings)
                    .onTapGesture { draft.selection = .settings }
            }
            VStack(alignment: .leading, spacing: 12) {
                Text("Routes, first match wins").font(.caption).foregroundStyle(.secondary)
                ForEach(Array(draft.workflow.routes.enumerated()), id: \.element.id) { i, route in
                    NodeBox(title: "\(i + 1). \(route.name)", subtitle: routeSubtitle(route),
                            icon: route.skip ? "nosign" : "arrow.triangle.branch",
                            selected: draft.selection == .route(route.id),
                            badge: draft.preview.map { _ in "\(draft.count(forRoute: route.id))" })
                        .overlay(alignment: .trailing) { port(for: route) }
                        .frameTag(.route(route.id))
                        .onTapGesture { draft.selection = .route(route.id) }
                }
                Button { draft.addRoute() } label: { Label("Add Route", systemImage: "plus") }
                    .buttonStyle(.borderless)
            }
            VStack(alignment: .leading, spacing: 12) {
                Text("Copy to").font(.caption).foregroundStyle(.secondary)
                ForEach(draft.workflow.destinations) { d in
                    NodeBox(title: d.name, subtitle: d.root.isEmpty ? "No folder chosen" : d.root, icon: "externaldrive",
                            selected: draft.selection == .destination(d.id), dropTarget: dropTarget == .destination(d.id))
                        .frameTag(.destination(d.id))
                        .onTapGesture { draft.selection = .destination(d.id) }
                }
                if draft.workflow.routes.contains(where: \.skip) {
                    NodeBox(title: "Not copied", subtitle: "Skipped; stays on the card", icon: "nosign", selected: false, dimmed: true)
                        .frameTag(.notCopied)
                }
                Button { draft.addDestination() } label: { Label("Add Destination", systemImage: "plus") }
                    .buttonStyle(.borderless)
                Text("Drag from a route's dot to a destination to connect or disconnect it.")
                    .font(.caption).foregroundStyle(.secondary).frame(width: 205, alignment: .leading)
            }
        }
        .padding(24)
        .coordinateSpace(name: Self.space)
        .onPreferenceChange(NodeFrames.self) { new in frames = new }
        .background {
            ZStack {
                ForEach(edges, id: \.self) { edge in
                    if let a = frames[edge.from], let b = frames[edge.to] {
                        Connector(from: a, to: b)
                            .stroke(edge.highlighted ? Color.accentColor : Color.secondary.opacity(0.45),
                                    style: StrokeStyle(lineWidth: edge.highlighted ? 2.5 : 1.5, dash: edge.dashed ? [5, 4] : []))
                    }
                }
                if let drag, let a = frames[.route(drag.route)] {
                    Connector(from: a, to: CGRect(origin: drag.point, size: .zero))
                        .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 2.5, dash: [6, 4]))
                }
            }
        }
    }

    /// The draggable output port on a route's right edge.
    @ViewBuilder private func port(for route: Workflow.Route) -> some View {
        if !route.skip {
            Circle()
                .fill(draft.selection == .route(route.id) || drag?.route == route.id ? Color.accentColor : Color.secondary)
                .frame(width: 12, height: 12)
                .overlay(Circle().stroke(.background, lineWidth: 2))
                .offset(x: 6)
                .contentShape(Circle().inset(by: -8))
                .help("Drag to a destination to connect or disconnect")
                .gesture(
                    DragGesture(minimumDistance: 2, coordinateSpace: .named(Self.space))
                        .onChanged { v in
                            drag = (route.id, v.location)
                            draft.selection = .route(route.id)
                        }
                        .onEnded { v in
                            if case .destination(let id)? = target(at: v.location) { toggle(route: route.id, destination: id) }
                            drag = nil
                        })
        }
    }

    private var dropTarget: Node? {
        drag.flatMap { target(at: $0.point) }
    }

    private func target(at point: CGPoint) -> Node? {
        frames.first { node, rect in
            if case .destination = node { rect.insetBy(dx: -6, dy: -6).contains(point) } else { false }
        }?.key
    }

    private func toggle(route: String, destination: String) {
        draft.updateRoute(route) { r in
            if r.destinations.contains(destination) { r.destinations.removeAll { $0 == destination } }
            else { r.destinations.append(destination) }
        }
    }

    struct Edge: Hashable {
        let from: Node
        let to: Node
        var highlighted = false
        var dashed = false
    }

    private var edges: [Edge] {
        var out: [Edge] = []
        for r in draft.workflow.routes {
            let hot = draft.selection == .route(r.id)
            out.append(Edge(from: .source, to: .route(r.id), highlighted: hot))
            if r.skip {
                out.append(Edge(from: .route(r.id), to: .notCopied, highlighted: hot, dashed: true))
            } else {
                for d in r.destinations {
                    out.append(Edge(from: .route(r.id), to: .destination(d), highlighted: hot || draft.selection == .destination(d)))
                }
            }
        }
        return out
    }

    private var sourceSubtitle: String {
        guard let card = draft.previewSource else { return "Insert a card to preview" }
        return "\(card.files.count) files · never modified"
    }

    private var settingsSubtitle: String {
        "verify \(draft.workflow.verify.rawValue) · \(draft.workflow.timeZone ?? "Mac's time zone")"
    }

    private func routeSubtitle(_ r: Workflow.Route) -> String {
        let what = WorkflowDescriber.matchText(r.match)
        if r.skip { return "\(what) · not copied" }
        let n = r.destinations.count
        return "\(what) → \(r.folder)/\(r.fileName)" + (n > 1 ? " · \(n) destinations" : "")
    }
}

struct NodeFrames: PreferenceKey {
    static let defaultValue: [PipelineDiagram.Node: CGRect] = [:]
    static func reduce(value: inout [PipelineDiagram.Node: CGRect], nextValue: () -> [PipelineDiagram.Node: CGRect]) {
        value.merge(nextValue()) { $1 }
    }
}

extension View {
    /// Reports this view's frame in the pipeline's coordinate space.
    func frameTag(_ node: PipelineDiagram.Node) -> some View {
        background(GeometryReader { g in
            Color.clear.preference(key: NodeFrames.self, value: [node: g.frame(in: .named(PipelineDiagram.space))])
        })
    }
}

/// A horizontal S-curve from the right edge of one node to the left edge of another.
struct Connector: Shape {
    let from: CGRect
    let to: CGRect

    func path(in _: CGRect) -> Path {
        let a = CGPoint(x: from.maxX, y: from.midY)
        let b = CGPoint(x: to.minX, y: to.midY)
        let dx = max(24, abs(b.x - a.x) / 2)
        var p = Path()
        p.move(to: a)
        p.addCurve(to: b, control1: CGPoint(x: a.x + dx, y: a.y), control2: CGPoint(x: b.x - dx, y: b.y))
        return p
    }
}

struct NodeBox: View {
    let title: String
    let subtitle: String
    let icon: String
    let selected: Bool
    var badge: String? = nil
    var dimmed = false
    var dropTarget = false

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: icon).foregroundStyle(selected ? Color.accentColor : .secondary).frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline).lineLimit(1)
                Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
            Spacer(minLength: 0)
            if let badge {
                Text(badge).font(.caption.monospacedDigit()).padding(.horizontal, 6).padding(.vertical, 2)
                    .background(.quaternary, in: Capsule())
                    .help("Files on the inserted card this route copies")
            }
        }
        .padding(10)
        .frame(width: 205, alignment: .leading)
        .background(dropTarget ? AnyShapeStyle(Color.accentColor.opacity(0.15)) : AnyShapeStyle(.background),
                    in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10)
            .strokeBorder(selected || dropTarget ? Color.accentColor : Color.secondary.opacity(0.3), lineWidth: selected || dropTarget ? 2 : 1))
        .opacity(dimmed ? 0.6 : 1)
        .contentShape(RoundedRectangle(cornerRadius: 10))
    }
}
