import UIKit
import XpectorKit

extension XPAttributeBuilder {
    static func controlGroups(for view: UIView) -> [XPAttributeGroup] {
        var groups = [XPAttributeGroup]()
        if let control = view as? UIControl {
            groups.append(controlGroup(control))
        }
        if let button = view as? UIButton {
            groups.append(buttonGroup(button))
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

    private static func segmentedControlGroup(_ segmented: UISegmentedControl) -> XPAttributeGroup {
        var attrs: [XPAttribute] = [
            .init(id: "seg.selectedIndex", title: "Selected Index", type: .int,
                  value: .int(segmented.selectedSegmentIndex), isEditable: true),
            .init(id: "seg.numberOfSegments", title: "Segments", type: .int,
                  value: .int(segmented.numberOfSegments), isEditable: false),
        ]
        for segment in 0 ..< segmented.numberOfSegments {
            let title = segmented.titleForSegment(at: segment) ?? "(image)"
            attrs.append(.init(id: "seg.segment\(segment).title", title: "Segment \(segment)", type: .string,
                               value: .string(title), isEditable: true))
        }
        return XPAttributeGroup(id: "segmentedControl", title: "UISegmentedControl",
                                sections: [XPAttributeSection(id: "seg.main", title: "", attributes: attrs)])
    }
}
