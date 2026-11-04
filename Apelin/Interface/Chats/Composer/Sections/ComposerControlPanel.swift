// Lakr233's Inhouse Code, from FlowDown.
// I CAN DO WHAT THE FUCK I WANT.

import Combine
import UIKit

/// FlowDown's four import buttons, expanded inside the editor.
final class ComposerControlPanel: ComposerSectionView {
    let isPanelOpen = CurrentValueSubject<Bool, Never>(false)
    let cameraButton = ComposerGiantButton(title: String(localized: "Camera"), icon: "ComposerCamera")
    let photoButton = ComposerGiantButton(title: String(localized: "Photo"), icon: "ComposerPhoto")
    let fileButton = ComposerGiantButton(title: String(localized: "File"), icon: "ComposerFile")
    let webButton = ComposerGiantButton(title: String(localized: "Web"), icon: "ComposerWeb")
    private lazy var buttons = [cameraButton, photoButton, fileButton, webButton]

    override func initializeViews() {
        super.initializeViews()
        for button in buttons {
            addSubview(button)
        }
        isPanelOpen.removeDuplicates().sink { [weak self] open in
            guard let self else { return }
            accessibilityElementsHidden = !open
            // The buttons take the model row's place, so they hand over too.
            for button in buttons {
                button.handOver(visible: open)
            }
            heightPublisher.send(open ? buttonHeight : 0)
            setNeedsLayout()
        }.store(in: &cancellables)
    }

    private var buttonHeight: CGFloat {
        max(100, UIFont.preferredFont(forTextStyle: .footnote).lineHeight + 76)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let spacing: CGFloat = 10
        let width = (bounds.width - spacing * CGFloat(buttons.count - 1)) / CGFloat(buttons.count)
        for (index, button) in buttons.enumerated() {
            button.frame = directionalFrame(
                CGRect(x: CGFloat(index) * (width + spacing), y: 0, width: width, height: buttonHeight)
            )
        }
    }

    func toggle() {
        doWithAnimation { [self] in isPanelOpen.send(!isPanelOpen.value) }
    }

    /// Opened or folded from outside, as the row's plus does: one value, one
    /// place it is kept, so both controls agree on which way it is.
    func setPanelOpen(_ open: Bool) {
        guard isPanelOpen.value != open else { return }
        toggle()
    }

    func close() {
        guard isPanelOpen.value else { return }
        toggle()
    }
}
