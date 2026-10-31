// L10n.swift — English (default) and French strings.
//
// The language follows the system (French if the first preferred language is French,
// English otherwise) unless one is picked in the menu. The choice lives in the app's
// UserDefaults, which the reconciler reads too since it is the same binary.

import Foundation

enum Language: String, CaseIterable {
    case auto, en, fr

    static var setting: Language {
        get { Language(rawValue: UserDefaults.standard.string(forKey: "language") ?? "") ?? .auto }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "language") }
    }

    static var resolved: Language {
        if setting != .auto { return setting }
        return Locale.preferredLanguages.first?.hasPrefix("fr") == true ? .fr : .en
    }
}

/// Localized string for `key`, formatted with `args` (%@ for strings, %d for Int).
func t(_ key: String, _ args: CVarArg...) -> String {
    let table = Language.resolved == .fr ? fr : en
    return String(format: table[key] ?? en[key] ?? key, arguments: args)
}

private let en: [String: String] = [
    "status.active": "● Active — checks every 15 s",
    "status.paused": "◌ Paused — screens are not corrected",
    "status.stopped": "! Agent stopped",
    "status.unconfigured": "! Screens not set up yet",
    "status.unsupported": "! This version of macOS is not supported",
    "status.breaker": "⚠︎ %d corrections in 5 min, paused automatically",
    "status.last": "Last action: %@",
    "status.loop": "⚠︎ %d corrections in 5 min: is another tool fighting?",
    "tip.active": "Display Guard: active",
    "tip.paused": "Display Guard: paused",
    "tip.stopped": "Display Guard: agent stopped",
    "tip.unconfigured": "Display Guard: screens not set up yet",
    "tip.loop": "Display Guard: repeated corrections",
    "menu.pause": "Pause",
    "menu.resume": "Resume",
    "menu.start": "Start the agent",
    "menu.repair": "Repair now",
    "menu.identify": "Identify screens",
    "menu.top": "Top screen",
    "menu.hz": "240 Hz screen",
    "menu.auto": "Automatic",
    "menu.hzNote": "Only the screen on the fast port can run at 240 Hz",
    "menu.serialOff": "%@ · not connected",
    "menu.language": "Language",
    "menu.langAuto": "Automatic (system)",
    "menu.log": "Open log",
    "menu.configure": "Set up screens…",
    "menu.uninstall": "Uninstall Display Guard…",
    "menu.quit": "Quit Display Guard",
    "menu.busy": "Setting up screens…",
    "welcome.title": "Set up the screens",
    "welcome.text": """
        1. Connect the screens over DisplayPort.
        2. Arrange them in System Settings > Displays the way you want them.
        3. Click Set Up.

        Display Guard saves this arrangement and restores it every 15 seconds, along with the resolution and refresh rates. The screens may blink once.
        """,
    "button.setup": "Set Up",
    "button.later": "Later",
    "button.cancel": "Cancel",
    "button.uninstall": "Uninstall",
    "noscreen.title": "No 5120 × 1440 screen found",
    "noscreen.text": "Connect the screens over DisplayPort, then try again with “Set up screens…”.",
    "done.title": "Screens set up",
    "done.text": "Saved arrangement: %@.\nDisplay Guard now restores it every 15 seconds.",
    "done.top": "%@ at the top",
    "done.bottom": "%@ at the bottom",
    "error.install": "Display Guard could not install itself",
    "error.save": "Could not save the arrangement",
    "unsupported.title": "This version of macOS is not supported",
    "unsupported.text": "Display Guard relies on display functions that this version of macOS no longer provides. Look for a newer version of the app on GitHub.",
    "uninstall.title": "Uninstall Display Guard?",
    "uninstall.text": "The screens will no longer be watched. The saved arrangement, the log and the app go to the Trash.",
    "identify.top": "Top",
    "identify.bottom": "Bottom",
    "identify.builtin": "Built-in display",
    "identify.unmanaged": "Not managed",
    "identify.primary": "Chosen for 240 Hz",
    "identify.capable": "On the fast port: can run at 240 Hz",
    "notify.title": "Screens: loop detected",
    "notify.text": "%d corrections in 5 min, paused. Open the Display Guard menu to resume.",
]

private let fr: [String: String] = [
    "status.active": "● Actif — vérifie toutes les 15 s",
    "status.paused": "◌ En pause — les écrans ne sont plus corrigés",
    "status.stopped": "! Agent arrêté",
    "status.unconfigured": "! Écrans pas encore configurés",
    "status.unsupported": "! Cette version de macOS n'est pas prise en charge",
    "status.breaker": "⚠︎ %d corrections en 5 min, pause automatique",
    "status.last": "Dernière action : %@",
    "status.loop": "⚠︎ %d corrections en 5 min : un autre outil se bat ?",
    "tip.active": "Display Guard : actif",
    "tip.paused": "Display Guard : en pause",
    "tip.stopped": "Display Guard : agent arrêté",
    "tip.unconfigured": "Display Guard : écrans pas encore configurés",
    "tip.loop": "Display Guard : corrections répétées",
    "menu.pause": "Mettre en pause",
    "menu.resume": "Reprendre",
    "menu.start": "Démarrer l'agent",
    "menu.repair": "Réparer maintenant",
    "menu.identify": "Identifier les écrans",
    "menu.top": "Écran du haut",
    "menu.hz": "Écran à 240 Hz",
    "menu.auto": "Automatique",
    "menu.hzNote": "Seul l'écran branché sur le port rapide peut avoir 240 Hz",
    "menu.serialOff": "%@ · non branché",
    "menu.language": "Langue",
    "menu.langAuto": "Automatique (système)",
    "menu.log": "Ouvrir le journal",
    "menu.configure": "Configurer les écrans…",
    "menu.uninstall": "Désinstaller Display Guard…",
    "menu.quit": "Quitter Display Guard",
    "menu.busy": "Configuration des écrans…",
    "welcome.title": "Configurer les écrans",
    "welcome.text": """
        1. Branche les écrans en DisplayPort.
        2. Dispose-les dans Réglages Système > Moniteurs comme tu les veux.
        3. Clique sur Configurer.

        Display Guard enregistre cette disposition et la rétablit toutes les 15 secondes, avec la résolution et les fréquences. Les écrans peuvent clignoter une fois.
        """,
    "button.setup": "Configurer",
    "button.later": "Plus tard",
    "button.cancel": "Annuler",
    "button.uninstall": "Désinstaller",
    "noscreen.title": "Aucun écran 5120 × 1440 détecté",
    "noscreen.text": "Branche les écrans en DisplayPort, puis réessaie avec « Configurer les écrans… ».",
    "done.title": "Écrans configurés",
    "done.text": "Disposition enregistrée : %@.\nDisplay Guard la rétablit maintenant toutes les 15 secondes.",
    "done.top": "%@ en haut",
    "done.bottom": "%@ en bas",
    "error.install": "Display Guard n'a pas pu s'installer",
    "error.save": "Impossible d'enregistrer la disposition",
    "unsupported.title": "Cette version de macOS n'est pas prise en charge",
    "unsupported.text": "Display Guard utilise des fonctions d'affichage que cette version de macOS ne fournit plus. Cherche une version plus récente de l'app sur GitHub.",
    "uninstall.title": "Désinstaller Display Guard ?",
    "uninstall.text": "Les écrans ne seront plus surveillés. La disposition enregistrée, le journal et l'app partent à la corbeille.",
    "identify.top": "En haut",
    "identify.bottom": "En bas",
    "identify.builtin": "Écran intégré",
    "identify.unmanaged": "Non géré",
    "identify.primary": "Choisi pour 240 Hz",
    "identify.capable": "Sur le port rapide : peut afficher 240 Hz",
    "notify.title": "Écrans : boucle détectée",
    "notify.text": "%d corrections en 5 min, pause automatique. Ouvre le menu Display Guard pour reprendre.",
]
