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
        case labels = 0
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
        if Section(rawValue: indexPath.section) == .buttons {
            print("[UIKit] Tapped button row \(indexPath.row)")
        }
    }
}
