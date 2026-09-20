import Foundation

/// Only quota-panel text crosses the WebView boundary. Conversation and notebook
/// content is never needed to measure a subscription.
enum GoogleUsagePages {
    static let sites: [WebSessionProvider.Site] = [
        site(id: "gemini-chat", name: "Gemini chat", url: "https://gemini.google.com/usage", kind: "quota"),
        site(id: "notebooklm", name: "NotebookLM", url: "https://notebook.google.com/", kind: "notebook"),
        site(id: "google-flow", name: "Google Flow", url: "https://labs.google/fx/tools/flow", kind: "flow")
    ]

    private static func site(id: String, name: String, url: String, kind: String) -> WebSessionProvider.Site {
        let storeIDs = ["gemini-chat": "F7E2B908-5B1A-476B-B23C-5F8F083CB101",
                        "notebooklm": "F7E2B908-5B1A-476B-B23C-5F8F083CB102",
                        "google-flow": "F7E2B908-5B1A-476B-B23C-5F8F083CB103"]
        return WebSessionProvider.Site(id: id, displayName: name, glyph: .geminiSpark,
            origin: URL(string: url)!, script: script(kind: kind),
            authProbeScript: #"""
            const account = document.querySelector('a[href*="accounts.google.com/SignOutOptions"], [aria-label^="Google Account:"], [aria-label^="Cuenta de Google:"]');
            return JSON.stringify({authenticated: !!account});
            """#,
            reloadBeforeFetch: true,
            dataStoreIdentifier: UUID(uuidString: storeIDs[id]!),
            managePath: "",
            parse: { body in
                guard let data = body.data(using: .utf8),
                      let text = (try? JSONSerialization.jsonObject(with: data) as? [String: String])?["text"]
                else { throw UsageProviderError.badResponse(status: 0) }
                if kind == "flow" { return try parseCredits(text) }
                return try parseQuota(text)
            })
    }

    /// Labels checked against the current English help and live Spanish pages.
    /// Missing percentages stay unavailable: a message count is not a quota.
    static func parseQuota(_ text: String) throws -> [LimitWindow] {
        let current = #"(?i)(?:current\s+(?:usage|limit)|5[ -]?hour(?:\s+(?:usage|limit))?|uso\s+actual[^\n]*|límite\s+actual)"#
        let weekly = #"(?i)(?:weekly\s+(?:usage|limit)|límite\s+semanal|uso\s+semanal)"#
        let labels = [("current", "Current", current, 5.0 * 3600), ("weekly", "Weekly", weekly, 7.0 * 86400)]
        let ranges = labels.compactMap { item -> (String, String, Range<String.Index>, Double)? in
            guard let range = text.range(of: item.2, options: .regularExpression) else { return nil }
            return (item.0, item.1, range, item.3)
        }.sorted { $0.2.lowerBound < $1.2.lowerBound }
        var windows: [LimitWindow] = []
        for (index, row) in ranges.enumerated() {
            let end = index + 1 < ranges.count ? ranges[index + 1].2.lowerBound : text.endIndex
            let section = String(text[row.2.upperBound..<end].prefix(500))
            guard let match = matches(#"(?i)(\d+(?:[.,]\d+)?)\s*%\s*(used|remaining|left|usado|utilizado|restante|disponible)"#, in: section).first,
                  let percent = Double(match[1].replacingOccurrences(of: ",", with: ".")), (0...100).contains(percent)
            else { continue }
            let remaining = ["remaining", "left", "restante", "disponible"].contains(match[2].lowercased())
            let resets = matches(#"(?im)(?:resets?\b|se restablec(?:e|erá)\b)[^\n%]{0,75}"#, in: section).first?.first
            windows.append(LimitWindow(id: row.0, label: row.0 == "current" ? L10n.t("Current") : L10n.t("Weekly"),
                usedFraction: (remaining ? 100 - percent : percent) / 100,
                detail: resets?.trimmingCharacters(in: .whitespacesAndNewlines), duration: row.3))
        }
        guard !windows.isEmpty else {
            throw UsageProviderError.nothingMetered(L10n.t("Open Usage in the Google sign-in window. No readable quota yet."))
        }
        return windows
    }

    static func parseCredits(_ text: String) throws -> [LimitWindow] {
        let patterns = [
            #"(?i)([\d][\d,.\s]*)\s+(?:Google Flow\s+|AI\s+)?credits?(?:\s+(?:remaining|left))?\b"#,
            #"(?i)([\d][\d,.\s]*)\s+créditos?(?:\s+(?:de\s+)?(?:IA|Google Flow))?(?:\s+(?:restantes|disponibles))?\b"#,
            #"(?i)(?:remaining\s+(?:AI\s+|Google Flow\s+)?credits?|créditos?\s+(?:restantes|disponibles))\s*[:\n]?\s*([\d][\d,. ]*)"#
        ]
        let numbers = Set(patterns.flatMap { matches($0, in: text) }.compactMap { match -> Int? in
            guard match.count > 1 else { return nil }
            // Credit counters are integers. Reject ambiguous decimal notation.
            let normalized = match[1].trimmingCharacters(in: .whitespacesAndNewlines)
            guard normalized.range(of: #"^\d{1,3}(?:[,. ]\d{3})+$|^\d+$"#, options: .regularExpression) != nil else { return nil }
            return Int(normalized.filter(\.isNumber))
        })
        guard numbers.count == 1, let credits = numbers.first else {
            throw UsageProviderError.nothingMetered(L10n.t("Open your Flow profile to read the credit balance."))
        }
        return [LimitWindow(id: "credits", label: L10n.t("Credits"), remaining: credits)]
    }

    private static func matches(_ pattern: String, in text: String) -> [[String]] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let ns = text as NSString
        return regex.matches(in: text, range: NSRange(location: 0, length: ns.length)).map { match in
            (0..<match.numberOfRanges).map { match.range(at: $0).location == NSNotFound ? "" : ns.substring(with: match.range(at: $0)) }
        }
    }

    private static func script(kind: String) -> String {
        "const kind = '\(kind)';\n" + #"""
        const reply = (status, text = '') => JSON.stringify({status, body: JSON.stringify({text})});
        if (location.hostname === 'accounts.google.com') return reply(401);
        const wait = ms => new Promise(resolve => setTimeout(resolve, ms));
        const visible = e => !!(e && e.getClientRects().length);
        const label = e => (e.getAttribute('aria-label') || e.innerText || '').trim();
        const controls = () => Array.from(document.querySelectorAll('button, [role="button"], [role="menuitem"], a')).filter(visible);
        const click = re => { const el = controls().find(e => re.test(label(e))); if (!el) return false; el.click(); return true; };
        const usagePanel = () => {
            const dialogs = Array.from(document.querySelectorAll('[role="dialog"], dialog, mat-dialog-container')).filter(visible);
            const dialog = dialogs.find(e => /weekly|semanal/.test(e.innerText.toLowerCase()) && /%/.test(e.innerText));
            if (dialog) return dialog.innerText;
            if (kind === 'quota' && location.pathname === '/usage') {
                // Cut off the sidebar at the usage heading; never export recent chat titles.
                const text = document.body.innerText;
                const start = text.search(/(?:Usage limits|Límites de uso)/i);
                if (start >= 0) return text.slice(start);
            }
            return '';
        };
        await wait(1500);
        if (controls().some(e => /^(Sign in|Iniciar sesión|Acceder)$/i.test(label(e)))) return reply(401);
        if (kind === 'flow') {
            click(/^(Google Account:|Cuenta de Google:|Account menu|Profile|Perfil)/i);
            await wait(700);
            const panels = Array.from(document.querySelectorAll('[role="dialog"], [role="menu"], [data-radix-popper-content-wrapper]')).filter(visible);
            const panel = panels.find(e => /credits|créditos/i.test(e.innerText));
            if (!panel) return reply(200);
            // Keep only balance lines; exclude upsell packages and generation costs.
            const lines = panel.innerText.split('\n').map(s => s.trim()).filter(Boolean);
            const snippets = [];
            for (let i = 0; i < lines.length; i++) {
                if (/credits|créditos/i.test(lines[i]) && !/buy|purchase|comprar|upgrade|cost|coste|mes|month/i.test(lines[i])) {
                    snippets.push(lines.slice(Math.max(0, i - 1), i + 2).join('\n'));
                }
            }
            return reply(200, snippets.join('\n').slice(0, 2000));
        }
        let text = usagePanel();
        if (!text && kind === 'notebook') {
            click(/^(Settings|Ajustes|Configuración)$/i);
            await wait(500);
            click(/^(Usage|Show usage dialog|Mostrar cuadro de diálogo de uso|Uso)$/i);
        }
        for (let i = 0; i < 6 && !text; i++) { await wait(500); text = usagePanel(); }
        return reply(200, text.slice(0, 4000));
        """#
    }
}
