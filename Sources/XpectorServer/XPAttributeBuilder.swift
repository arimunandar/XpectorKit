import UIKit
import XpectorKit

enum XPAttributeBuilder {
    static func build(for view: UIView) -> [XPAttributeGroup] {
        var groups = [
            layoutGroup(view),
            XPConstraintAttributes.group(for: view),
            viewLayerGroup(view),
            accessibilityGroup(view),
        ]
        groups.append(contentsOf: textGroups(for: view))
        groups.append(contentsOf: controlGroups(for: view))
        groups.append(contentsOf: containerGroups(for: view))
        return groups
    }

    // MARK: - Accessibility

    private static func accessibilityGroup(_ view: UIView) -> XPAttributeGroup {
        var attrs: [XPAttribute] = [
            .init(id: "a11y.isElement", title: "Is Accessibility Element", type: .bool,
                  value: .bool(view.isAccessibilityElement), isEditable: true),
        ]
        if let label = view.accessibilityLabel {
            attrs.append(.init(id: "a11y.label", title: "Label", type: .string,
                               value: .string(label), isEditable: true))
        }
        if let value = view.accessibilityValue {
            attrs.append(.init(id: "a11y.value", title: "Value", type: .string,
                               value: .string(value), isEditable: true))
        }
        if let hint = view.accessibilityHint {
            attrs.append(.init(id: "a11y.hint", title: "Hint", type: .string,
                               value: .string(hint), isEditable: true))
        }
        if let identifier = view.accessibilityIdentifier {
            attrs.append(.init(id: "a11y.identifier", title: "Identifier", type: .string,
                               value: .string(identifier), isEditable: true))
        }
        return XPAttributeGroup(id: "accessibility", title: "Accessibility",
                                sections: [XPAttributeSection(id: "a11y.main", title: "", attributes: attrs)])
    }

    // MARK: - Layout

    private static func layoutGroup(_ view: UIView) -> XPAttributeGroup {
        var attrs = geometryAttributes(view)
        let intrinsic = view.intrinsicContentSize
        if intrinsic.width != UIView.noIntrinsicMetric || intrinsic.height != UIView.noIntrinsicMetric {
            attrs.append(.init(id: "layout.intrinsicContentSize", title: "Intrinsic Size", type: .size,
                               value: .size(w: Double(intrinsic.width), h: Double(intrinsic.height)),
                               isEditable: false))
        }
        attrs.append(contentsOf: priorityAttributes(view))
        return XPAttributeGroup(id: "layout", title: "Layout",
                                sections: [XPAttributeSection(id: "layout.main", title: "", attributes: attrs)])
    }

    private static func geometryAttributes(_ view: UIView) -> [XPAttribute] {
        let frame = view.frame
        let bounds = view.bounds
        let safeArea = view.safeAreaInsets
        let anchor = view.layer.anchorPoint
        let position = view.layer.position
        return [
            .init(id: "layout.frame", title: "Frame", type: .rect,
                  value: .rect(x: Double(frame.origin.x), y: Double(frame.origin.y),
                               w: Double(frame.size.width), h: Double(frame.size.height)),
                  isEditable: true),
            .init(id: "layout.bounds", title: "Bounds", type: .rect,
                  value: .rect(x: Double(bounds.origin.x), y: Double(bounds.origin.y),
                               w: Double(bounds.size.width), h: Double(bounds.size.height)),
                  isEditable: true),
            .init(id: "layout.safeAreaInsets", title: "Safe Area Insets", type: .insets,
                  value: .insets(top: Double(safeArea.top), left: Double(safeArea.left),
                                 bottom: Double(safeArea.bottom), right: Double(safeArea.right)),
                  isEditable: false),
            .init(id: "layout.layer.position", title: "Layer Position", type: .point,
                  value: .point(x: Double(position.x), y: Double(position.y)),
                  isEditable: true),
            .init(id: "layout.layer.anchorPoint", title: "Anchor Point", type: .point,
                  value: .point(x: Double(anchor.x), y: Double(anchor.y)),
                  isEditable: true),
        ]
    }

    private static func priorityAttributes(_ view: UIView) -> [XPAttribute] {
        let huggingH = view.contentHuggingPriority(for: .horizontal).rawValue
        let huggingV = view.contentHuggingPriority(for: .vertical).rawValue
        let resistH = view.contentCompressionResistancePriority(for: .horizontal).rawValue
        let resistV = view.contentCompressionResistancePriority(for: .vertical).rawValue
        return [
            .init(id: "layout.huggingH", title: "Hugging H", type: .double,
                  value: .double(Double(huggingH)), isEditable: true),
            .init(id: "layout.huggingV", title: "Hugging V", type: .double,
                  value: .double(Double(huggingV)), isEditable: true),
            .init(id: "layout.resistH", title: "Resistance H", type: .double,
                  value: .double(Double(resistH)), isEditable: true),
            .init(id: "layout.resistV", title: "Resistance V", type: .double,
                  value: .double(Double(resistV)), isEditable: true),
        ]
    }

    // MARK: - View / Layer

    private static func viewLayerGroup(_ view: UIView) -> XPAttributeGroup {
        var attrs = visibilityAttributes(view)
        if let background = view.backgroundColor {
            attrs.append(contentsOf: colorAttributes(id: "view.backgroundColor", title: "Background Color",
                                                     color: background))
        } else {
            attrs.append(.init(id: "view.backgroundColor", title: "Background Color", type: .color,
                               value: .color(r: 0, g: 0, b: 0, a: 0), isEditable: true))
        }
        attrs.append(contentsOf: borderAndShadowAttributes(view.layer))
        attrs.append(contentsOf: renderingAttributes(view))
        return XPAttributeGroup(id: "viewLayer", title: "View / Layer",
                                sections: [XPAttributeSection(id: "viewLayer.main", title: "", attributes: attrs)])
    }

    private static func visibilityAttributes(_ view: UIView) -> [XPAttribute] {
        [
            .init(id: "view.hidden", title: "Hidden", type: .bool,
                  value: .bool(view.isHidden), isEditable: true),
            .init(id: "view.alpha", title: "Alpha", type: .double,
                  value: .double(Double(view.alpha)), isEditable: true),
            .init(id: "view.userInteractionEnabled", title: "User Interaction", type: .bool,
                  value: .bool(view.isUserInteractionEnabled), isEditable: true),
            .init(id: "view.clipsToBounds", title: "Clips to Bounds", type: .bool,
                  value: .bool(view.clipsToBounds), isEditable: true),
            .init(id: "view.layer.cornerRadius", title: "Corner Radius", type: .double,
                  value: .double(Double(view.layer.cornerRadius)), isEditable: true),
        ]
    }

    private static func borderAndShadowAttributes(_ layer: CALayer) -> [XPAttribute] {
        var attrs = [XPAttribute]()
        if let borderColor = layer.borderColor,
           let borderAttribute = colorAttribute(id: "view.layer.borderColor", title: "Border Color",
                                                cgColor: borderColor)
        {
            attrs.append(borderAttribute)
        }
        attrs.append(.init(id: "view.layer.borderWidth", title: "Border Width", type: .double,
                           value: .double(Double(layer.borderWidth)), isEditable: true))
        if let shadowColor = layer.shadowColor,
           let shadowAttribute = colorAttribute(id: "view.layer.shadowColor", title: "Shadow Color",
                                                cgColor: shadowColor)
        {
            attrs.append(shadowAttribute)
        }
        attrs.append(contentsOf: [
            .init(id: "view.layer.shadowOpacity", title: "Shadow Opacity", type: .double,
                  value: .double(Double(layer.shadowOpacity)), isEditable: true),
            .init(id: "view.layer.shadowRadius", title: "Shadow Radius", type: .double,
                  value: .double(Double(layer.shadowRadius)), isEditable: true),
            .init(id: "view.layer.shadowOffset", title: "Shadow Offset", type: .size,
                  value: .size(w: Double(layer.shadowOffset.width), h: Double(layer.shadowOffset.height)),
                  isEditable: true),
        ])
        return attrs
    }

    private static func renderingAttributes(_ view: UIView) -> [XPAttribute] {
        let contentModes = ["scaleToFill", "scaleAspectFit", "scaleAspectFill", "redraw",
                            "center", "top", "bottom", "left", "right",
                            "topLeft", "topRight", "bottomLeft", "bottomRight"]
        var attrs: [XPAttribute] = [
            .init(id: "view.contentMode", title: "Content Mode", type: .enumeration,
                  value: .string(contentModes[safe: view.contentMode.rawValue] ?? "unknown"),
                  isEditable: true, enumCases: contentModes),
        ]
        if let tint = view.tintColor {
            attrs.append(contentsOf: colorAttributes(id: "view.tintColor", title: "Tint Color", color: tint))
        }
        attrs.append(.init(id: "view.tag", title: "Tag", type: .int,
                           value: .int(view.tag), isEditable: true))
        return attrs
    }

    // MARK: - Shared helpers

    static func colorAttributes(id: String, title: String, color: UIColor,
                                isEditable: Bool = true) -> [XPAttribute]
    {
        var attrs = [colorAttribute(id: id, title: title, color: color, isEditable: isEditable)]
        if let token = XPTokenResolverRegistry.shared.current?.colorToken(color) {
            attrs.append(.init(id: id + ".token", title: title + " Token", type: .string,
                               value: .string(token), isEditable: false))
        }
        return attrs
    }

    static func fontAttributes(idPrefix: String, font: UIFont) -> [XPAttribute] {
        var attrs: [XPAttribute] = [
            .init(id: idPrefix + ".fontSize", title: "Font Size", type: .double,
                  value: .double(Double(font.pointSize)), isEditable: true),
            .init(id: idPrefix + ".fontName", title: "Font", type: .string,
                  value: .string(font.fontName), isEditable: false),
        ]
        if let token = XPTokenResolverRegistry.shared.current?.fontToken(font) {
            attrs.append(.init(id: idPrefix + ".fontToken", title: "Font Token", type: .string,
                               value: .string(token), isEditable: false))
        }
        return attrs
    }

    static func colorAttribute(id: String, title: String, color: UIColor, isEditable: Bool = true) -> XPAttribute {
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 0
        color.getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        return .init(id: id, title: title, type: .color,
                     value: .color(r: Double(red), g: Double(green), b: Double(blue), a: Double(alpha)),
                     isEditable: isEditable)
    }

    static func colorAttribute(id: String, title: String, cgColor: CGColor,
                               isEditable: Bool = true) -> XPAttribute?
    {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let converted = cgColor.converted(to: space, intent: .defaultIntent, options: nil),
              let components = converted.components, components.count >= 4 else { return nil }

        return .init(id: id, title: title, type: .color,
                     value: .color(r: Double(components[0]), g: Double(components[1]),
                                   b: Double(components[2]), a: Double(components[3])),
                     isEditable: isEditable)
    }
}

extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

extension [String] {
    subscript(safe index: NSInteger) -> String? {
        let integerIndex = Int(index)
        return indices.contains(integerIndex) ? self[integerIndex] : nil
    }
}
