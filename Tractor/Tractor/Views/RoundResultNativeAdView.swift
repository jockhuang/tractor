import GoogleMobileAds
import SwiftUI
import UIKit

@MainActor
final class NativeAdModel: NSObject, ObservableObject {
    @Published private(set) var nativeAd: NativeAd?

    private var adLoader: AdLoader?
    private var hasRequestedAd = false

    func updateAdEligibility(_ canRequestAds: Bool) {
        guard canRequestAds else {
            nativeAd = nil
            hasRequestedAd = false
            adLoader = nil
            return
        }
        guard !hasRequestedAd else { return }
        hasRequestedAd = true

        let viewOptions = NativeAdViewAdOptions()
        viewOptions.preferredAdChoicesPosition = .topRightCorner

        let loader = AdLoader(
            adUnitID: AdsManager.nativeAdUnitID,
            rootViewController: nil,
            adTypes: [.native],
            options: [viewOptions]
        )
        adLoader = loader
        loader.delegate = self
        loader.load(Request())
    }
}

extension NativeAdModel: NativeAdLoaderDelegate, NativeAdDelegate {
    func adLoader(_ adLoader: AdLoader, didReceive nativeAd: NativeAd) {
        nativeAd.delegate = self
        self.nativeAd = nativeAd
    }

    func adLoader(_ adLoader: AdLoader, didFailToReceiveAdWithError error: Error) {
        #if DEBUG
        print("Native ad failed to load: \(error.localizedDescription)")
        #endif
    }
}

struct NativeAdPlacement: View {
    let nativeAd: NativeAd

    var body: some View {
        NativeAdContainer(nativeAd: nativeAd)
            .frame(height: 156)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .accessibilityLabel(L10n.text("ads.accessibility_label"))
    }
}

private struct NativeAdContainer: UIViewRepresentable {
    let nativeAd: NativeAd

    func makeUIView(context: Context) -> NativeAdView {
        let nativeAdView = NativeAdView()
        nativeAdView.backgroundColor = UIColor.white.withAlphaComponent(0.1)
        nativeAdView.layer.cornerRadius = 12
        nativeAdView.clipsToBounds = true

        let attributionLabel = UILabel()
        attributionLabel.translatesAutoresizingMaskIntoConstraints = false
        attributionLabel.text = L10n.text("ads.attribution")
        attributionLabel.textAlignment = .center
        attributionLabel.font = .systemFont(ofSize: 10, weight: .bold)
        attributionLabel.textColor = .white
        attributionLabel.backgroundColor = UIColor.systemYellow.withAlphaComponent(0.9)
        attributionLabel.layer.cornerRadius = 3
        attributionLabel.clipsToBounds = true

        let mediaView = MediaView()
        mediaView.translatesAutoresizingMaskIntoConstraints = false
        mediaView.backgroundColor = UIColor.black.withAlphaComponent(0.16)
        mediaView.layer.cornerRadius = 7
        mediaView.clipsToBounds = true

        let headlineLabel = UILabel()
        headlineLabel.font = .systemFont(ofSize: 15, weight: .semibold)
        headlineLabel.textColor = .white
        headlineLabel.numberOfLines = 1

        let advertiserLabel = UILabel()
        advertiserLabel.font = .systemFont(ofSize: 11, weight: .medium)
        advertiserLabel.textColor = UIColor.white.withAlphaComponent(0.7)
        advertiserLabel.numberOfLines = 1

        let bodyLabel = UILabel()
        bodyLabel.font = .systemFont(ofSize: 11)
        bodyLabel.textColor = UIColor.white.withAlphaComponent(0.72)
        bodyLabel.numberOfLines = 2

        let textStack = UIStackView(arrangedSubviews: [headlineLabel, advertiserLabel, bodyLabel])
        textStack.translatesAutoresizingMaskIntoConstraints = false
        textStack.axis = .vertical
        textStack.spacing = 2
        textStack.alignment = .fill

        let callToActionButton = UIButton(type: .system)
        callToActionButton.translatesAutoresizingMaskIntoConstraints = false
        callToActionButton.titleLabel?.font = .systemFont(ofSize: 12, weight: .bold)
        callToActionButton.setTitleColor(.white, for: .normal)
        callToActionButton.backgroundColor = .systemBlue
        callToActionButton.layer.cornerRadius = 7
        // The Google Mobile Ads SDK owns click handling for registered asset views.
        callToActionButton.isUserInteractionEnabled = false

        [attributionLabel, mediaView, textStack, callToActionButton].forEach(nativeAdView.addSubview)

        nativeAdView.mediaView = mediaView
        nativeAdView.headlineView = headlineLabel
        nativeAdView.advertiserView = advertiserLabel
        nativeAdView.bodyView = bodyLabel
        nativeAdView.callToActionView = callToActionButton

        NSLayoutConstraint.activate([
            attributionLabel.leadingAnchor.constraint(equalTo: nativeAdView.leadingAnchor, constant: 8),
            attributionLabel.topAnchor.constraint(equalTo: nativeAdView.topAnchor, constant: 6),
            attributionLabel.widthAnchor.constraint(greaterThanOrEqualToConstant: 28),
            attributionLabel.heightAnchor.constraint(equalToConstant: 17),

            mediaView.leadingAnchor.constraint(equalTo: nativeAdView.leadingAnchor, constant: 8),
            mediaView.topAnchor.constraint(equalTo: attributionLabel.bottomAnchor, constant: 5),
            mediaView.bottomAnchor.constraint(equalTo: nativeAdView.bottomAnchor, constant: -8),
            mediaView.widthAnchor.constraint(equalToConstant: 120),
            mediaView.heightAnchor.constraint(equalToConstant: 120),

            textStack.leadingAnchor.constraint(equalTo: mediaView.trailingAnchor, constant: 10),
            textStack.centerYAnchor.constraint(equalTo: mediaView.centerYAnchor),
            textStack.trailingAnchor.constraint(lessThanOrEqualTo: callToActionButton.leadingAnchor, constant: -10),

            callToActionButton.trailingAnchor.constraint(equalTo: nativeAdView.trailingAnchor, constant: -8),
            callToActionButton.bottomAnchor.constraint(equalTo: nativeAdView.bottomAnchor, constant: -10),
            callToActionButton.heightAnchor.constraint(equalToConstant: 34),
            callToActionButton.widthAnchor.constraint(lessThanOrEqualToConstant: 104),
            callToActionButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 74)
        ])

        return nativeAdView
    }

    func updateUIView(_ nativeAdView: NativeAdView, context: Context) {
        guard
            let headlineLabel = nativeAdView.headlineView as? UILabel,
            let advertiserLabel = nativeAdView.advertiserView as? UILabel,
            let bodyLabel = nativeAdView.bodyView as? UILabel,
            let callToActionButton = nativeAdView.callToActionView as? UIButton
        else { return }

        headlineLabel.text = nativeAd.headline
        nativeAdView.mediaView?.mediaContent = nativeAd.mediaContent

        advertiserLabel.text = nativeAd.advertiser
        advertiserLabel.isHidden = nativeAd.advertiser == nil

        bodyLabel.text = nativeAd.body
        bodyLabel.isHidden = nativeAd.body == nil

        callToActionButton.setTitle(nativeAd.callToAction, for: .normal)
        callToActionButton.isHidden = nativeAd.callToAction == nil
        callToActionButton.isUserInteractionEnabled = false

        // Asset values must be populated before associating the NativeAd with its view.
        nativeAdView.nativeAd = nativeAd
    }
}
