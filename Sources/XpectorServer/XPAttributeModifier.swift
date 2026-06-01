import UIKit
import XpectorKit

final class XPAttributeModifier {

    static func apply(
        _ modification: XPAttributeModification,
        to view: UIView,
        screenshotScale: Double = 1.0,
        maxScreenshotDimension: Int = 512
    ) -> XPModificationResponse {
        let id = modification.attributeID
        let val = modification.value

        do {
            try applyValue(id: id, value: val, to: view)

            view.setNeedsLayout()
            view.layoutIfNeeded()

            let screenshot = XPHierarchyCapture.captureSoloScreenshotPublic(
                of: view, scale: screenshotScale, maxDimension: maxScreenshotDimension)
            let groups = XPAttributeBuilder.build(for: view)

            return XPModificationResponse(
                success: true,
                updatedGroups: groups,
                updatedScreenshot: screenshot
            )
        } catch {
            return XPModificationResponse(success: false, error: error.localizedDescription)
        }
    }

    private static func applyValue(id: String, value: XPAttributeValue, to view: UIView) throws {
        switch id {

        // MARK: Layout
        case "layout.frame":
            guard case .rect(let x, let y, let w, let h) = value else { throw ModError.typeMismatch }
            view.frame = CGRect(x: x, y: y, width: w, height: h)
        case "layout.bounds":
            guard case .rect(let x, let y, let w, let h) = value else { throw ModError.typeMismatch }
            view.bounds = CGRect(x: x, y: y, width: w, height: h)
        case "layout.layer.position":
            guard case .point(let x, let y) = value else { throw ModError.typeMismatch }
            view.layer.position = CGPoint(x: x, y: y)
        case "layout.layer.anchorPoint":
            guard case .point(let x, let y) = value else { throw ModError.typeMismatch }
            view.layer.anchorPoint = CGPoint(x: x, y: y)
        case "layout.huggingH":
            guard case .double(let v) = value else { throw ModError.typeMismatch }
            view.setContentHuggingPriority(UILayoutPriority(Float(v)), for: .horizontal)
        case "layout.huggingV":
            guard case .double(let v) = value else { throw ModError.typeMismatch }
            view.setContentHuggingPriority(UILayoutPriority(Float(v)), for: .vertical)
        case "layout.resistH":
            guard case .double(let v) = value else { throw ModError.typeMismatch }
            view.setContentCompressionResistancePriority(UILayoutPriority(Float(v)), for: .horizontal)
        case "layout.resistV":
            guard case .double(let v) = value else { throw ModError.typeMismatch }
            view.setContentCompressionResistancePriority(UILayoutPriority(Float(v)), for: .vertical)

        // MARK: View / Layer
        case "view.hidden":
            guard case .bool(let v) = value else { throw ModError.typeMismatch }
            view.isHidden = v
        case "view.alpha":
            guard case .double(let v) = value else { throw ModError.typeMismatch }
            view.alpha = CGFloat(v)
        case "view.userInteractionEnabled":
            guard case .bool(let v) = value else { throw ModError.typeMismatch }
            view.isUserInteractionEnabled = v
        case "view.clipsToBounds":
            guard case .bool(let v) = value else { throw ModError.typeMismatch }
            view.clipsToBounds = v
        case "view.layer.cornerRadius":
            guard case .double(let v) = value else { throw ModError.typeMismatch }
            view.layer.cornerRadius = CGFloat(v)
        case "view.backgroundColor":
            guard case .color(let r, let g, let b, let a) = value else { throw ModError.typeMismatch }
            view.backgroundColor = UIColor(red: r, green: g, blue: b, alpha: a)
        case "view.layer.borderColor":
            guard case .color(let r, let g, let b, let a) = value else { throw ModError.typeMismatch }
            view.layer.borderColor = UIColor(red: r, green: g, blue: b, alpha: a).cgColor
        case "view.layer.borderWidth":
            guard case .double(let v) = value else { throw ModError.typeMismatch }
            view.layer.borderWidth = CGFloat(v)
        case "view.layer.shadowColor":
            guard case .color(let r, let g, let b, let a) = value else { throw ModError.typeMismatch }
            view.layer.shadowColor = UIColor(red: r, green: g, blue: b, alpha: a).cgColor
        case "view.layer.shadowOpacity":
            guard case .double(let v) = value else { throw ModError.typeMismatch }
            view.layer.shadowOpacity = Float(v)
        case "view.layer.shadowRadius":
            guard case .double(let v) = value else { throw ModError.typeMismatch }
            view.layer.shadowRadius = CGFloat(v)
        case "view.layer.shadowOffset":
            guard case .size(let w, let h) = value else { throw ModError.typeMismatch }
            view.layer.shadowOffset = CGSize(width: w, height: h)
        case "view.contentMode":
            guard case .string(let s) = value else { throw ModError.typeMismatch }
            let modes = ["scaleToFill", "scaleAspectFit", "scaleAspectFill", "redraw",
                         "center", "top", "bottom", "left", "right",
                         "topLeft", "topRight", "bottomLeft", "bottomRight"]
            guard let idx = modes.firstIndex(of: s) else { throw ModError.invalidValue }
            view.contentMode = UIView.ContentMode(rawValue: idx) ?? .scaleToFill
        case "view.tintColor":
            guard case .color(let r, let g, let b, let a) = value else { throw ModError.typeMismatch }
            view.tintColor = UIColor(red: r, green: g, blue: b, alpha: a)
        case "view.tag":
            guard case .int(let v) = value else { throw ModError.typeMismatch }
            view.tag = v

        // MARK: UILabel
        case "label.text":
            guard case .string(let v) = value, let label = view as? UILabel else { throw ModError.typeMismatch }
            label.text = v
        case "label.fontSize":
            guard case .double(let v) = value, let label = view as? UILabel else { throw ModError.typeMismatch }
            label.font = label.font.withSize(CGFloat(v))
        case "label.numberOfLines":
            guard case .int(let v) = value, let label = view as? UILabel else { throw ModError.typeMismatch }
            label.numberOfLines = v
        case "label.textColor":
            guard case .color(let r, let g, let b, let a) = value, let label = view as? UILabel else { throw ModError.typeMismatch }
            label.textColor = UIColor(red: r, green: g, blue: b, alpha: a)
        case "label.lineBreakMode":
            guard case .string(let s) = value, let label = view as? UILabel else { throw ModError.typeMismatch }
            let modes = ["wordWrapping", "charWrapping", "clipping", "truncatingHead", "truncatingTail", "truncatingMiddle"]
            guard let idx = modes.firstIndex(of: s) else { throw ModError.invalidValue }
            label.lineBreakMode = NSLineBreakMode(rawValue: idx) ?? .byTruncatingTail
        case "label.textAlignment":
            guard case .string(let s) = value, let label = view as? UILabel else { throw ModError.typeMismatch }
            let alignments = ["left", "center", "right", "justified", "natural"]
            guard let idx = alignments.firstIndex(of: s) else { throw ModError.invalidValue }
            label.textAlignment = NSTextAlignment(rawValue: idx) ?? .natural
        case "label.adjustsFontSizeToFitWidth":
            guard case .bool(let v) = value, let label = view as? UILabel else { throw ModError.typeMismatch }
            label.adjustsFontSizeToFitWidth = v

        // MARK: UIControl
        case "control.enabled":
            guard case .bool(let v) = value, let control = view as? UIControl else { throw ModError.typeMismatch }
            control.isEnabled = v
        case "control.selected":
            guard case .bool(let v) = value, let control = view as? UIControl else { throw ModError.typeMismatch }
            control.isSelected = v
        case "control.contentVerticalAlignment":
            guard case .string(let s) = value, let control = view as? UIControl else { throw ModError.typeMismatch }
            let alignments = ["center", "top", "bottom", "fill"]
            guard let idx = alignments.firstIndex(of: s) else { throw ModError.invalidValue }
            control.contentVerticalAlignment = UIControl.ContentVerticalAlignment(rawValue: idx) ?? .center
        case "control.contentHorizontalAlignment":
            guard case .string(let s) = value, let control = view as? UIControl else { throw ModError.typeMismatch }
            let alignments = ["center", "left", "right", "fill", "leading", "trailing"]
            guard let idx = alignments.firstIndex(of: s) else { throw ModError.invalidValue }
            control.contentHorizontalAlignment = UIControl.ContentHorizontalAlignment(rawValue: idx) ?? .center

        // MARK: UIScrollView
        case "scroll.contentInset":
            guard case .insets(let t, let l, let b, let r) = value, let sv = view as? UIScrollView else { throw ModError.typeMismatch }
            sv.contentInset = UIEdgeInsets(top: t, left: l, bottom: b, right: r)
        case "scroll.contentOffset":
            guard case .point(let x, let y) = value, let sv = view as? UIScrollView else { throw ModError.typeMismatch }
            sv.contentOffset = CGPoint(x: x, y: y)
        case "scroll.contentSize":
            guard case .size(let w, let h) = value, let sv = view as? UIScrollView else { throw ModError.typeMismatch }
            sv.contentSize = CGSize(width: w, height: h)
        case "scroll.bounces":
            guard case .bool(let v) = value, let sv = view as? UIScrollView else { throw ModError.typeMismatch }
            sv.bounces = v
        case "scroll.isPagingEnabled":
            guard case .bool(let v) = value, let sv = view as? UIScrollView else { throw ModError.typeMismatch }
            sv.isPagingEnabled = v

        // MARK: UITableView
        case "table.separatorStyle":
            guard case .string(let s) = value, let tv = view as? UITableView else { throw ModError.typeMismatch }
            let styles = ["none", "singleLine", "singleLineEtched"]
            guard let idx = styles.firstIndex(of: s) else { throw ModError.invalidValue }
            tv.separatorStyle = UITableViewCell.SeparatorStyle(rawValue: idx) ?? .none
        case "table.separatorColor":
            guard case .color(let r, let g, let b, let a) = value, let tv = view as? UITableView else { throw ModError.typeMismatch }
            tv.separatorColor = UIColor(red: r, green: g, blue: b, alpha: a)
        case "table.separatorInset":
            guard case .insets(let t, let l, let b, let r) = value, let tv = view as? UITableView else { throw ModError.typeMismatch }
            tv.separatorInset = UIEdgeInsets(top: t, left: l, bottom: b, right: r)

        // MARK: UIStackView
        case "stack.axis":
            guard case .string(let s) = value, let sv = view as? UIStackView else { throw ModError.typeMismatch }
            sv.axis = s == "vertical" ? .vertical : .horizontal
        case "stack.distribution":
            guard case .string(let s) = value, let sv = view as? UIStackView else { throw ModError.typeMismatch }
            let dists = ["fill", "fillEqually", "fillProportionally", "equalSpacing", "equalCentering"]
            guard let idx = dists.firstIndex(of: s) else { throw ModError.invalidValue }
            sv.distribution = UIStackView.Distribution(rawValue: idx) ?? .fill
        case "stack.alignment":
            guard case .string(let s) = value, let sv = view as? UIStackView else { throw ModError.typeMismatch }
            let aligns = ["fill", "leading", "firstBaseline", "center", "trailing", "lastBaseline"]
            guard let idx = aligns.firstIndex(of: s) else { throw ModError.invalidValue }
            sv.alignment = UIStackView.Alignment(rawValue: idx) ?? .fill
        case "stack.spacing":
            guard case .double(let v) = value, let sv = view as? UIStackView else { throw ModError.typeMismatch }
            sv.spacing = CGFloat(v)

        // MARK: UITextField
        case "textField.text":
            guard case .string(let v) = value, let tf = view as? UITextField else { throw ModError.typeMismatch }
            tf.text = v
        case "textField.placeholder":
            guard case .string(let v) = value, let tf = view as? UITextField else { throw ModError.typeMismatch }
            tf.placeholder = v
        case "textField.fontSize":
            guard case .double(let v) = value, let tf = view as? UITextField else { throw ModError.typeMismatch }
            if let font = tf.font {
                tf.font = font.withSize(CGFloat(v))
            }
        case "textField.textColor":
            guard case .color(let r, let g, let b, let a) = value, let tf = view as? UITextField else { throw ModError.typeMismatch }
            tf.textColor = UIColor(red: r, green: g, blue: b, alpha: a)
        case "textField.textAlignment":
            guard case .string(let s) = value, let tf = view as? UITextField else { throw ModError.typeMismatch }
            let alignments = ["left", "center", "right", "justified", "natural"]
            guard let idx = alignments.firstIndex(of: s) else { throw ModError.invalidValue }
            tf.textAlignment = NSTextAlignment(rawValue: idx) ?? .natural
        case "textField.clearButtonMode":
            guard case .string(let s) = value, let tf = view as? UITextField else { throw ModError.typeMismatch }
            let modes = ["never", "whileEditing", "unlessEditing", "always"]
            guard let idx = modes.firstIndex(of: s) else { throw ModError.invalidValue }
            tf.clearButtonMode = UITextField.ViewMode(rawValue: idx) ?? .never

        // MARK: UITextView
        case "textView.text":
            guard case .string(let v) = value, let tv = view as? UITextView else { throw ModError.typeMismatch }
            tv.text = v
        case "textView.fontSize":
            guard case .double(let v) = value, let tv = view as? UITextView else { throw ModError.typeMismatch }
            if let font = tv.font {
                tv.font = font.withSize(CGFloat(v))
            }
        case "textView.textColor":
            guard case .color(let r, let g, let b, let a) = value, let tv = view as? UITextView else { throw ModError.typeMismatch }
            tv.textColor = UIColor(red: r, green: g, blue: b, alpha: a)
        case "textView.textAlignment":
            guard case .string(let s) = value, let tv = view as? UITextView else { throw ModError.typeMismatch }
            let alignments = ["left", "center", "right", "justified", "natural"]
            guard let idx = alignments.firstIndex(of: s) else { throw ModError.invalidValue }
            tv.textAlignment = NSTextAlignment(rawValue: idx) ?? .natural
        case "textView.isEditable":
            guard case .bool(let v) = value, let tv = view as? UITextView else { throw ModError.typeMismatch }
            tv.isEditable = v
        case "textView.isSelectable":
            guard case .bool(let v) = value, let tv = view as? UITextView else { throw ModError.typeMismatch }
            tv.isSelectable = v
        case "textView.textContainerInset":
            guard case .insets(let t, let l, let b, let r) = value, let tv = view as? UITextView else { throw ModError.typeMismatch }
            tv.textContainerInset = UIEdgeInsets(top: t, left: l, bottom: b, right: r)

        default:
            throw ModError.unknownAttribute
        }
    }

    private enum ModError: LocalizedError {
        case typeMismatch, invalidValue, unknownAttribute

        var errorDescription: String? {
            switch self {
            case .typeMismatch: "Type mismatch for attribute value"
            case .invalidValue: "Invalid value for attribute"
            case .unknownAttribute: "Unknown attribute ID"
            }
        }
    }
}
