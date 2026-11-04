import UIKit

/// One commit's place in the graph: its column, the columns with a line
/// entering and leaving the row, its own parent edges, and whether it is a
/// merge.
struct GitGraphRow: Equatable {
    let lane: Int
    let edges: [GitGraphEdge]
    let top: [Int]
    let bottom: [Int]
    let isMerge: Bool
}

struct GitGraphEdge: Equatable {
    let fromLane: Int
    let toLane: Int
    /// The column whose colour the line takes: the child's for a first-parent
    /// line, the parent's for a merge line, so a branch keeps its colour as
    /// it joins.
    let lane: Int
    /// True for a merge parent's line, which is drawn bottom to centre.
    let isMergeIn: Bool
}

/// The lanes and edges of a whole loaded history, computed once for the list.
///
/// A row cannot be laid out alone: its column depends on every newer commit
/// that reserved one, and the merge-parent heuristic looks an occupant up in
/// the whole list. The tab builds this once per page and hands each cell its
/// own `GitGraphRow`.
struct GitGraphLayout: Equatable {
    let rows: [GitGraphRow]
    let maxLane: Int

    static let empty = GitGraphLayout(rows: [], maxLane: 0)

    init(commits: [GitCommit]) {
        // The reuse heuristic asks an occupant whether this merge parent is
        // one of its own parents, so every commit has to be readable before
        // the walk starts.
        var commitMap: [String: GitCommit] = [:]
        for commit in commits {
            commitMap[commit.id] = commit
        }

        var active: [String?] = []
        var rows: [GitGraphRow] = []
        rows.reserveCapacity(commits.count)
        var maxLane = 0

        func liveColumns() -> [Int] {
            active.indices.filter { active[$0] != nil }
        }

        for commit in commits {
            // 1. Occupy a column: the one a child reserved for this commit,
            // else the left-most free one, else a new one at the end.
            var lane = active.firstIndex(of: commit.id) ?? -1
            if lane < 0 {
                if let free = active.firstIndex(where: { $0 == nil }) {
                    lane = free
                    active[free] = commit.id
                } else {
                    lane = active.count
                    active.append(commit.id)
                }
            }
            maxLane = max(maxLane, lane)

            // 2. Above the node, every live column has a line entering.
            let top = liveColumns()

            // 3. A root releases its column and has nothing to draw below.
            guard let firstParent = commit.parents.first else {
                active[lane] = nil
                rows.append(GitGraphRow(
                    lane: lane, edges: [], top: top, bottom: liveColumns(),
                    isMerge: commit.parents.count > 1
                ))
                continue
            }

            var edges: [GitGraphEdge] = []

            // 4. The first parent continues this column, or this line bends
            // to the column that parent already sits in.
            let firstParentLane = active.firstIndex(of: firstParent) ?? -1
            if firstParentLane >= 0, firstParentLane != lane {
                edges.append(GitGraphEdge(
                    fromLane: lane, toLane: firstParentLane, lane: lane, isMergeIn: false
                ))
                active[lane] = nil
            } else {
                edges.append(GitGraphEdge(fromLane: lane, toLane: lane, lane: lane, isMergeIn: false))
                active[lane] = firstParent
            }

            // 5. Every further parent of a merge gets a column: its own if it
            // has one, else the column of an occupant that will walk into it,
            // else the left-most free one, else a new one.
            for parent in commit.parents.dropFirst() {
                let parentLane: Int
                if let existing = active.firstIndex(of: parent) {
                    parentLane = existing
                } else if let reuse = active.firstIndex(where: { occupant in
                    guard let occupant else { return false }
                    guard active.firstIndex(of: occupant) != lane else { return false }
                    return commitMap[occupant]?.parents.contains(parent) == true
                }) {
                    parentLane = reuse
                } else if let free = active.firstIndex(where: { $0 == nil }) {
                    active[free] = parent
                    parentLane = free
                } else {
                    active.append(parent)
                    parentLane = active.count - 1
                }
                maxLane = max(maxLane, parentLane)
                edges.append(GitGraphEdge(
                    fromLane: lane, toLane: parentLane, lane: parentLane, isMergeIn: true
                ))
            }

            // 6. Below the node, the columns still held have a line leaving.
            rows.append(GitGraphRow(
                lane: lane, edges: edges, top: top, bottom: liveColumns(),
                isMerge: commit.parents.count > 1
            ))
        }

        self.init(rows: rows, maxLane: maxLane)
    }

    private init(rows: [GitGraphRow], maxLane: Int) {
        self.rows = rows
        self.maxLane = maxLane
    }
}

/// One row of the commit graph, drawn with the three passes the reference
/// app uses: the verticals, then the curves that change column, then the node
/// on top.
///
/// A view is one row tall. Its height changes with the row's content, so the
/// centre and every y coordinate are read from `bounds` during `draw(_:)` and
/// nothing is cached in points.
final class GitGraphView: UIView {
    /// The reference app's eight colours, chosen to read on both grounds.
    private static let palette: [UIColor] = [
        UIColor(hex: 0x2563EB),
        UIColor(hex: 0x16A34A),
        UIColor(hex: 0xF59E0B),
        UIColor(hex: 0x8B5CF6),
        UIColor(hex: 0x06B6D4),
        UIColor(hex: 0xEF4444),
        UIColor(hex: 0xEC4899),
        UIColor(hex: 0xEAB308)
    ]

    /// A lane's colour, cycled through the eight. The hash pill in the row
    /// uses this too, so the pill and the line agree.
    static func color(forLane lane: Int) -> UIColor {
        palette[((lane % palette.count) + palette.count) % palette.count]
    }

    /// Ten points when the history is a single line, so the text gets the
    /// room the graph does not need; sixteen otherwise.
    static func laneWidth(for maxLane: Int) -> CGFloat {
        maxLane == 0 ? 10 : 16
    }

    static func canvasWidth(maxLane: Int, laneWidth: CGFloat) -> CGFloat {
        laneWidth * CGFloat(maxLane + 1) + 8
    }

    private(set) var canvasWidth: CGFloat = 0

    /// The colour drawn inside a merge commit's ring, so the lines passing
    /// through it do not show in the hole. The cell sets it to its own card
    /// colour.
    var nodeFillColor: UIColor = .secondarySystemBackground {
        didSet { setNeedsDisplay() }
    }

    private var row: GitGraphRow?
    private var laneWidth: CGFloat = 0
    private var maxLane = 0
    private var suppressesTop = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        isOpaque = false
        backgroundColor = .clear
        isUserInteractionEnabled = false
        contentMode = .redraw
        // The row's own label carries the commit; the picture repeats none of
        // it.
        isAccessibilityElement = false
        accessibilityElementsHidden = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// Draws the row for the commit at `index` of a layout the list built
    /// once. This is what the commits tab uses.
    func configure(layout: GitGraphLayout, index: Int, laneWidth: CGFloat) {
        guard layout.rows.indices.contains(index) else {
            row = nil
            canvasWidth = 0
            setNeedsDisplay()
            return
        }
        row = layout.rows[index]
        self.laneWidth = laneWidth
        maxLane = layout.maxLane
        suppressesTop = index == 0
        canvasWidth = Self.canvasWidth(maxLane: layout.maxLane, laneWidth: laneWidth)
        setNeedsDisplay()
    }

    /// Draws the last commit of `commits` as one row.
    ///
    /// The slice reaching the row is enough to know that row's column, except
    /// for a merge whose reuse heuristic needs a commit older than the slice.
    /// The commits tab therefore passes its whole layout to
    /// `configure(layout:index:laneWidth:)` instead of calling this per row.
    func configure(commits: [GitCommit], laneWidth: CGFloat) {
        guard !commits.isEmpty else {
            row = nil
            canvasWidth = 0
            setNeedsDisplay()
            return
        }
        let layout = GitGraphLayout(commits: commits)
        configure(layout: layout, index: layout.rows.count - 1, laneWidth: laneWidth)
        // A lone row is the newest one it knows about, so no line dangles
        // above it.
        suppressesTop = commits.count == 1
    }

    override func draw(_ rect: CGRect) {
        guard let row, laneWidth > 0, bounds.height > 0,
              let context = UIGraphicsGetCurrentContext()
        else { return }

        let height = bounds.height
        let centreY = height / 2
        let top = Set(row.top)
        let bottom = Set(row.bottom)
        // A column whose lower half a curve takes over loses its straight
        // vertical, unless a through-line already occupies the upper half:
        // then the trunk keeps its line and the curve is drawn over it.
        let curveTargets = Set(row.edges.filter { $0.fromLane != $0.toLane }.map(\.toLane))
            .subtracting(top)
        let columns = Set(row.top).union(row.bottom).union([row.lane]).sorted()

        context.setLineWidth(2.5)
        context.setLineCap(.round)
        context.setLineJoin(.round)

        // Pass 1: the straight segments, each column separately.
        for column in columns {
            let inTop = top.contains(column)
            let inBottom = bottom.contains(column) && !curveTargets.contains(column)
            guard inTop || inBottom else { continue }
            context.setStrokeColor(Self.color(forLane: column).cgColor)
            context.beginPath()
            if inTop, inBottom {
                let start = suppressesTop ? centreY : 0
                context.move(to: CGPoint(x: centreX(column), y: start))
                context.addLine(to: CGPoint(x: centreX(column), y: height))
            } else if inTop {
                if !suppressesTop {
                    context.move(to: CGPoint(x: centreX(column), y: 0))
                    context.addLine(to: CGPoint(x: centreX(column), y: centreY))
                }
            } else {
                context.move(to: CGPoint(x: centreX(column), y: centreY))
                context.addLine(to: CGPoint(x: centreX(column), y: height))
            }
            context.strokePath()
        }

        // Pass 2: a line that changes column, bowed through the row's lower
        // half.
        let midY = centreY + (height - centreY) / 2
        for edge in row.edges where edge.fromLane != edge.toLane {
            context.setStrokeColor(Self.color(forLane: edge.lane).cgColor)
            context.beginPath()
            if edge.isMergeIn {
                context.move(to: CGPoint(x: centreX(edge.toLane), y: height))
                context.addCurve(
                    to: CGPoint(x: centreX(edge.fromLane), y: centreY),
                    control1: CGPoint(x: centreX(edge.toLane), y: midY),
                    control2: CGPoint(x: centreX(edge.fromLane), y: midY)
                )
            } else {
                context.move(to: CGPoint(x: centreX(edge.fromLane), y: centreY))
                context.addCurve(
                    to: CGPoint(x: centreX(edge.toLane), y: height),
                    control1: CGPoint(x: centreX(edge.fromLane), y: midY),
                    control2: CGPoint(x: centreX(edge.toLane), y: midY)
                )
            }
            context.strokePath()
        }

        // Pass 3: the commit itself. A merge is a ring with a small core, so
        // it stays recognisable even when two lines meet on it.
        let centre = CGPoint(x: centreX(row.lane), y: centreY)
        let color = Self.color(forLane: row.lane)
        if row.isMerge {
            let ring = CGRect(x: centre.x - 7, y: centre.y - 7, width: 14, height: 14)
            context.setFillColor(nodeFillColor.cgColor)
            context.fillEllipse(in: ring)
            context.setStrokeColor(color.cgColor)
            context.setLineWidth(2.5)
            context.strokeEllipse(in: ring)
            context.setFillColor(color.cgColor)
            context.fillEllipse(in: CGRect(x: centre.x - 3.5, y: centre.y - 3.5, width: 7, height: 7))
        } else {
            context.setFillColor(color.cgColor)
            context.fillEllipse(in: CGRect(x: centre.x - 5, y: centre.y - 5, width: 10, height: 10))
        }
    }

    private func centreX(_ lane: Int) -> CGFloat {
        CGFloat(lane) * laneWidth + laneWidth / 2 + 4
    }
}
