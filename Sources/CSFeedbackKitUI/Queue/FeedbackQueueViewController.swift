import UIKit
import CSFeedbackKit

/// Debug screen for the on-device queue: notes waiting, failed, or recently sent, with
/// per-destination status. Tap a note to resend, copy, or delete it.
final class FeedbackQueueViewController: UITableViewController {

    private struct Section {
        let title: String
        let entries: [FeedbackQueueEntry]
    }

    private var sections: [Section] = []
    private var busy: Set<String> = []
    private let emptyLabel = UILabel()

    init() {
        super.init(style: .insetGrouped)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Feedback queue"
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "entry")
        refreshControl = UIRefreshControl()
        refreshControl?.addTarget(self, action: #selector(reload), for: .valueChanged)

        emptyLabel.text = "No notes on this device."
        emptyLabel.textColor = .secondaryLabel
        emptyLabel.textAlignment = .center
        emptyLabel.font = .preferredFont(forTextStyle: .body)

        if navigationController?.viewControllers.first === self, presentingViewController != nil {
            navigationItem.leftBarButtonItem = UIBarButtonItem(
                barButtonSystemItem: .done,
                target: self,
                action: #selector(close)
            )
        }
        reload()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        reload()
    }

    // MARK: Data

    @objc private func reload() {
        Task {
            let entries = await Feedback.queue()
            apply(entries)
            refreshControl?.endRefreshing()
        }
    }

    private func apply(_ entries: [FeedbackQueueEntry]) {
        let failed = entries.filter { $0.state == .failed }
        let waiting = entries.filter { $0.state == .waiting }
        let sent = entries.filter { $0.state == .sent }
        sections = [
            Section(title: "Failed", entries: failed),
            Section(title: "Waiting", entries: waiting),
            Section(title: "Sent (last 3 days)", entries: sent),
        ].filter { !$0.entries.isEmpty }

        tableView.backgroundView = sections.isEmpty ? emptyLabel : nil
        navigationItem.rightBarButtonItem = failed.isEmpty ? nil : UIBarButtonItem(
            title: "Resend failed",
            style: .plain,
            target: self,
            action: #selector(resendAllFailed)
        )
        tableView.reloadData()
    }

    private func entry(at indexPath: IndexPath) -> FeedbackQueueEntry {
        sections[indexPath.section].entries[indexPath.row]
    }

    // MARK: Table

    override func numberOfSections(in tableView: UITableView) -> Int {
        sections.count
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        sections[section].entries.count
    }

    override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        sections[section].title
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "entry", for: indexPath)
        let entry = entry(at: indexPath)

        var content = UIListContentConfiguration.subtitleCell()
        let firstLine = entry.payload.note.split(separator: "\n", omittingEmptySubsequences: true).first.map(String.init) ?? "(empty)"
        content.text = firstLine
        content.textProperties.numberOfLines = 2
        content.secondaryText = detailText(for: entry)
        content.secondaryTextProperties.color = .secondaryLabel
        content.secondaryTextProperties.numberOfLines = 0
        content.textToSecondaryTextVerticalPadding = 4

        switch entry.state {
        case .failed:
            content.image = UIImage(systemName: "exclamationmark.triangle.fill")
            content.imageProperties.tintColor = .systemOrange
        case .waiting:
            content.image = UIImage(systemName: "clock")
            content.imageProperties.tintColor = .secondaryLabel
        case .sent:
            content.image = UIImage(systemName: "checkmark.circle.fill")
            content.imageProperties.tintColor = .systemGreen
        }
        cell.contentConfiguration = content

        if busy.contains(entry.id) {
            let spinner = UIActivityIndicatorView(style: .medium)
            spinner.startAnimating()
            cell.accessoryView = spinner
        } else {
            cell.accessoryView = nil
            cell.accessoryType = .none
        }
        return cell
    }

    private func detailText(for entry: FeedbackQueueEntry) -> String {
        var parts: [String] = [Self.dateFormatter.string(from: entry.savedAt)]
        if let screen = entry.payload.source?.title ?? entry.payload.source?.screen {
            parts.append(screen)
        }
        if !entry.payload.tags.isEmpty {
            parts.append(entry.payload.tags.map(\.label).joined(separator: " "))
        }
        let header = parts.joined(separator: " · ")
        let destinations = entry.deliveries.map { status -> String in
            switch status.state {
            case .delivered:
                return "✓ \(status.destinationId)"
            case .pending:
                let error = status.lastError.map { ", \(Self.short($0))" } ?? ""
                return "… \(status.destinationId) (try \(status.attempts + 1)\(error))"
            case .failed:
                return "✗ \(status.destinationId): \(Self.short(status.lastError ?? "failed"))"
            }
        }
        return ([header] + destinations).joined(separator: "\n")
    }

    private static func short(_ text: String) -> String {
        let oneLine = text.replacingOccurrences(of: "\n", with: " ")
        return oneLine.count > 60 ? String(oneLine.prefix(60)) + "…" : oneLine
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        formatter.doesRelativeDateFormatting = true
        return formatter
    }()

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        let entry = entry(at: indexPath)
        guard !busy.contains(entry.id) else { return }

        let sheet = UIAlertController(title: nil, message: nil, preferredStyle: .actionSheet)
        if entry.state == .failed || entry.state == .waiting {
            sheet.addAction(UIAlertAction(title: "Resend now", style: .default) { [weak self] _ in
                self?.resend(entry.id, includingDelivered: false)
            })
        }
        sheet.addAction(UIAlertAction(title: "Resend to every destination", style: .default) { [weak self] _ in
            self?.resend(entry.id, includingDelivered: true)
        })
        sheet.addAction(UIAlertAction(title: "Copy note", style: .default) { [weak self] _ in
            UIPasteboard.general.string = entry.payload.note
            self?.toast("Copied", kind: .success)
        })
        sheet.addAction(UIAlertAction(title: "Copy JSON", style: .default) { [weak self] _ in
            UIPasteboard.general.string = entry.jsonWithoutAttachmentData()
            self?.toast("Copied", kind: .success)
        })
        sheet.addAction(UIAlertAction(title: "Delete", style: .destructive) { [weak self] _ in
            self?.delete(entry.id)
        })
        sheet.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        if let popover = sheet.popoverPresentationController, let cell = tableView.cellForRow(at: indexPath) {
            popover.sourceView = cell
            popover.sourceRect = cell.bounds
        }
        present(sheet, animated: true)
    }

    override func tableView(
        _ tableView: UITableView,
        trailingSwipeActionsConfigurationForRowAt indexPath: IndexPath
    ) -> UISwipeActionsConfiguration? {
        let entry = entry(at: indexPath)
        let delete = UIContextualAction(style: .destructive, title: "Delete") { [weak self] _, _, done in
            self?.delete(entry.id)
            done(true)
        }
        return UISwipeActionsConfiguration(actions: [delete])
    }

    // MARK: Actions

    private func resend(_ id: String, includingDelivered: Bool) {
        busy.insert(id)
        tableView.reloadData()
        Task {
            let statuses = await Feedback.resend(id, includingDelivered: includingDelivered)
            busy.remove(id)
            if statuses.isEmpty {
                toast("Feedback isn’t set up in this build", kind: .error)
            } else if statuses.allSatisfy({ $0.state == .delivered }) {
                toast("Delivered", kind: .success)
            } else if let failure = statuses.first(where: { $0.state != .delivered }) {
                let verb = failure.state == .pending ? "Still waiting" : "Failed"
                toast("\(verb): \(failure.destinationId) (\(Self.short(failure.lastError ?? "no response")))", kind: .error)
            }
            reload()
        }
    }

    @objc private func resendAllFailed() {
        let failed = sections.flatMap(\.entries).filter { $0.state == .failed }.map(\.id)
        guard !failed.isEmpty else { return }
        busy.formUnion(failed)
        tableView.reloadData()
        Task {
            var delivered = 0
            for id in failed {
                let statuses = await Feedback.resend(id)
                busy.remove(id)
                if !statuses.isEmpty, statuses.allSatisfy({ $0.state == .delivered }) { delivered += 1 }
            }
            toast("Delivered \(delivered) of \(failed.count)", kind: delivered == failed.count ? .success : .error)
            reload()
        }
    }

    private func delete(_ id: String) {
        Task {
            await Feedback.discard(id)
            reload()
        }
    }

    private func toast(_ text: String, kind: FeedbackToast.Kind) {
        Feedback.appearance.showToast(self, FeedbackToast(text: text, kind: kind))
    }

    @objc private func close() {
        dismiss(animated: true)
    }
}

@MainActor
extension Feedback {
    /// The queue screen, to push onto your own navigation stack (e.g. a debug menu).
    public static func makeQueueViewController() -> UIViewController {
        FeedbackQueueViewController()
    }

    /// Presents the queue screen in its own sheet.
    public static func presentQueue(from presenter: UIViewController) {
        let navigation = UINavigationController(rootViewController: FeedbackQueueViewController())
        ViewControllerTree.presentationAnchor(for: presenter).present(navigation, animated: true)
    }
}
