import UIKit

class UIKitDemoViewController: UITableViewController {

    private let slider = UISlider()
    private let toggle = UISwitch()
    private let segmented = UISegmentedControl(items: ["First", "Second", "Third"])
    private let textField = UITextField()
    private let progressView = UIProgressView(progressViewStyle: .default)

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "UIKit Demo"
        view.backgroundColor = .systemGroupedBackground
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "cell")

        slider.minimumValue = 0
        slider.maximumValue = 100
        slider.value = 50
        slider.accessibilityIdentifier = "demoSlider"

        toggle.isOn = true
        toggle.accessibilityIdentifier = "demoToggle"

        segmented.selectedSegmentIndex = 0
        segmented.accessibilityIdentifier = "demoSegmented"

        textField.placeholder = "Type something here..."
        textField.borderStyle = .roundedRect
        textField.accessibilityIdentifier = "demoTextField"

        progressView.progress = 0.65
        progressView.accessibilityIdentifier = "demoProgress"
    }

    // MARK: - Sections

    enum Section: Int, CaseIterable {
        case navigation = 0
        case labels
        case buttons
        case controls
        case inputs
        case images
    }

    override func numberOfSections(in tableView: UITableView) -> Int {
        Section.allCases.count
    }

    override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        switch Section(rawValue: section) {
        case .navigation: return "Navigation"
        case .labels: return "Labels"
        case .buttons: return "Buttons"
        case .controls: return "Controls"
        case .inputs: return "Inputs"
        case .images: return "Images"
        case .none: return nil
        }
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        switch Section(rawValue: section) {
        case .navigation: return 2
        case .labels: return 3
        case .buttons: return 3
        case .controls: return 3
        case .inputs: return 2
        case .images: return 2
        case .none: return 0
        }
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "cell", for: indexPath)
        cell.accessoryView = nil
        cell.selectionStyle = .none

        var config = cell.defaultContentConfiguration()

        switch Section(rawValue: indexPath.section) {
        case .navigation:
            cell.selectionStyle = .default
            cell.accessoryType = indexPath.row == 0 ? .disclosureIndicator : .none
            switch indexPath.row {
            case 0:
                config.text = "Push Detail Screen"
                config.image = UIImage(systemName: "arrow.right")
                config.imageProperties.tintColor = .systemGreen
                cell.accessibilityIdentifier = "nav_push"
            case 1:
                config.text = "Present Modal"
                config.image = UIImage(systemName: "rectangle.portrait.on.rectangle.portrait")
                config.imageProperties.tintColor = .systemBlue
                cell.accessibilityIdentifier = "nav_present"
            default: break
            }

        case .labels:
            switch indexPath.row {
            case 0:
                config.text = "Hello World"
                config.secondaryText = "A simple UILabel"
                cell.accessibilityIdentifier = "label_hello"
            case 1:
                config.text = "Multi-line Label"
                config.secondaryText = "This is a longer description that demonstrates how multi-line text looks in a UIKit table view cell"
                config.secondaryTextProperties.numberOfLines = 0
                cell.accessibilityIdentifier = "label_multiline"
            case 2:
                config.text = "Styled Label"
                config.textProperties.color = .systemBlue
                config.textProperties.font = .boldSystemFont(ofSize: 18)
                config.secondaryText = "Bold, Blue, 18pt"
                cell.accessibilityIdentifier = "label_styled"
            default: break
            }

        case .buttons:
            switch indexPath.row {
            case 0:
                config.text = "Default Button"
                config.image = UIImage(systemName: "hand.tap")
                cell.accessibilityIdentifier = "button_default"
            case 1:
                config.text = "Destructive Action"
                config.textProperties.color = .systemRed
                config.image = UIImage(systemName: "trash")
                config.imageProperties.tintColor = .systemRed
                cell.accessibilityIdentifier = "button_destructive"
            case 2:
                config.text = "Action with Badge"
                config.image = UIImage(systemName: "bell.badge")
                config.imageProperties.tintColor = .systemOrange
                cell.accessibilityIdentifier = "button_badge"
            default: break
            }

        case .controls:
            switch indexPath.row {
            case 0:
                config.text = "UISwitch"
                cell.accessoryView = toggle
                cell.accessibilityIdentifier = "control_switch"
            case 1:
                config.text = "UISlider"
                let container = UIView(frame: CGRect(x: 0, y: 0, width: 150, height: 30))
                slider.frame = container.bounds
                slider.autoresizingMask = [.flexibleWidth, .flexibleHeight]
                container.addSubview(slider)
                cell.accessoryView = container
                cell.accessibilityIdentifier = "control_slider"
            case 2:
                config.text = "Progress"
                let container = UIView(frame: CGRect(x: 0, y: 0, width: 150, height: 4))
                progressView.frame = container.bounds
                progressView.autoresizingMask = [.flexibleWidth]
                container.addSubview(progressView)
                cell.accessoryView = container
                cell.accessibilityIdentifier = "control_progress"
            default: break
            }

        case .inputs:
            switch indexPath.row {
            case 0:
                config.text = "TextField"
                let container = UIView(frame: CGRect(x: 0, y: 0, width: 200, height: 34))
                textField.frame = container.bounds
                textField.autoresizingMask = [.flexibleWidth, .flexibleHeight]
                container.addSubview(textField)
                cell.accessoryView = container
                cell.accessibilityIdentifier = "input_textfield"
            case 1:
                config.text = "Segmented"
                let container = UIView(frame: CGRect(x: 0, y: 0, width: 200, height: 32))
                segmented.frame = container.bounds
                segmented.autoresizingMask = [.flexibleWidth, .flexibleHeight]
                container.addSubview(segmented)
                cell.accessoryView = container
                cell.accessibilityIdentifier = "input_segmented"
            default: break
            }

        case .images:
            switch indexPath.row {
            case 0:
                config.text = "SF Symbol"
                config.image = UIImage(systemName: "star.fill")
                config.imageProperties.tintColor = .systemYellow
                cell.accessibilityIdentifier = "image_sf"
            case 1:
                config.text = "System Image"
                config.image = UIImage(systemName: "photo.on.rectangle.angled")
                config.imageProperties.tintColor = .systemTeal
                cell.accessibilityIdentifier = "image_system"
            default: break
            }

        case .none:
            break
        }

        cell.contentConfiguration = config
        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        switch Section(rawValue: indexPath.section) {
        case .navigation:
            if indexPath.row == 0 {
                let detail = UIKitDetailViewController(depth: 1)
                navigationController?.pushViewController(detail, animated: true)
            } else {
                let modal = UIKitModalViewController()
                modal.modalPresentationStyle = .formSheet
                present(modal, animated: true)
            }
        case .buttons:
            print("[UIKit] Tapped button row \(indexPath.row)")
        default:
            break
        }
    }
}

// MARK: - UIKit Detail (pushable)

class UIKitDetailViewController: UITableViewController {
    private let depth: Int

    init(depth: Int) {
        self.depth = depth
        super.init(style: .insetGrouped)
        title = "UIKit Detail \(depth)"
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

    override func numberOfSections(in tableView: UITableView) -> Int { 2 }

    override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        section == 0 ? "Info" : "Navigate"
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        section == 0 ? 1 : 2
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = UITableViewCell(style: .subtitle, reuseIdentifier: nil)
        if indexPath.section == 0 {
            cell.textLabel?.text = "Detail screen at depth \(depth)"
            cell.selectionStyle = .none
        } else if indexPath.row == 0 {
            cell.textLabel?.text = "Push another level"
            cell.accessoryType = .disclosureIndicator
        } else {
            cell.textLabel?.text = "Present modal from here"
            cell.textLabel?.textColor = .systemBlue
        }
        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        if indexPath.section == 1 {
            if indexPath.row == 0 {
                let next = UIKitDetailViewController(depth: depth + 1)
                navigationController?.pushViewController(next, animated: true)
            } else {
                let modal = UIKitModalViewController()
                modal.modalPresentationStyle = .formSheet
                present(modal, animated: true)
            }
        }
    }
}

// MARK: - UIKit Modal (presentable)

class UIKitModalViewController: UIViewController {
    override func viewDidLoad() {
        super.viewDidLoad()
        title = "UIKit Modal"
        view.backgroundColor = .systemIndigo

        let label = UILabel()
        label.text = "UIKit Modal"
        label.font = .boldSystemFont(ofSize: 24)
        label.textColor = .white
        label.textAlignment = .center

        let closeButton = UIButton(type: .system)
        closeButton.setTitle("Dismiss", for: .normal)
        closeButton.setTitleColor(.white, for: .normal)
        closeButton.titleLabel?.font = .boldSystemFont(ofSize: 17)
        closeButton.addTarget(self, action: #selector(close), for: .touchUpInside)

        let stack = UIStackView(arrangedSubviews: [label, closeButton])
        stack.axis = .vertical
        stack.spacing = 20
        stack.alignment = .center
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: view.centerYAnchor),
        ])
    }

    @objc private func close() { dismiss(animated: true) }
}
