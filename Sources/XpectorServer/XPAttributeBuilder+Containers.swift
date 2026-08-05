import UIKit
import XpectorKit

extension XPAttributeBuilder {
    static func containerGroups(for view: UIView) -> [XPAttributeGroup] {
        var groups = [XPAttributeGroup]()
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
        if let imageView = view as? UIImageView {
            groups.append(imageViewGroup(imageView))
        }
        return groups
    }

    // MARK: - UIScrollView

    private static func scrollViewGroup(_ scrollView: UIScrollView) -> XPAttributeGroup {
        let inset = scrollView.contentInset
        let adjustedInset = scrollView.adjustedContentInset
        let offset = scrollView.contentOffset
        let size = scrollView.contentSize
        let attrs: [XPAttribute] = [
            .init(id: "scroll.contentInset", title: "Content Inset", type: .insets,
                  value: .insets(top: Double(inset.top), left: Double(inset.left),
                                 bottom: Double(inset.bottom), right: Double(inset.right)),
                  isEditable: true),
            .init(id: "scroll.adjustedContentInset", title: "Adjusted Content Inset", type: .insets,
                  value: .insets(top: Double(adjustedInset.top), left: Double(adjustedInset.left),
                                 bottom: Double(adjustedInset.bottom), right: Double(adjustedInset.right)),
                  isEditable: false),
            .init(id: "scroll.contentOffset", title: "Content Offset", type: .point,
                  value: .point(x: Double(offset.x), y: Double(offset.y)), isEditable: true),
            .init(id: "scroll.contentSize", title: "Content Size", type: .size,
                  value: .size(w: Double(size.width), h: Double(size.height)), isEditable: true),
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
        let separatorInset = tableView.separatorInset
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
        if let separatorColor = tableView.separatorColor {
            attrs.append(contentsOf: colorAttributes(id: "table.separatorColor", title: "Separator Color",
                                                     color: separatorColor))
        }
        attrs.append(.init(id: "table.separatorInset", title: "Separator Inset", type: .insets,
                           value: .insets(top: Double(separatorInset.top), left: Double(separatorInset.left),
                                          bottom: Double(separatorInset.bottom),
                                          right: Double(separatorInset.right)),
                           isEditable: true))
        return XPAttributeGroup(id: "tableView", title: "UITableView",
                                sections: [XPAttributeSection(id: "table.main", title: "", attributes: attrs)])
    }

    // MARK: - UICollectionView

    private static func collectionViewGroup(_ collectionView: UICollectionView) -> XPAttributeGroup {
        var attrs: [XPAttribute] = [
            .init(id: "cv.numberOfSections", title: "Sections", type: .int,
                  value: .int(collectionView.numberOfSections), isEditable: false),
        ]
        for section in 0 ..< min(collectionView.numberOfSections, 20) {
            attrs.append(.init(id: "cv.section\(section).items", title: "Section \(section) Items", type: .int,
                               value: .int(collectionView.numberOfItems(inSection: section)), isEditable: false))
        }
        attrs.append(contentsOf: flowLayoutAttributes(collectionView))
        return XPAttributeGroup(id: "collectionView", title: "UICollectionView",
                                sections: [XPAttributeSection(id: "cv.main", title: "", attributes: attrs)])
    }

    private static func flowLayoutAttributes(_ collectionView: UICollectionView) -> [XPAttribute] {
        guard let flow = collectionView.collectionViewLayout as? UICollectionViewFlowLayout else { return [] }

        let dirs = ["vertical", "horizontal"]
        return [
            .init(id: "cv.scrollDirection", title: "Scroll Direction", type: .enumeration,
                  value: .string(dirs[safe: flow.scrollDirection.rawValue] ?? "unknown"),
                  isEditable: false, enumCases: dirs),
            .init(id: "cv.itemSize", title: "Item Size", type: .size,
                  value: .size(w: Double(flow.itemSize.width), h: Double(flow.itemSize.height)),
                  isEditable: false),
            .init(id: "cv.minimumLineSpacing", title: "Line Spacing", type: .double,
                  value: .double(Double(flow.minimumLineSpacing)), isEditable: true),
            .init(id: "cv.minimumInteritemSpacing", title: "Interitem Spacing", type: .double,
                  value: .double(Double(flow.minimumInteritemSpacing)), isEditable: true),
        ]
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

    // MARK: - UIImageView

    private static func imageViewGroup(_ imageView: UIImageView) -> XPAttributeGroup {
        var attrs = [XPAttribute]()
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
}
