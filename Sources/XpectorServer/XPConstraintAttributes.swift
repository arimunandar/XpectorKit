import UIKit
import XpectorKit

enum XPConstraintAttributes {
    static func group(for view: UIView) -> XPAttributeGroup {
        let horizontal = view.constraintsAffectingLayout(for: .horizontal)
        let vertical = view.constraintsAffectingLayout(for: .vertical)
        let listed = Set((horizontal + vertical).map(ObjectIdentifier.init))
        let others = view.constraints.filter { !listed.contains(ObjectIdentifier($0)) }

        var sections: [XPAttributeSection] = [
            XPAttributeSection(id: "constraints.flags", title: "", attributes: flagAttributes(view)),
        ]
        if !horizontal.isEmpty {
            sections.append(section(id: "constraints.horizontal", title: "Horizontal",
                                    constraints: horizontal, view: view))
        }
        if !vertical.isEmpty {
            sections.append(section(id: "constraints.vertical", title: "Vertical",
                                    constraints: vertical, view: view))
        }
        if !others.isEmpty {
            sections.append(section(id: "constraints.other", title: "Other",
                                    constraints: others, view: view))
        }
        return XPAttributeGroup(id: "constraints", title: "Constraints", sections: sections)
    }

    // MARK: - Sections

    private static func flagAttributes(_ view: UIView) -> [XPAttribute] {
        [
            .init(id: "constraints.translatesAutoresizingMask", title: "Autoresizing Mask", type: .bool,
                  value: .bool(view.translatesAutoresizingMaskIntoConstraints), isEditable: false),
            .init(id: "constraints.hasAmbiguousLayout", title: "Ambiguous Layout", type: .bool,
                  value: .bool(view.hasAmbiguousLayout), isEditable: false),
        ]
    }

    private static func section(id: String, title: String,
                                constraints: [NSLayoutConstraint], view: UIView) -> XPAttributeSection
    {
        let attrs = constraints.enumerated().map { index, constraint in
            XPAttribute(id: "\(id).\(index)", title: rowTitle(constraint, view: view), type: .string,
                        value: .string(describe(constraint, relativeTo: view)), isEditable: false)
        }
        return XPAttributeSection(id: id, title: title, attributes: attrs)
    }

    private static func rowTitle(_ constraint: NSLayoutConstraint, view: UIView) -> String {
        if constraint.firstItem === view {
            return attributeName(constraint.firstAttribute)
        }
        if constraint.secondItem === view {
            return attributeName(constraint.secondAttribute)
        }
        return attributeName(constraint.firstAttribute)
    }

    // MARK: - Formatting

    private static func describe(_ constraint: NSLayoutConstraint, relativeTo view: UIView) -> String {
        let lhs = "\(itemName(constraint.firstItem, relativeTo: view)).\(attributeName(constraint.firstAttribute))"
        var result = "\(lhs) \(relationSymbol(constraint.relation)) \(rightHandSide(constraint, relativeTo: view))"
        if constraint.priority != .required {
            result += " @\(Int(constraint.priority.rawValue))"
        }
        if !constraint.identifier.isNilOrEmpty {
            result += " '\(constraint.identifier ?? "")'"
        }
        if !constraint.isActive {
            result += " (inactive)"
        }
        return result
    }

    private static func rightHandSide(_ constraint: NSLayoutConstraint, relativeTo view: UIView) -> String {
        guard let secondItem = constraint.secondItem else {
            return format(constraint.constant)
        }

        var rhs = "\(itemName(secondItem, relativeTo: view)).\(attributeName(constraint.secondAttribute))"
        if constraint.multiplier != 1 {
            rhs += " × \(format(constraint.multiplier))"
        }
        if constraint.constant > 0 {
            rhs += " + \(format(constraint.constant))"
        } else if constraint.constant < 0 {
            rhs += " − \(format(-constraint.constant))"
        }
        return rhs
    }

    private static func itemName(_ item: AnyObject?, relativeTo view: UIView) -> String {
        guard let item else { return "nil" }

        if let guide = item as? UILayoutGuide {
            let owner = guide.owningView.map { viewName($0, relativeTo: view) } ?? "?"
            return "\(owner).\(guideName(guide))"
        }
        if let itemView = item as? UIView {
            return viewName(itemView, relativeTo: view)
        }
        return String(describing: type(of: item))
    }

    private static func viewName(_ itemView: UIView, relativeTo view: UIView) -> String {
        if itemView === view {
            return "self"
        }
        if itemView === view.superview {
            return "superview"
        }
        let className = String(describing: type(of: itemView))
        if let identifier = itemView.accessibilityIdentifier, !identifier.isEmpty {
            return "\(className)#\(identifier)"
        }
        return className
    }

    private static func guideName(_ guide: UILayoutGuide) -> String {
        let identifier = guide.identifier
        if identifier.contains("SafeArea") {
            return "safeArea"
        }
        if identifier.contains("Margins") {
            return "margins"
        }
        if identifier.contains("Keyboard") {
            return "keyboard"
        }
        if identifier.contains("ReadableContent") {
            return "readable"
        }
        return identifier.isEmpty ? "layoutGuide" : identifier
    }

    private static func attributeName(_ attribute: NSLayoutConstraint.Attribute) -> String {
        switch attribute {
        case .left: return "left"
        case .right: return "right"
        case .top: return "top"
        case .bottom: return "bottom"
        case .leading: return "leading"
        case .trailing: return "trailing"
        case .width: return "width"
        case .height: return "height"
        case .centerX: return "centerX"
        case .centerY: return "centerY"
        case .lastBaseline: return "lastBaseline"
        case .firstBaseline: return "firstBaseline"
        case .leftMargin: return "leftMargin"
        case .rightMargin: return "rightMargin"
        case .topMargin: return "topMargin"
        case .bottomMargin: return "bottomMargin"
        case .leadingMargin: return "leadingMargin"
        case .trailingMargin: return "trailingMargin"
        case .centerXWithinMargins: return "centerXWithinMargins"
        case .centerYWithinMargins: return "centerYWithinMargins"
        case .notAnAttribute: return "notAnAttribute"
        @unknown default: return "attribute\(attribute.rawValue)"
        }
    }

    private static func relationSymbol(_ relation: NSLayoutConstraint.Relation) -> String {
        switch relation {
        case .lessThanOrEqual: return "≤"
        case .equal: return "=="
        case .greaterThanOrEqual: return "≥"
        @unknown default: return "?"
        }
    }

    private static func format(_ value: CGFloat) -> String {
        value == value.rounded() ? String(Int(value)) : String(format: "%.1f", value)
    }
}

private extension String? {
    var isNilOrEmpty: Bool {
        self?.isEmpty ?? true
    }
}
