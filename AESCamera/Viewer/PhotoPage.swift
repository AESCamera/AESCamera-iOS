import AESCore
import SwiftUI
import UIKit

/// A photo decrypted in memory, bounded to 2× the screen's long side, in a zoomable view.
/// While zoomed in, the pager stops scrolling so panning stays on the photo.
struct PhotoPage: View {
    let item: MediaItem
    @Binding var zoomed: Bool
    let onTap: () -> Void

    @Environment(AppSession.self) private var session
    @State private var image: UIImage?
    @State private var failure: String?

    var body: some View {
        ZStack {
            if let image {
                ZoomableImage(image: image, zoomed: $zoomed, onTap: onTap)
            } else if let failure {
                Label(failure, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.white)
                    .padding()
            } else {
                ProgressView().tint(.white)
            }
        }
        .contentShape(Rectangle())
        .task(id: item.id) {
            guard let secret = session.secret else { return }
            let url = item.url
            let maxPixel = Int(max(UIScreen.main.nativeBounds.width, UIScreen.main.nativeBounds.height)) * 2
            let result = await Task.detached(priority: .userInitiated) { () -> Result<CGImage, Error> in
                Result {
                    let plaintext = try ImageCrypto.open(Data(contentsOf: url), secret: secret)
                    guard let decoded = Thumbnails.decode(plaintext, maxPixelSize: maxPixel) else {
                        throw CameraError.photoFailed
                    }
                    return decoded
                }
            }.value
            switch result {
            case .success(let cgImage): image = UIImage(cgImage: cgImage)
            case .failure(CryptoError.authenticationFailed), .failure(CryptoError.badPadding):
                failure = "This photo doesn't open with this password, or it was changed."
            case .failure: failure = "This photo can't be opened."
            }
        }
    }
}

/// `UIScrollView`-based pinch/double-tap zoom.
struct ZoomableImage: UIViewRepresentable {
    let image: UIImage
    @Binding var zoomed: Bool
    let onTap: () -> Void

    func makeUIView(context: Context) -> ZoomView {
        let view = ZoomView()
        view.imageView.image = image
        view.onZoomChange = { zoomed = $0 }
        view.onTap = onTap
        return view
    }

    func updateUIView(_ view: ZoomView, context: Context) {
        if view.imageView.image !== image {
            view.imageView.image = image
            view.setNeedsLayout()
        }
        view.onZoomChange = { zoomed = $0 }
        view.onTap = onTap
    }

    final class ZoomView: UIScrollView, UIScrollViewDelegate {
        let imageView = UIImageView()
        var onZoomChange: ((Bool) -> Void)?
        var onTap: (() -> Void)?
        private var wasZoomed = false
        private var lastSize = CGSize.zero

        override init(frame: CGRect) {
            super.init(frame: frame)
            delegate = self
            minimumZoomScale = 1
            maximumZoomScale = 5
            showsVerticalScrollIndicator = false
            showsHorizontalScrollIndicator = false
            contentInsetAdjustmentBehavior = .never
            imageView.contentMode = .scaleAspectFit
            addSubview(imageView)

            let doubleTap = UITapGestureRecognizer(target: self, action: #selector(doubleTapped(_:)))
            doubleTap.numberOfTapsRequired = 2
            addGestureRecognizer(doubleTap)
            let singleTap = UITapGestureRecognizer(target: self, action: #selector(singleTapped))
            singleTap.require(toFail: doubleTap)
            addGestureRecognizer(singleTap)
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

        override func layoutSubviews() {
            super.layoutSubviews()
            if bounds.size != lastSize {
                lastSize = bounds.size
                zoomScale = 1
                imageView.frame = CGRect(origin: .zero, size: bounds.size)
                contentSize = bounds.size
            }
        }

        func viewForZooming(in scrollView: UIScrollView) -> UIView? { imageView }

        func scrollViewDidZoom(_ scrollView: UIScrollView) {
            let isZoomed = zoomScale > 1.01
            if isZoomed != wasZoomed {
                wasZoomed = isZoomed
                onZoomChange?(isZoomed)
            }
        }

        @objc private func singleTapped() { onTap?() }

        @objc private func doubleTapped(_ recognizer: UITapGestureRecognizer) {
            if zoomScale > 1.01 {
                setZoomScale(1, animated: true)
            } else {
                let point = recognizer.location(in: imageView)
                let size = CGSize(width: bounds.width / 2.5, height: bounds.height / 2.5)
                zoom(to: CGRect(x: point.x - size.width / 2, y: point.y - size.height / 2, width: size.width, height: size.height), animated: true)
            }
        }
    }
}
