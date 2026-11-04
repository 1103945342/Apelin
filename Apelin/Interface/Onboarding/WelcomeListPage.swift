// Copyright (c) 2026 OwnGoal Studio. MIT; see LICENSE beside this file.
// Layout copied from Irisin/Interface/Onboarding/WelcomeRepositoriesController.swift.
import SnapKit
import UIKit

/// The original repository page's table over its fixed action bar. Subclasses
/// supply only the rows and the action for this step of Apelin's welcome.
class WelcomeListPage: UIViewController, UITableViewDelegate {
    let tableView = FirstFillTableView(frame: .zero, style: .insetGrouped)
    let flow: WelcomeFlow
    private var action: (() -> Void)?
    var secondaryTitle: String? {
        nil
    }

    func secondaryAction() {}
    private(set) lazy var actionBar = WelcomeActionBar(
        title: String(localized: "Next"),
        secondaryTitle: secondaryTitle,
        action: { [weak self] in self?.action?() },
        secondaryAction: { [weak self] in self?.secondaryAction() },
    )

    init(flow: WelcomeFlow) {
        self.flow = flow
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("Use init(flow:)")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = WelcomeStyle.groupedBackground
        view.addSubview(tableView)
        view.addSubview(actionBar)
        tableView.snp.makeConstraints {
            $0.top.leading.trailing.equalToSuperview()
            $0.bottom.equalTo(actionBar.snp.top)
        }
        actionBar.snp.makeConstraints { $0.leading.trailing.bottom.equalToSuperview() }
        tableView.backgroundColor = WelcomeStyle.groupedBackground
        tableView.delegate = self
    }

    func next(_ action: @escaping () -> Void) {
        self.action = action
    }

    func text(_ configuration: UIListContentConfiguration, _ text: String) -> UIView {
        var configuration = configuration
        configuration.text = text
        let view = UITableViewHeaderFooterView()
        view.contentConfiguration = configuration
        return view
    }
}
