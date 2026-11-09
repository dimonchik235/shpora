import SwiftUI

/// Размер текста на часах: чем меньше, тем больше помещается на экран.
/// Текст записи масштабируется свободно (см. `contentScale`), а списки — через Dynamic Type,
/// у которого нет размеров меньше `.xSmall`.
enum TextSize: Int, CaseIterable {
    case tiny, xxSmall, xSmall, small, standardSize, large, xLarge, xxLarge

    static let storageKey = "watchTextSize"
    static let standard = TextSize.standardSize

    var scale: CGFloat {
        switch self {
        case .tiny: 0.6
        case .xxSmall: 0.7
        case .xSmall: 0.8
        case .small: 0.9
        case .standardSize: 1
        case .large: 1.12
        case .xLarge: 1.25
        case .xxLarge: 1.4
        }
    }

    var dynamicType: DynamicTypeSize {
        switch self {
        case .tiny, .xxSmall, .xSmall: .xSmall
        case .small: .small
        case .standardSize: .large
        case .large: .xLarge
        case .xLarge: .xxLarge
        case .xxLarge: .xxxLarge
        }
    }

    var smaller: TextSize? { TextSize(rawValue: rawValue - 1) }
    var larger: TextSize? { TextSize(rawValue: rawValue + 1) }
}

/// Экран выбора размера: кнопки «A» по бокам и колёсико.
struct TextSizeScreen: View {
    @AppStorage(TextSize.storageKey) private var size = TextSize.standard
    @State private var crown: Double = 0

    var body: some View {
        VStack(spacing: 10) {
            Text("Функции костей: **опора**, защита, движение и кроветворение.")
                .font(MDFont.style(.body, scale: size.scale))
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .clipped()

            HStack {
                Button { if let s = size.smaller { size = s } } label: {
                    Image(systemName: "textformat.size.smaller")
                }
                .disabled(size.smaller == nil)

                Text("\(size.rawValue + 1) / \(TextSize.allCases.count)")
                    .font(.footnote.monospacedDigit())
                    .frame(maxWidth: .infinity)

                Button { if let s = size.larger { size = s } } label: {
                    Image(systemName: "textformat.size.larger")
                }
                .disabled(size.larger == nil)
            }
            .buttonStyle(.bordered)

            Button("Сбросить") { size = .standard }
                .font(.footnote)
                .buttonStyle(.plain)
                .foregroundStyle(.tint)
        }
        .padding(.horizontal, 4)
        .navigationTitle("Размер текста")
        .focusable()
        .digitalCrownRotation($crown, from: 0, through: Double(TextSize.allCases.count - 1), by: 1,
                              sensitivity: .low, isContinuous: false, isHapticFeedbackEnabled: true)
        .onAppear { crown = Double(size.rawValue) }
        .onChange(of: crown) {
            if let s = TextSize(rawValue: Int(crown.rounded())), s != size { size = s }
        }
        .onChange(of: size) { crown = Double(size.rawValue) }
    }
}
