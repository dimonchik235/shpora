import SwiftUI
import UIKit

extension View {
    /// Полноэкранный просмотр: на iPhone — fullScreenCover, на часах — sheet (там есть системная кнопка закрытия).
    func zoomCover<Content: View>(isPresented: Binding<Bool>, @ViewBuilder content: @escaping () -> Content) -> some View {
        #if os(watchOS)
        sheet(isPresented: isPresented, content: content)
        #else
        fullScreenCover(isPresented: isPresented, content: content)
        #endif
    }
}

#if os(iOS)

// MARK: - iPhone: зум через UIScrollView

struct ZoomableImageScreen: View {
    let image: UIImage
    /// true — картинка-формула, перекрашивается в цвет текста.
    let template: Bool
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ZStack(alignment: .topTrailing) {
            ZoomContainer(naturalSize: image.size, fitMode: .fitScreen) {
                let view = UIImageView(image: template ? image.withRenderingMode(.alwaysTemplate) : image)
                view.tintColor = .label
                return view
            }
            .ignoresSafeArea()
            CloseButton { dismiss() }
        }
        .background(template ? Color(.systemBackground) : .black)
    }
}

struct FullTableScreen: View {
    let table: MDTable
    @Environment(\.dismiss) private var dismiss
    @Environment(\.mathProvider) private var math

    var body: some View {
        let content = TableGrid(table: table)
            .environment(\.mathProvider, math)
            .padding(16)
        ZStack(alignment: .topTrailing) {
            ZoomContainer(naturalSize: nil, fitMode: .fitWidthNoUpscale) {
                let host = UIHostingController(rootView: content)
                host.view.backgroundColor = .clear
                host.view.bounds.size = host.sizeThatFits(in: CGSize(width: CGFloat.greatestFiniteMagnitude,
                                                                     height: CGFloat.greatestFiniteMagnitude))
                // удерживаем контроллер, пока жива вьюха
                objc_setAssociatedObject(host.view!, &hostKey, host, .OBJC_ASSOCIATION_RETAIN)
                return host.view
            }
            .ignoresSafeArea(edges: .bottom)
            CloseButton { dismiss() }
        }
        .background(Color(.systemBackground))
    }
}

nonisolated(unsafe) private var hostKey: UInt8 = 0

private struct CloseButton: View {
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Image(systemName: "xmark")
                .font(.headline)
                .padding(12)
        }
        .buttonStyle(.glass)
        .buttonBorderShape(.circle)
        .padding()
    }
}

enum ZoomFitMode { case fitScreen, fitWidthNoUpscale }

struct ZoomContainer: UIViewRepresentable {
    /// nil — взять размер из bounds созданной вьюхи.
    let naturalSize: CGSize?
    let fitMode: ZoomFitMode
    let makeContent: () -> UIView

    init(naturalSize: CGSize?, fitMode: ZoomFitMode, makeContent: @escaping () -> UIView) {
        self.naturalSize = naturalSize
        self.fitMode = fitMode
        self.makeContent = makeContent
    }

    func makeUIView(context: Context) -> ZoomScrollView {
        let content = makeContent()
        return ZoomScrollView(content: content, naturalSize: naturalSize ?? content.bounds.size, fitMode: fitMode)
    }

    func updateUIView(_ uiView: ZoomScrollView, context: Context) {}
}

final class ZoomScrollView: UIScrollView, UIScrollViewDelegate {
    private let content: UIView
    private let naturalSize: CGSize
    private let fitMode: ZoomFitMode
    private var lastBoundsSize: CGSize = .zero

    init(content: UIView, naturalSize: CGSize, fitMode: ZoomFitMode) {
        self.content = content
        self.naturalSize = CGSize(width: max(naturalSize.width, 1), height: max(naturalSize.height, 1))
        self.fitMode = fitMode
        super.init(frame: .zero)
        delegate = self
        content.frame = CGRect(origin: .zero, size: self.naturalSize)
        addSubview(content)
        contentSize = self.naturalSize
        showsVerticalScrollIndicator = false
        showsHorizontalScrollIndicator = false
        decelerationRate = .fast
        contentInsetAdjustmentBehavior = .never
        let doubleTap = UITapGestureRecognizer(target: self, action: #selector(handleDoubleTap(_:)))
        doubleTap.numberOfTapsRequired = 2
        addGestureRecognizer(doubleTap)
    }

    required init?(coder: NSCoder) { fatalError() }

    private var fitScale: CGFloat {
        let w = bounds.width / naturalSize.width
        let h = bounds.height / naturalSize.height
        switch fitMode {
        case .fitScreen: return min(w, h)
        case .fitWidthNoUpscale: return min(w, 1)
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        if bounds.size != lastBoundsSize, bounds.width > 0 {
            lastBoundsSize = bounds.size
            minimumZoomScale = min(fitScale, 1)
            maximumZoomScale = max(fitScale * 8, 3)
            zoomScale = initialScale
            centerContent()
            // Широкая таблица открывается с левого края, а не посередине.
            contentOffset = CGPoint(x: -contentInset.left, y: -contentInset.top)
        }
        centerContent()
    }

    /// Широкую таблицу не ужимаем до нечитаемого размера: целиком её можно увидеть, сведя пальцы.
    private var initialScale: CGFloat {
        switch fitMode {
        case .fitScreen: fitScale
        case .fitWidthNoUpscale: max(fitScale, 0.8)
        }
    }

    private func centerContent() {
        let x = max((bounds.width - contentSize.width) / 2, 0)
        let y = max((bounds.height - contentSize.height) / 2, 0)
        contentInset = UIEdgeInsets(top: y + safeAreaInsets.top, left: x, bottom: y, right: x)
    }

    func viewForZooming(in scrollView: UIScrollView) -> UIView? { content }

    func scrollViewDidZoom(_ scrollView: UIScrollView) { centerContent() }

    @objc private func handleDoubleTap(_ gesture: UITapGestureRecognizer) {
        if zoomScale > fitScale * 1.05 {
            setZoomScale(fitScale, animated: true)
        } else {
            let point = gesture.location(in: content)
            let target = min(fitScale * 3, maximumZoomScale)
            let size = CGSize(width: bounds.width / target, height: bounds.height / target)
            zoom(to: CGRect(x: point.x - size.width / 2, y: point.y - size.height / 2,
                            width: size.width, height: size.height), animated: true)
        }
    }
}

#else

// MARK: - Часы: зум колёсиком Digital Crown, перемещение пальцем

struct ZoomableImageScreen: View {
    let image: UIImage
    let template: Bool
    /// Для широких таблиц: открыть сразу в читаемом масштабе с левого верхнего края.
    var startReadable = false

    @State private var scale: Double = 1
    @State private var offset: CGSize = .zero
    @State private var dragStart: CGSize = .zero
    @State private var size: CGSize = .zero
    @State private var started = false

    var body: some View {
        Image(uiImage: image)
            .renderingMode(template ? .template : .original)
            .resizable()
            .scaledToFit()
            .scaleEffect(scale)
            .offset(offset)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(
                DragGesture()
                    .onChanged { value in
                        offset = clamped(CGSize(width: dragStart.width + value.translation.width,
                                                height: dragStart.height + value.translation.height))
                    }
                    .onEnded { _ in dragStart = offset }
            )
            .onTapGesture(count: 2) {
                withAnimation {
                    if scale > 1.1 {
                        scale = 1
                        offset = .zero
                        dragStart = .zero
                    } else {
                        scale = min(3, maxScale)
                    }
                }
            }
            .onChange(of: scale) {
                offset = clamped(offset)
                dragStart = offset
            }
            .onGeometryChange(for: CGSize.self) { $0.size } action: { newSize in
                size = newSize
                startReadableIfNeeded()
            }
            .clipped()
            .focusable()
            .digitalCrownRotation($scale, from: 1, through: maxScale, by: 0.1,
                                  sensitivity: .medium, isContinuous: false, isHapticFeedbackEnabled: true)
            .ignoresSafeArea(edges: .bottom)
    }

    /// Размер картинки на экране при масштабе 1 (вписана в экран).
    private var fittedSize: CGSize {
        guard image.size.width > 0, image.size.height > 0 else { return .zero }
        let fit = min(size.width / image.size.width, size.height / image.size.height)
        return CGSize(width: image.size.width * fit, height: image.size.height * fit)
    }

    private func startReadableIfNeeded() {
        guard startReadable, !started, size.width > 0, fittedSize.width > 0 else { return }
        started = true
        // Во сколько раз картинка ужата, чтобы влезть в экран, — на столько и приближаем.
        let target = min(maxScale, image.size.width / fittedSize.width)
        guard target > 1.05 else { return }
        scale = target
        offset = clamped(CGSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude),
                         scale: target)
        dragStart = offset
    }

    private var maxScale: Double {
        // чем больше картинка, тем сильнее можно приблизить
        max(4, min(10, Double(max(image.size.width, image.size.height) * image.scale) / 150))
    }

    /// Двигать можно ровно настолько, чтобы край картинки доходил до края экрана.
    private func clamped(_ value: CGSize, scale: Double? = nil) -> CGSize {
        let s = scale ?? self.scale
        let maxX = max(0, (fittedSize.width * s - size.width) / 2)
        let maxY = max(0, (fittedSize.height * s - size.height) / 2)
        return CGSize(width: min(max(value.width, -maxX), maxX),
                      height: min(max(value.height, -maxY), maxY))
    }
}

/// На часах таблица превращается в картинку и смотрится с зумом.
struct FullTableScreen: View {
    let table: MDTable
    @Environment(\.mathProvider) private var math
    @State private var image: UIImage?

    var body: some View {
        Group {
            if let image {
                ZoomableImageScreen(image: image, template: false, startReadable: true)
            } else {
                ProgressView()
            }
        }
        .task {
            let renderer = ImageRenderer(content:
                TableGrid(table: table)
                    .environment(\.mathProvider, math)
                    .foregroundStyle(.white)
                    .tint(.accentColor)
                    .environment(\.colorScheme, .dark)
                    .padding(4)
                    .background(.black))
            renderer.scale = 4
            renderer.proposedSize = .unspecified
            image = renderer.uiImage
        }
    }
}

#endif
