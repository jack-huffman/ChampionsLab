//  GuidedBuilderView.swift
//  Choose a Mega, then talk it through.

import SwiftUI

struct GuidedBuilderView: View {
    @EnvironmentObject private var store: Store

    @Binding var seedID: String
    @Binding var format: String
    /// Handed the finished brief when the interview ends.
    let onBuild: (BuildBrief) -> Void

    @State private var stage: Stage
    @State private var query = ""
    @State private var answers: [String: String] = [:]
    /// Worked out once per Pokémon. Both of these run the whole field through
    /// the damage calculator, and they were being recomputed on every redraw.
    @State private var cachedBriefing: BuildInterview.Briefing?
    @State private var cachedQuestions: [BuildInterview.Question] = []
    @State private var cachedFor = ""
    @State private var brief = BuildBrief()
    @State private var questionIndex = 0

    enum Stage { case choose, briefing, interview }

    init(seedID: Binding<String>, format: Binding<String>,
         initialStage: Stage = .choose, onBuild: @escaping (BuildBrief) -> Void) {
        _seedID = seedID
        _format = format
        _stage = State(initialValue: initialStage)
        self.onBuild = onBuild
    }

    private var seed: Form? { store.formsByID[seedID] }

    private func prepare() {
        guard let seed, cachedFor != seedID else { return }
        let interview = BuildInterview(store: store, seed: seed, format: format)
        cachedBriefing = interview.briefing()
        cachedQuestions = interview.questions()
        cachedFor = seedID
    }

    /// The cache where it has been filled, and a direct computation otherwise —
    /// ImageRenderer never fires onAppear, so the snapshot path needs a way in.
    private func interviewData(_ seed: Form)
        -> (briefing: BuildInterview.Briefing, questions: [BuildInterview.Question]) {
        if let cachedBriefing, !cachedQuestions.isEmpty, cachedFor == seedID {
            return (cachedBriefing, cachedQuestions)
        }
        let interview = BuildInterview(store: store, seed: seed, format: format)
        return (interview.briefing(), interview.questions())
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            switch stage {
            case .choose:
                chooser
            case .briefing:
                // The reading stages are capped: a question and four answers
                // stretched across a wide window is hard to read, and the
                // gallery is the only part that wants the whole width.
                if let seed { briefingPage(seed).frame(maxWidth: 820, alignment: .leading) }
            case .interview:
                if let seed { interviewPage(seed).frame(maxWidth: 820, alignment: .leading) }
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .padding(22)
        .onAppear(perform: prepare)
        .onChange(of: seedID) { _ in
            answers = [:]
            brief = BuildBrief()
            questionIndex = 0
            prepare()
        }
    }

    // MARK: - Choosing

    private var allMegas: [Form] {
        store.data.forms.filter(\.isMega).sorted { $0.formLabel < $1.formLabel }
    }
    private var filtered: [Form] {
        guard !query.isEmpty else { return allMegas }
        return allMegas.filter { $0.formLabel.localizedCaseInsensitiveContains(query) }
    }
    /// Wide enough for two full type chips. At 132 they truncated to "Dra…".
    private var columns: [GridItem] { [GridItem(.adaptive(minimum: 158), spacing: 12)] }

    private var chooser: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 5) {
                Text("What are you building around?")
                    .font(.system(size: 24, weight: .bold, design: .rounded))
                Text("Pick the Mega the team exists to use. Everything after this is worked out from it — what it loses to, what covers it, and how it moves first.")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if query.isEmpty {
                section("New in \(store.data.regulation.id)",
                        subtitle: "The Megas this regulation introduced.",
                        forms: store.newMegas)
                let zMegas = allMegas.filter(\.isZMega)
                if !zMegas.isEmpty {
                    section("Z Megas", subtitle: "From Legends: Z-A, and above every established speed benchmark.",
                            forms: zMegas)
                }
            }

            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    SectionHeader(title: query.isEmpty ? "Every Mega" : "Matches",
                                  subtitle: "\(filtered.count) of \(allMegas.count)")
                    Spacer()
                    TextField("Search", text: $query)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 200)
                }
                LazyVGrid(columns: columns, spacing: 12) {
                    ForEach(filtered) { form in
                        PokemonTile(form: form, side: 76, isSelected: seedID == form.id,
                                    caption: caption(for: form)) {
                            seedID = form.id
                            prepare()
                            stage = .briefing
                        }
                    }
                }
            }
        }
    }

    private func section(_ title: String, subtitle: String, forms: [Form]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(title: title, subtitle: subtitle)
            LazyVGrid(columns: columns, spacing: 12) {
                ForEach(forms) { form in
                    PokemonTile(form: form, side: 84, isSelected: seedID == form.id,
                                caption: caption(for: form)) {
                        seedID = form.id
                        stage = .briefing
                    }
                }
            }
        }
    }

    /// Measured usage where there is any, otherwise the number that matters most.
    private func caption(for form: Form) -> String {
        if let entry = store.data.usage.first(where: {
            ($0.name == form.formLabel || $0.name == form.name) && !$0.isProjected
        }) {
            return String(format: "%.1f%% used", entry.usage)
        }
        return "BST \(form.bst) · \(form.speed) Spe"
    }

    // MARK: - What the engine already knows

    private func briefingPage(_ seed: Form) -> some View {
        let brief = interviewData(seed).briefing
        return VStack(alignment: .leading, spacing: 16) {
            header(seed, step: "Before we start")

            Card(padding: 16) {
                VStack(alignment: .leading, spacing: 12) {
                    SectionHeader(title: "What it is",
                                  subtitle: "Run against every tracked threat before a single partner is chosen.")
                    HStack(alignment: .top, spacing: 22) {
                        figure(String(format: "%+.2f", brief.standing), "standing",
                               Palette.grade(Int((brief.standing + 1) * 50)))
                        figure("\(brief.beats.count)", "beats", Palette.good)
                        figure("\(brief.losesTo.count)", "loses to", Palette.bad)
                        figure("\(brief.outspeeds)/\(brief.fieldSize)", "outspeeds", Palette.accent)
                        figure(brief.bestMove, "best attack", Palette.dim)
                    }
                    if !brief.worstWeaknesses.isEmpty {
                        Divider()
                        VStack(alignment: .leading, spacing: 5) {
                            Text("WHAT HURTS IT")
                                .font(.system(size: 9, weight: .bold)).kerning(0.5)
                                .foregroundStyle(.tertiary)
                            ForEach(brief.worstWeaknesses, id: \.type) { weakness in
                                HStack(spacing: 7) {
                                    TypeIcon(type: weakness.type, side: 18)
                                    Text("\(weakness.type.rawValue) ×\(weakness.multiplier == 4 ? "4" : "2")")
                                        .font(.system(size: 12, weight: .medium))
                                    Text(String(format: "carried by %.0f%% of the field",
                                                weakness.fieldShare * 100))
                                        .font(.system(size: 11)).foregroundStyle(.secondary)
                                    Spacer()
                                }
                            }
                        }
                    }
                    if !brief.losesTo.isEmpty {
                        Text("Loses to " + brief.losesTo.joined(separator: ", ") + ".")
                            .font(.system(size: 11)).foregroundStyle(Palette.bad)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }

            HStack {
                Button("Choose someone else") { stage = .choose }
                Spacer()
                Button("Start") {
                    brief0()
                    stage = .interview
                }
                .keyboardShortcut(.defaultAction)
            }
        }
    }

    private func figure(_ value: String, _ label: String, _ colour: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value)
                .font(.system(size: 17, weight: .bold, design: .rounded))
                .monospacedDigit().foregroundStyle(colour)
                .lineLimit(1)
            Text(label.uppercased())
                .font(.system(size: 9, weight: .semibold)).kerning(0.4)
                .foregroundStyle(.tertiary)
        }
    }

    private func brief0() {
        brief = BuildBrief()
        answers = [:]
        questionIndex = 0
    }

    // MARK: - The interview

    private func interviewPage(_ seed: Form) -> some View {
        let questions = interviewData(seed).questions
        guard !questions.isEmpty else { return AnyView(EmptyView()) }
        let question = questions[min(questionIndex, questions.count - 1)]
        let answered = answers[question.id] != nil

        return AnyView(VStack(alignment: .leading, spacing: 16) {
            header(seed, step: "Question \(questionIndex + 1) of \(questions.count)")
            progress(questions.count)

            Card(padding: 18) {
                VStack(alignment: .leading, spacing: 14) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(question.prompt)
                            .font(.system(size: 18, weight: .semibold, design: .rounded))
                        Text(question.detail)
                            .font(.system(size: 12)).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    ForEach(question.options) { option in
                        ChoiceCard(label: option.label, detail: option.detail,
                                   recommended: option.recommended,
                                   isSelected: answers[question.id] == option.id) {
                            answers[question.id] = option.id
                            var working = brief
                            option.apply(&working)
                            working.decisions.removeAll { $0.question == question.prompt }
                            working.decisions.append((question.prompt, option.label))
                            brief = working
                        }
                    }
                }
            }

            if !brief.decisions.isEmpty { decisionsSoFar }

            HStack {
                Button(questionIndex == 0 ? "Back to the briefing" : "Previous") {
                    if questionIndex == 0 { stage = .briefing } else { questionIndex -= 1 }
                }
                Spacer()
                if questionIndex < questions.count - 1 {
                    Button("Next") { questionIndex += 1 }
                        .disabled(!answered)
                        .keyboardShortcut(.defaultAction)
                } else {
                    Button("Build the team") { onBuild(brief) }
                        .disabled(!answered)
                        .keyboardShortcut(.defaultAction)
                }
            }
        })
    }

    private func progress(_ count: Int) -> some View {
        HStack(spacing: 4) {
            ForEach(0..<count, id: \.self) { index in
                Capsule()
                    .fill(index <= questionIndex ? Palette.accent : Palette.hairline)
                    .frame(height: 4)
            }
        }
    }

    private var decisionsSoFar: some View {
        Card(padding: 12) {
            VStack(alignment: .leading, spacing: 5) {
                Text("THE BRIEF SO FAR")
                    .font(.system(size: 9, weight: .bold)).kerning(0.5)
                    .foregroundStyle(.tertiary)
                ForEach(brief.decisions, id: \.question) { decision in
                    HStack(alignment: .top, spacing: 6) {
                        Image(systemName: "checkmark")
                            .font(.system(size: 9)).foregroundStyle(Palette.good)
                        Text(decision.question).font(.system(size: 11))
                            .foregroundStyle(.secondary)
                        Text(decision.answer).font(.system(size: 11, weight: .semibold))
                        Spacer(minLength: 0)
                    }
                }
            }
        }
    }

    private func header(_ seed: Form, step: String) -> some View {
        HStack(spacing: 14) {
            SpriteImage(form: seed, side: 64)
            VStack(alignment: .leading, spacing: 3) {
                Text(step.uppercased())
                    .font(.system(size: 9, weight: .bold)).kerning(0.6)
                    .foregroundStyle(Palette.accent)
                Text(seed.formLabel)
                    .font(.system(size: 22, weight: .bold, design: .rounded))
                HStack(spacing: 4) {
                    ForEach(seed.pokeTypes) { TypeChip(type: $0, size: .small) }
                }
            }
            Spacer()
        }
    }
}
