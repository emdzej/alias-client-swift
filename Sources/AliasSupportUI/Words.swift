import AliasSupport
import Foundation

/// The words the views show, in a language they have (`AliasLabels.languages`: English, Polish), English
/// for any other. Yours to change: take the set for a language and set what you'd say otherwise, or all
/// of it, for a language not here.
///
///     var words = AliasLabels(language: "pl")
///     words.reportTitle = "Zgłoś błąd w grze"
///     AliasSupportView(client: alias, labels: words)
public struct AliasLabels: Sendable {
    /// The languages built in.
    public static let languages = ["en", "pl"]

    /// The language these are in ("en", "pl"): the one asked for, if built in, else "en". Plurals follow it.
    public var language: String
    public var redactTitle = "Black out what you don't want to send"
    public var box = "Box"
    public var brush = "Brush"
    public var undo = "Undo"
    public var clear = "Clear"
    public var cancel = "Cancel"
    public var done = "Done"
    public var reportTitle = "Report a problem"
    public var notePrompt = "What happened?"
    public var screenshot = "Screenshot"
    public var includeScreenshot = "Send the screenshot"
    public var blackOut = "Black out parts"
    public var whatsSent = "What's sent with it"
    public var nothingElse = "Nothing else."
    public var contactTitle = "A way to reach you (optional)"
    public var contactPlaceholder = "you@example.com"
    public var agree = "I agree"
    public var send = "Send"
    public var sending = "Sending…"
    public var sent = "Sent. You'll see support's answer here."
    public var yourReports = "Your reports"
    public var noReports = "No reports yet."
    public var replyPrompt = "Write a reply"
    public var talkLive = "Talk live"
    public var liveAsked = "Asked: someone will join when they can."
    public var liveNow = "Live: support is here."
    public var typing = "Support is typing…"
    public var agent = "Answered by an agent, not a person"
    public var support = "Support"
    public var you = "You"
    public var statusWords: [String: String] = ["open": "Open", "in_progress": "In progress", "waiting": "Waiting on you",
                                                 "resolved": "Resolved", "closed": "Closed"]
    /// "{n} new answers", by the language's plural forms (English: one, other; Polish: one, few, many).
    public var newAnswerForms = ["{n} new answer", "{n} new answers"]

    /// The words for a language ("pl", "pl-PL", "pl_PL"); default: the app's (`AliasClient.defaultLanguage`).
    public init(language: String? = AliasClient.defaultLanguage) {
        self.language = AliasLabels.builtIn(language)
        if self.language == "pl" { polish() }
    }

    /// The built-in language for a tag: its first part, if built in, else "en".
    public static func builtIn(_ tag: String?) -> String {
        let l = (tag ?? "").lowercased().split(whereSeparator: { $0 == "-" || $0 == "_" }).first.map(String.init) ?? ""
        return languages.contains(l) ? l : "en"
    }

    /// Which of a language's plural forms n takes. English: 0 one, 1 other. Polish: 0 one (1), 1 few (2-4,
    /// 22-24, not 12-14), 2 many (the rest).
    public static func pluralForm(_ n: Int, language: String) -> Int {
        let n = abs(n)
        switch builtIn(language) {
        case "pl":
            if n == 1 { return 0 }
            let (d, h) = (n % 10, n % 100)
            return (2...4).contains(d) && !(12...14).contains(h) ? 1 : 2
        default: return n == 1 ? 0 : 1
        }
    }

    /// The form for n of forms (one, other; Polish: one, few, many), {n} replaced by n.
    public func plural(_ n: Int, _ forms: [String]) -> String {
        guard !forms.isEmpty else { return String(n) }
        let f = forms[min(Self.pluralForm(n, language: language), forms.count - 1)]
        return f.replacingOccurrences(of: "{n}", with: String(n))
    }

    /// "3 new answers", for a notice of support's answers.
    public func newAnswers(_ n: Int) -> String { plural(n, newAnswerForms) }

    private mutating func polish() {
        redactTitle = "Ukryj to, czego nie powinno być widać"
        box = "Prostokąt"
        brush = "Pędzel"
        undo = "Cofnij"
        clear = "Wyczyść"
        cancel = "Anuluj"
        done = "Gotowe"
        reportTitle = "Zgłoś problem"
        notePrompt = "Co się stało?"
        screenshot = "Zrzut ekranu"
        includeScreenshot = "Wyślij zrzut ekranu"
        blackOut = "Zakryj fragmenty"
        whatsSent = "Wysyłane razem z nim"
        nothingElse = "Nic więcej."
        contactTitle = "Jak się z Tobą skontaktować (opcjonalnie)"
        contactPlaceholder = "adres@example.com"
        agree = "Zgadzam się"
        send = "Wyślij"
        sending = "Wysyłanie…"
        sent = "Wysłane. Odpowiedź wsparcia pojawi się tutaj."
        yourReports = "Twoje zgłoszenia"
        noReports = "Nie ma jeszcze zgłoszeń."
        replyPrompt = "Napisz odpowiedź"
        talkLive = "Porozmawiaj na żywo"
        liveAsked = "Poproszono o rozmowę na żywo. Ktoś ze wsparcia dołączy, gdy tylko będzie to możliwe."
        liveNow = "Na żywo: wsparcie jest tutaj."
        typing = "Wsparcie pisze…"
        agent = "Odpowiedź automatyczna, nie od człowieka"
        support = "Wsparcie"
        you = "Ty"
        statusWords = ["open": "Otwarte", "in_progress": "W toku", "waiting": "Czeka na Ciebie",
                       "resolved": "Rozwiązane", "closed": "Zamknięte"]
        newAnswerForms = ["{n} nowa odpowiedź", "{n} nowe odpowiedzi", "{n} nowych odpowiedzi"]
    }
}
