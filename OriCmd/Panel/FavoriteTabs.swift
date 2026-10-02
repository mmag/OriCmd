import AppKit

/// Total Commander's favorite tabs: the tabs of both panels saved under a name,
/// shown again from the Commands → Favorite Tabs menu.
struct FavoriteTabs {
    var name: String
    var left: FilePanelController.SavedTabs
    var right: FilePanelController.SavedTabs

    private static let key = "FavoriteTabs"

    static var saved: [FavoriteTabs] {
        get {
            (AppDefaults.store.array(forKey: key) as? [[String: Any]] ?? []).compactMap { entry in
                guard let name = entry["name"] as? String else { return nil }
                return FavoriteTabs(name: name, left: .init(entry["left"] as? [String: Any]),
                                    right: .init(entry["right"] as? [String: Any]))
            }
        }
        set {
            AppDefaults.store.set(newValue.map { ["name": $0.name, "left": $0.left.dictionary, "right": $0.right.dictionary] },
                                  forKey: key)
        }
    }
}

/// The Favorite Tabs submenu, made anew each time it opens. Its items go to the
/// main view controller through the responder chain.
final class FavoriteTabsMenu: NSObject, NSMenuDelegate {
    static let shared = FavoriteTabsMenu()

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let favorites = FavoriteTabs.saved
        for favorite in favorites {
            let item = NSMenuItem(title: favorite.name, action: #selector(MainViewController.showFavoriteTabs(_:)),
                                  keyEquivalent: "")
            item.representedObject = favorite.name
            menu.addItem(item)
        }
        if !favorites.isEmpty { menu.addItem(.separator()) }
        menu.addItem(NSMenuItem(title: String(localized: "Save Current Tabs…"),
                                action: #selector(MainViewController.saveFavoriteTabs(_:)), keyEquivalent: ""))
        guard !favorites.isEmpty else { return }
        let remove = NSMenu(title: String(localized: "Remove"))
        for favorite in favorites {
            let item = NSMenuItem(title: favorite.name, action: #selector(MainViewController.removeFavoriteTabs(_:)),
                                  keyEquivalent: "")
            item.representedObject = favorite.name
            remove.addItem(item)
        }
        let container = NSMenuItem(title: remove.title, action: nil, keyEquivalent: "")
        container.submenu = remove
        menu.addItem(container)
    }
}
