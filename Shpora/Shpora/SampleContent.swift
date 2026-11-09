import UIKit

/// Пример при первом запуске: Биология › Кости › Функции костей.
enum SampleContent {
    static func create(in root: URL) {
        let bones = root.appendingPathComponent("Биология/Кости", isDirectory: true)
        let fm = FileManager.default
        try? fm.createDirectory(at: bones.appendingPathComponent("images"), withIntermediateDirectories: true)
        try? fm.createDirectory(at: root.appendingPathComponent("Биология/Ткани"), withIntermediateDirectories: true)
        try? fm.createDirectory(at: root.appendingPathComponent("Биология/Животные"), withIntermediateDirectories: true)

        if let image = sampleImage(), let data = image.pngData() {
            try? data.write(to: bones.appendingPathComponent("images/skeleton.png"))
        }

        let note = #"""
        # Функции костей

        Скелет человека состоит из **206 костей**. Это ==шпаргалка-пример== — нажмите «Изменить», чтобы посмотреть, как она написана.

        ## Основные функции

        1. **Опорная** — каркас для мягких тканей
        2. **Защитная** — череп защищает мозг, рёбра — сердце и лёгкие
        3. **Двигательная** — рычаги для мышц
        4. **Кроветворная** — в красном костном мозге
        5. **Обменная** — депо кальция и фосфора

        ## Состав кости

        | Вещество | Доля | Что даёт |
        | --- | :---: | --- |
        | Органическое (оссеин) | ~30% | упругость |
        | Неорганическое (соли Ca) | ~60% | твёрдость |
        | Вода | ~10% | — |

        ## Картинка

        Нажмите на картинку, чтобы приблизить:

        ![Скелет](images/skeleton.png)

        ## Формулы

        Основной минерал кости — гидроксиапатит $Ca_{10}(PO_4)_6(OH)_2$.

        Прочность на сжатие:

        $$
        \sigma = \frac{F}{S}
        $$

        > Совет: записи — обычные .md файлы. Их можно писать на Mac в папке iCloud Drive › Шпора.

        - [x] Выучить функции
        - [ ] Выучить строение
        """#
        try? note.write(to: bones.appendingPathComponent("Функции костей.md"), atomically: true, encoding: .utf8)
    }

    private static func sampleImage() -> UIImage? {
        let config = UIImage.SymbolConfiguration(pointSize: 600, weight: .regular)
        guard let symbol = UIImage(systemName: "figure.stand", withConfiguration: config)?
            .withTintColor(.systemBlue, renderingMode: .alwaysOriginal) else { return nil }
        let size = CGSize(width: 1200, height: 1200)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: size, format: format).image { ctx in
            UIColor.white.setFill()
            ctx.fill(CGRect(origin: .zero, size: size))
            let s = symbol.size
            symbol.draw(at: CGPoint(x: (size.width - s.width) / 2, y: (size.height - s.height) / 2))
        }
    }
}
