import UIKit
import XpectorKit

extension XPAttributeBuilder {
    static func textGroups(for view: UIView) -> [XPAttributeGroup] {
        var groups = [XPAttributeGroup]()
        if let label = view as? UILabel {
            groups.append(labelGroup(label))
        }
        if let textField = view as? UITextField {
            groups.append(textFieldGroup(textField))
        }
        if let textView = view as? UITextView {
            groups.append(textViewGroup(textView))
        }
        return groups
    }

    // MARK: - UILabel

    private static func labelGroup(_ label: UILabel) -> XPAttributeGroup {
        let alignments = ["left", "center", "right", "justified", "natural"]
        let lineBreaks = ["wordWrapping", "charWrapping", "clipping",
                          "truncatingHead", "truncatingTail", "truncatingMiddle"]
        var attrs: [XPAttribute] = [
            .init(id: "label.text", title: "Text", type: .string,
                  value: .string(label.text ?? ""), isEditable: true),
        ]
        attrs.append(contentsOf: fontAttributes(idPrefix: "label", font: label.font))
        attrs.append(.init(id: "label.numberOfLines", title: "Number of Lines", type: .int,
                           value: .int(label.numberOfLines), isEditable: true))
        if let textColor = label.textColor {
            attrs.append(contentsOf: colorAttributes(id: "label.textColor", title: "Text Color",
                                                     color: textColor))
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
            attrs.append(contentsOf: fontAttributes(idPrefix: "textField", font: font))
        }
        if let textColor = textField.textColor {
            attrs.append(contentsOf: colorAttributes(id: "textField.textColor", title: "Text Color",
                                                     color: textColor))
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
        let containerInset = textView.textContainerInset
        var attrs: [XPAttribute] = [
            .init(id: "textView.text", title: "Text", type: .string,
                  value: .string(textView.text ?? ""), isEditable: true),
        ]
        if let font = textView.font {
            attrs.append(contentsOf: fontAttributes(idPrefix: "textView", font: font))
        }
        if let textColor = textView.textColor {
            attrs.append(contentsOf: colorAttributes(id: "textView.textColor", title: "Text Color",
                                                     color: textColor))
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
                  value: .insets(top: Double(containerInset.top), left: Double(containerInset.left),
                                 bottom: Double(containerInset.bottom), right: Double(containerInset.right)),
                  isEditable: true),
        ])
        return XPAttributeGroup(id: "textView", title: "UITextView",
                                sections: [XPAttributeSection(id: "textView.main", title: "", attributes: attrs)])
    }
}
