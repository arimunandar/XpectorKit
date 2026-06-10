import UIKit
import XpectorKit

final class XPAttributeBuilder {

    static func build(for view: UIView) -> [XPAttributeGroup] {
        var groups: [XPAttributeGroup] = []
        groups.append(layoutGroup(view))
        groups.append(viewLayerGroup(view))
        groups.append(accessibilityGroup(view))

        if let label = view as? UILabel {
            groups.append(labelGroup(label))
        }
        if let control = view as? UIControl {
            groups.append(controlGroup(control))
        }
        if let button = view as? UIButton {
            groups.append(buttonGroup(button))
        }
        if let scrollView = view as? UIScrollView {
            groups.append(scrollViewGroup(scrollView))
        }
        if let tableView = view as? UITableView {
            groups.append(tableViewGroup(tableView))
        }
        if let collectionView = view as? UICollectionView {
            groups.append(collectionViewGroup(collectionView))
        }
        if let stackView = view as? UIStackView {
            groups.append(stackViewGroup(stackView))
        }
        if let textField = view as? UITextField {
            groups.append(textFieldGroup(textField))
        }
        if let textView = view as? UITextView {
            groups.append(textViewGroup(textView))
        }
        if let imageView = view as? UIImageView {
            groups.append(imageViewGroup(imageView))
        }
        if let toggle = view as? UISwitch {
            groups.append(switchGroup(toggle))
        }
        if let slider = view as? UISlider {
            groups.append(sliderGroup(slider))
        }
        if let segmented = view as? UISegmentedControl {
            groups.append(segmentedControlGroup(segmented))
        }

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
        let frame = view.frame
        let bounds = view.bounds
        let safeArea = view.safeAreaInsets
        let anchor = view.layer.anchorPoint
        let position = view.layer.position

        var attrs: [XPAttribute] = [
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

        let intrinsic = view.intrinsicContentSize
        if intrinsic.width != UIView.noIntrinsicMetric || intrinsic.height != UIView.noIntrinsicMetric {
            attrs.append(.init(id: "layout.intrinsicContentSize", title: "Intrinsic Size", type: .size,
                               value: .size(w: Double(intrinsic.width), h: Double(intrinsic.height)),
                               isEditable: false))
        }

        let huggingH = view.contentHuggingPriority(for: .horizontal).rawValue
        let huggingV = view.contentHuggingPriority(for: .vertical).rawValue
        let resistH = view.contentCompressionResistancePriority(for: .horizontal).rawValue
        let resistV = view.contentCompressionResistancePriority(for: .vertical).rawValue
        attrs.append(contentsOf: [
            .init(id: "layout.huggingH", title: "Hugging H", type: .double,
                  value: .double(Double(huggingH)), isEditable: true),
            .init(id: "layout.huggingV", title: "Hugging V", type: .double,
                  value: .double(Double(huggingV)), isEditable: true),
            .init(id: "layout.resistH", title: "Resistance H", type: .double,
                  value: .double(Double(resistH)), isEditable: true),
            .init(id: "layout.resistV", title: "Resistance V", type: .double,
                  value: .double(Double(resistV)), isEditable: true),
        ])

        return XPAttributeGroup(id: "layout", title: "Layout",
                                sections: [XPAttributeSection(id: "layout.main", title: "", attributes: attrs)])
    }

    // MARK: - View / Layer

    private static func viewLayerGroup(_ view: UIView) -> XPAttributeGroup {
        let layer = view.layer
        var attrs: [XPAttribute] = [
            .init(id: "view.hidden", title: "Hidden", type: .bool,
                  value: .bool(view.isHidden), isEditable: true),
            .init(id: "view.alpha", title: "Alpha", type: .double,
                  value: .double(Double(view.alpha)), isEditable: true),
            .init(id: "view.userInteractionEnabled", title: "User Interaction", type: .bool,
                  value: .bool(view.isUserInteractionEnabled), isEditable: true),
            .init(id: "view.clipsToBounds", title: "Clips to Bounds", type: .bool,
                  value: .bool(view.clipsToBounds), isEditable: true),
            .init(id: "view.layer.cornerRadius", title: "Corner Radius", type: .double,
                  value: .double(Double(layer.cornerRadius)), isEditable: true),
        ]

        if let bg = view.backgroundColor {
            var r: CGFloat = 0; var g: CGFloat = 0; var b: CGFloat = 0; var a: CGFloat = 0
            bg.getRed(&r, green: &g, blue: &b, alpha: &a)
            attrs.append(.init(id: "view.backgroundColor", title: "Background Color", type: .color,
                               value: .color(r: Double(r), g: Double(g), b: Double(b), a: Double(a)),
                               isEditable: true))
        } else {
            attrs.append(.init(id: "view.backgroundColor", title: "Background Color", type: .color,
                               value: .color(r: 0, g: 0, b: 0, a: 0), isEditable: true))
        }

        if let borderColor = layer.borderColor {
            let c = UIColor(cgColor: borderColor)
            var r: CGFloat = 0; var g: CGFloat = 0; var b: CGFloat = 0; var a: CGFloat = 0
            c.getRed(&r, green: &g, blue: &b, alpha: &a)
            attrs.append(.init(id: "view.layer.borderColor", title: "Border Color", type: .color,
                               value: .color(r: Double(r), g: Double(g), b: Double(b), a: Double(a)),
                               isEditable: true))
        }

        attrs.append(.init(id: "view.layer.borderWidth", title: "Border Width", type: .double,
                           value: .double(Double(layer.borderWidth)), isEditable: true))

        if let shadowColor = layer.shadowColor {
            let c = UIColor(cgColor: shadowColor)
            var r: CGFloat = 0; var g: CGFloat = 0; var b: CGFloat = 0; var a: CGFloat = 0
            c.getRed(&r, green: &g, blue: &b, alpha: &a)
            attrs.append(.init(id: "view.layer.shadowColor", title: "Shadow Color", type: .color,
                               value: .color(r: Double(r), g: Double(g), b: Double(b), a: Double(a)),
                               isEditable: true))
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

        let contentModes = ["scaleToFill", "scaleAspectFit", "scaleAspectFill", "redraw",
                            "center", "top", "bottom", "left", "right",
                            "topLeft", "topRight", "bottomLeft", "bottomRight"]
        attrs.append(.init(id: "view.contentMode", title: "Content Mode", type: .enumeration,
                           value: .string(contentModes[safe: view.contentMode.rawValue] ?? "unknown"),
                           isEditable: true, enumCases: contentModes))

        if let tint = view.tintColor {
            var r: CGFloat = 0; var g: CGFloat = 0; var b: CGFloat = 0; var a: CGFloat = 0
            tint.getRed(&r, green: &g, blue: &b, alpha: &a)
            attrs.append(.init(id: "view.tintColor", title: "Tint Color", type: .color,
                               value: .color(r: Double(r), g: Double(g), b: Double(b), a: Double(a)),
                               isEditable: true))
        }

        attrs.append(.init(id: "view.tag", title: "Tag", type: .int,
                           value: .int(view.tag), isEditable: true))

        return XPAttributeGroup(id: "viewLayer", title: "View / Layer",
                                sections: [XPAttributeSection(id: "viewLayer.main", title: "", attributes: attrs)])
    }

    // MARK: - UILabel

    private static func labelGroup(_ label: UILabel) -> XPAttributeGroup {
        let alignments = ["left", "center", "right", "justified", "natural"]
        let lineBreaks = ["wordWrapping", "charWrapping", "clipping", "truncatingHead", "truncatingTail", "truncatingMiddle"]
        var attrs: [XPAttribute] = [
            .init(id: "label.text", title: "Text", type: .string,
                  value: .string(label.text ?? ""), isEditable: true),
            .init(id: "label.fontSize", title: "Font Size", type: .double,
                  value: .double(Double(label.font.pointSize)), isEditable: true),
            .init(id: "label.numberOfLines", title: "Number of Lines", type: .int,
                  value: .int(label.numberOfLines), isEditable: true),
        ]

        if let tc = label.textColor {
            var r: CGFloat = 0; var g: CGFloat = 0; var b: CGFloat = 0; var a: CGFloat = 0
            tc.getRed(&r, green: &g, blue: &b, alpha: &a)
            attrs.append(.init(id: "label.textColor", title: "Text Color", type: .color,
                               value: .color(r: Double(r), g: Double(g), b: Double(b), a: Double(a)),
                               isEditable: true))
        }

        attrs.append(contentsOf: [
            .init(id: "label.lineBreakMode", title: "Line Break Mode", type: .enumeration,
                  value: .string(lineBreaks[safe: label.lineBreakMode.rawValue] ?? "unknown"),
                  isEditable: true, enumCases: lineBreaks),
            .init(id: "label.textAlignment", title: "Text Alignment", type: .enumeration,
                  value: .string(alignments[safe: label.textAlignment.rawValue] ?? "unknown"),
                  isEditable: true, enumCases: alignments),
            .init(id: "label.adjustsFontSizeToFitWidth", title: "Adjusts Font Size", type: .bool,
                  value: .bool(label.adjustsFontSizeToFitWidth), isEditable: true),
        ])

        return XPAttributeGroup(id: "label", title: "UILabel",
                                sections: [XPAttributeSection(id: "label.main", title: "", attributes: attrs)])
    }

    // MARK: - UIControl

    private static func controlGroup(_ control: UIControl) -> XPAttributeGroup {
        let vAlignments = ["center", "top", "bottom", "fill"]
        let hAlignments = ["center", "left", "right", "fill", "leading", "trailing"]
        let attrs: [XPAttribute] = [
            .init(id: "control.enabled", title: "Enabled", type: .bool,
                  value: .bool(control.isEnabled), isEditable: true),
            .init(id: "control.selected", title: "Selected", type: .bool,
                  value: .bool(control.isSelected), isEditable: true),
            .init(id: "control.contentVerticalAlignment", title: "Vertical Alignment", type: .enumeration,
                  value: .string(vAlignments[safe: control.contentVerticalAlignment.rawValue] ?? "unknown"),
                  isEditable: true, enumCases: vAlignments),
            .init(id: "control.contentHorizontalAlignment", title: "Horizontal Alignment", type: .enumeration,
                  value: .string(hAlignments[safe: control.contentHorizontalAlignment.rawValue] ?? "unknown"),
                  isEditable: true, enumCases: hAlignments),
        ]
        return XPAttributeGroup(id: "control", title: "UIControl",
                                sections: [XPAttributeSection(id: "control.main", title: "", attributes: attrs)])
    }

    // MARK: - UIButton

    private static func buttonGroup(_ button: UIButton) -> XPAttributeGroup {
        let config = button.configuration
        let contentInsets = config?.contentInsets ?? NSDirectionalEdgeInsets.zero
        let attrs: [XPAttribute] = [
            .init(id: "button.contentInsets", title: "Content Insets", type: .insets,
                  value: .insets(top: Double(contentInsets.top), left: Double(contentInsets.leading),
                                 bottom: Double(contentInsets.bottom), right: Double(contentInsets.trailing)),
                  isEditable: false),
        ]
        return XPAttributeGroup(id: "button", title: "UIButton",
                                sections: [XPAttributeSection(id: "button.main", title: "", attributes: attrs)])
    }

    // MARK: - UIScrollView

    private static func scrollViewGroup(_ scrollView: UIScrollView) -> XPAttributeGroup {
        let ci = scrollView.contentInset
        let aci = scrollView.adjustedContentInset
        let co = scrollView.contentOffset
        let cs = scrollView.contentSize
        let attrs: [XPAttribute] = [
            .init(id: "scroll.contentInset", title: "Content Inset", type: .insets,
                  value: .insets(top: Double(ci.top), left: Double(ci.left),
                                 bottom: Double(ci.bottom), right: Double(ci.right)),
                  isEditable: true),
            .init(id: "scroll.adjustedContentInset", title: "Adjusted Content Inset", type: .insets,
                  value: .insets(top: Double(aci.top), left: Double(aci.left),
                                 bottom: Double(aci.bottom), right: Double(aci.right)),
                  isEditable: false),
            .init(id: "scroll.contentOffset", title: "Content Offset", type: .point,
                  value: .point(x: Double(co.x), y: Double(co.y)), isEditable: true),
            .init(id: "scroll.contentSize", title: "Content Size", type: .size,
                  value: .size(w: Double(cs.width), h: Double(cs.height)), isEditable: true),
            .init(id: "scroll.bounces", title: "Bounces", type: .bool,
                  value: .bool(scrollView.bounces), isEditable: true),
            .init(id: "scroll.isPagingEnabled", title: "Paging Enabled", type: .bool,
                  value: .bool(scrollView.isPagingEnabled), isEditable: true),
            .init(id: "scroll.zoomScale", title: "Zoom Scale", type: .double,
                  value: .double(Double(scrollView.zoomScale)), isEditable: false),
        ]
        return XPAttributeGroup(id: "scrollView", title: "UIScrollView",
                                sections: [XPAttributeSection(id: "scroll.main", title: "", attributes: attrs)])
    }

    // MARK: - UITableView

    private static func tableViewGroup(_ tableView: UITableView) -> XPAttributeGroup {
        let styles = ["plain", "grouped", "insetGrouped"]
        let sepStyles = ["none", "singleLine", "singleLineEtched"]
        let si = tableView.separatorInset

        var attrs: [XPAttribute] = [
            .init(id: "table.style", title: "Style", type: .enumeration,
                  value: .string(styles[safe: tableView.style.rawValue] ?? "unknown"),
                  isEditable: false, enumCases: styles),
            .init(id: "table.numberOfSections", title: "Sections", type: .int,
                  value: .int(tableView.numberOfSections), isEditable: false),
            .init(id: "table.separatorStyle", title: "Separator Style", type: .enumeration,
                  value: .string(sepStyles[safe: tableView.separatorStyle.rawValue] ?? "unknown"),
                  isEditable: true, enumCases: sepStyles),
        ]

        if let sepColor = tableView.separatorColor {
            var r: CGFloat = 0; var g: CGFloat = 0; var b: CGFloat = 0; var a: CGFloat = 0
            sepColor.getRed(&r, green: &g, blue: &b, alpha: &a)
            attrs.append(.init(id: "table.separatorColor", title: "Separator Color", type: .color,
                               value: .color(r: Double(r), g: Double(g), b: Double(b), a: Double(a)),
                               isEditable: true))
        }

        attrs.append(.init(id: "table.separatorInset", title: "Separator Inset", type: .insets,
                           value: .insets(top: Double(si.top), left: Double(si.left),
                                          bottom: Double(si.bottom), right: Double(si.right)),
                           isEditable: true))

        return XPAttributeGroup(id: "tableView", title: "UITableView",
                                sections: [XPAttributeSection(id: "table.main", title: "", attributes: attrs)])
    }

    // MARK: - UIStackView

    private static func stackViewGroup(_ stackView: UIStackView) -> XPAttributeGroup {
        let axes = ["horizontal", "vertical"]
        let distributions = ["fill", "fillEqually", "fillProportionally", "equalSpacing", "equalCentering"]
        let alignments = ["fill", "leading", "firstBaseline", "center", "trailing", "lastBaseline"]
        let attrs: [XPAttribute] = [
            .init(id: "stack.axis", title: "Axis", type: .enumeration,
                  value: .string(axes[safe: stackView.axis.rawValue] ?? "unknown"),
                  isEditable: true, enumCases: axes),
            .init(id: "stack.distribution", title: "Distribution", type: .enumeration,
                  value: .string(distributions[safe: stackView.distribution.rawValue] ?? "unknown"),
                  isEditable: true, enumCases: distributions),
            .init(id: "stack.alignment", title: "Alignment", type: .enumeration,
                  value: .string(alignments[safe: stackView.alignment.rawValue] ?? "unknown"),
                  isEditable: true, enumCases: alignments),
            .init(id: "stack.spacing", title: "Spacing", type: .double,
                  value: .double(Double(stackView.spacing)), isEditable: true),
        ]
        return XPAttributeGroup(id: "stackView", title: "UIStackView",
                                sections: [XPAttributeSection(id: "stack.main", title: "", attributes: attrs)])
    }

    // MARK: - UITextField

    private static func textFieldGroup(_ textField: UITextField) -> XPAttributeGroup {
        let alignments = ["left", "center", "right", "justified", "natural"]
        let clearModes = ["never", "whileEditing", "unlessEditing", "always"]
        var attrs: [XPAttribute] = [
            .init(id: "textField.text", title: "Text", type: .string,
                  value: .string(textField.text ?? ""), isEditable: true),
            .init(id: "textField.placeholder", title: "Placeholder", type: .string,
                  value: .string(textField.placeholder ?? ""), isEditable: true),
        ]

        if let font = textField.font {
            attrs.append(.init(id: "textField.fontSize", title: "Font Size", type: .double,
                               value: .double(Double(font.pointSize)), isEditable: true))
        }

        if let tc = textField.textColor {
            var r: CGFloat = 0; var g: CGFloat = 0; var b: CGFloat = 0; var a: CGFloat = 0
            tc.getRed(&r, green: &g, blue: &b, alpha: &a)
            attrs.append(.init(id: "textField.textColor", title: "Text Color", type: .color,
                               value: .color(r: Double(r), g: Double(g), b: Double(b), a: Double(a)),
                               isEditable: true))
        }

        attrs.append(contentsOf: [
            .init(id: "textField.textAlignment", title: "Text Alignment", type: .enumeration,
                  value: .string(alignments[safe: textField.textAlignment.rawValue] ?? "unknown"),
                  isEditable: true, enumCases: alignments),
            .init(id: "textField.clearButtonMode", title: "Clear Button Mode", type: .enumeration,
                  value: .string(clearModes[safe: textField.clearButtonMode.rawValue] ?? "unknown"),
                  isEditable: true, enumCases: clearModes),
        ])

        return XPAttributeGroup(id: "textField", title: "UITextField",
                                sections: [XPAttributeSection(id: "textField.main", title: "", attributes: attrs)])
    }

    // MARK: - UITextView

    private static func textViewGroup(_ textView: UITextView) -> XPAttributeGroup {
        let alignments = ["left", "center", "right", "justified", "natural"]
        let tci = textView.textContainerInset
        var attrs: [XPAttribute] = [
            .init(id: "textView.text", title: "Text", type: .string,
                  value: .string(textView.text ?? ""), isEditable: true),
        ]

        if let font = textView.font {
            attrs.append(.init(id: "textView.fontSize", title: "Font Size", type: .double,
                               value: .double(Double(font.pointSize)), isEditable: true))
        }

        if let tc = textView.textColor {
            var r: CGFloat = 0; var g: CGFloat = 0; var b: CGFloat = 0; var a: CGFloat = 0
            tc.getRed(&r, green: &g, blue: &b, alpha: &a)
            attrs.append(.init(id: "textView.textColor", title: "Text Color", type: .color,
                               value: .color(r: Double(r), g: Double(g), b: Double(b), a: Double(a)),
                               isEditable: true))
        }

        attrs.append(contentsOf: [
            .init(id: "textView.textAlignment", title: "Text Alignment", type: .enumeration,
                  value: .string(alignments[safe: textView.textAlignment.rawValue] ?? "unknown"),
                  isEditable: true, enumCases: alignments),
            .init(id: "textView.isEditable", title: "Editable", type: .bool,
                  value: .bool(textView.isEditable), isEditable: true),
            .init(id: "textView.isSelectable", title: "Selectable", type: .bool,
                  value: .bool(textView.isSelectable), isEditable: true),
            .init(id: "textView.textContainerInset", title: "Container Inset", type: .insets,
                  value: .insets(top: Double(tci.top), left: Double(tci.left),
                                 bottom: Double(tci.bottom), right: Double(tci.right)),
                  isEditable: true),
        ])

        return XPAttributeGroup(id: "textView", title: "UITextView",
                                sections: [XPAttributeSection(id: "textView.main", title: "", attributes: attrs)])
    }

    // MARK: - UIImageView

    private static func imageViewGroup(_ imageView: UIImageView) -> XPAttributeGroup {
        var attrs: [XPAttribute] = []
        if let image = imageView.image {
            // `assetName` is a private/undocumented key on UIImageAsset. Probe
            // with `responds(to:)` first — calling value(forKey:) on a key that
            // doesn't exist raises NSUnknownKeyException, which is uncatchable in
            // Swift and would crash the host app on a future iOS version.
            let assetName: String? = {
                guard let asset = image.imageAsset,
                      asset.responds(to: NSSelectorFromString("assetName")) else { return nil }
                return asset.value(forKey: "assetName") as? String
            }()
            let name = image.accessibilityIdentifier
                ?? assetName
                ?? "(unnamed)"
            attrs.append(.init(id: "imageView.imageName", title: "Image Name", type: .string,
                               value: .string(name), isEditable: false))
            attrs.append(.init(id: "imageView.imageSize", title: "Image Size", type: .size,
                               value: .size(w: Double(image.size.width), h: Double(image.size.height)),
                               isEditable: false))
            attrs.append(.init(id: "imageView.imageScale", title: "Image Scale", type: .double,
                               value: .double(Double(image.scale)), isEditable: false))
        } else {
            attrs.append(.init(id: "imageView.imageName", title: "Image", type: .string,
                               value: .string("(no image)"), isEditable: false))
        }
        return XPAttributeGroup(id: "imageView", title: "UIImageView",
                                sections: [XPAttributeSection(id: "imageView.main", title: "", attributes: attrs)])
    }

    // MARK: - UICollectionView

    private static func collectionViewGroup(_ cv: UICollectionView) -> XPAttributeGroup {
        var attrs: [XPAttribute] = [
            .init(id: "cv.numberOfSections", title: "Sections", type: .int,
                  value: .int(cv.numberOfSections), isEditable: false),
        ]
        for section in 0..<min(cv.numberOfSections, 20) {
            attrs.append(.init(id: "cv.section\(section).items", title: "Section \(section) Items", type: .int,
                               value: .int(cv.numberOfItems(inSection: section)), isEditable: false))
        }
        if let flow = cv.collectionViewLayout as? UICollectionViewFlowLayout {
            let dirs = ["vertical", "horizontal"]
            attrs.append(.init(id: "cv.scrollDirection", title: "Scroll Direction", type: .enumeration,
                               value: .string(dirs[safe: flow.scrollDirection.rawValue] ?? "unknown"),
                               isEditable: false, enumCases: dirs))
            attrs.append(.init(id: "cv.itemSize", title: "Item Size", type: .size,
                               value: .size(w: Double(flow.itemSize.width), h: Double(flow.itemSize.height)),
                               isEditable: false))
            attrs.append(.init(id: "cv.minimumLineSpacing", title: "Line Spacing", type: .double,
                               value: .double(Double(flow.minimumLineSpacing)), isEditable: true))
            attrs.append(.init(id: "cv.minimumInteritemSpacing", title: "Interitem Spacing", type: .double,
                               value: .double(Double(flow.minimumInteritemSpacing)), isEditable: true))
        }
        return XPAttributeGroup(id: "collectionView", title: "UICollectionView",
                                sections: [XPAttributeSection(id: "cv.main", title: "", attributes: attrs)])
    }

    // MARK: - UISwitch

    private static func switchGroup(_ toggle: UISwitch) -> XPAttributeGroup {
        let attrs: [XPAttribute] = [
            .init(id: "switch.isOn", title: "Is On", type: .bool,
                  value: .bool(toggle.isOn), isEditable: true),
        ]
        return XPAttributeGroup(id: "switch", title: "UISwitch",
                                sections: [XPAttributeSection(id: "switch.main", title: "", attributes: attrs)])
    }

    // MARK: - UISlider

    private static func sliderGroup(_ slider: UISlider) -> XPAttributeGroup {
        let attrs: [XPAttribute] = [
            .init(id: "slider.value", title: "Value", type: .double,
                  value: .double(Double(slider.value)), isEditable: true),
            .init(id: "slider.minimumValue", title: "Min", type: .double,
                  value: .double(Double(slider.minimumValue)), isEditable: true),
            .init(id: "slider.maximumValue", title: "Max", type: .double,
                  value: .double(Double(slider.maximumValue)), isEditable: true),
        ]
        return XPAttributeGroup(id: "slider", title: "UISlider",
                                sections: [XPAttributeSection(id: "slider.main", title: "", attributes: attrs)])
    }

    // MARK: - UISegmentedControl

    private static func segmentedControlGroup(_ seg: UISegmentedControl) -> XPAttributeGroup {
        var attrs: [XPAttribute] = [
            .init(id: "seg.selectedIndex", title: "Selected Index", type: .int,
                  value: .int(seg.selectedSegmentIndex), isEditable: true),
            .init(id: "seg.numberOfSegments", title: "Segments", type: .int,
                  value: .int(seg.numberOfSegments), isEditable: false),
        ]
        for i in 0..<seg.numberOfSegments {
            let title = seg.titleForSegment(at: i) ?? "(image)"
            attrs.append(.init(id: "seg.segment\(i).title", title: "Segment \(i)", type: .string,
                               value: .string(title), isEditable: true))
        }
        return XPAttributeGroup(id: "segmentedControl", title: "UISegmentedControl",
                                sections: [XPAttributeSection(id: "seg.main", title: "", attributes: attrs)])
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

private extension Array where Element == String {
    subscript(safe index: NSInteger) -> String? {
        let idx = Int(index)
        return indices.contains(idx) ? self[idx] : nil
    }
}
