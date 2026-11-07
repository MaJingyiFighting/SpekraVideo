import Foundation
import StoreKit
import SwiftUI

@MainActor
final class ProPurchaseManager: ObservableObject {
    static let shared = ProPurchaseManager()
    static let productID = "app.spekravideo.cam.pro_creator"
    private static let cacheKey = "spekravideo.pro_creator.unlocked"

    @Published var isProUnlocked: Bool = false
    @Published var product: Product? = nil
    @Published var isPurchasing: Bool = false
    @Published var statusMessage: String? = nil

    private var updatesTask: Task<Void, Never>? = nil

    private init() {
        self.isProUnlocked = UserDefaults.standard.bool(forKey: Self.cacheKey)
        updatesTask = Task {
            await refreshEntitlements()
            await fetchProduct()
            for await verification in Transaction.updates {
                if case .verified(let tx) = verification, tx.productID == Self.productID {
                    if tx.revocationDate == nil {
                        self.unlock()
                    }
                    await tx.finish()
                }
            }
        }
    }

    var displayPrice: String {
        product?.displayPrice ?? "¥38"
    }

    func fetchProduct() async {
        do {
            let products = try await Product.products(for: [Self.productID])
            if let first = products.first {
                self.product = first
            }
        } catch {}
    }

    func refreshEntitlements() async {
        for await result in Transaction.currentEntitlements {
            if case .verified(let tx) = result, tx.productID == Self.productID, tx.revocationDate == nil {
                unlock()
                return
            }
        }
    }

    func purchase(onSuccess: (() -> Void)? = nil) {
        guard !isPurchasing else { return }
        isPurchasing = true
        statusMessage = nil

        Task {
            defer { isPurchasing = false }
            do {
                if product == nil {
                    await fetchProduct()
                }
                guard let prod = product else {
                    statusMessage = "正在连接 App Store，请稍后重试"
                    return
                }
                let result = try await prod.purchase()
                switch result {
                case .success(let verification):
                    if case .verified(let tx) = verification {
                        unlock()
                        await tx.finish()
                        onSuccess?()
                    } else {
                        statusMessage = "订单校验未通过"
                    }
                case .userCancelled:
                    break
                case .pending:
                    statusMessage = "订单等待确认中"
                @unknown default:
                    break
                }
            } catch {
                statusMessage = "购买未能完成，请检查网络或 Apple 账号设置"
            }
        }
    }

    func restore(onSuccess: (() -> Void)? = nil) {
        guard !isPurchasing else { return }
        isPurchasing = true
        statusMessage = nil

        Task {
            defer { isPurchasing = false }
            do {
                try await AppStore.sync()
                await refreshEntitlements()
                if isProUnlocked {
                    statusMessage = "已成功恢复专业版权益"
                    onSuccess?()
                } else {
                    statusMessage = "当前账号未查询到已购买记录"
                }
            } catch {
                statusMessage = "恢复购买失败，请检查网络连接"
            }
        }
    }

    private func unlock() {
        isProUnlocked = true
        UserDefaults.standard.set(true, forKey: Self.cacheKey)
    }
}

struct ProPaywallModalView: View {
    @ObservedObject var purchaseManager: ProPurchaseManager
    let accent: Color
    let onClose: () -> Void

    var body: some View {
        ZStack {
            Color.black.opacity(0.28)
                .ignoresSafeArea()
                .onTapGesture { onClose() }

            cardContent
                .padding(.horizontal, 26)
        }
    }

    @ViewBuilder
    private var cardContent: some View {
        let inner = VStack(spacing: 32) {
            // 顶部：右上角轻量关闭按钮 + 居中标题
            ZStack(alignment: .topTrailing) {
                VStack(spacing: 8) {
                    Text("SpekraVideo Pro")
                        .font(.system(size: 22, weight: .semibold, design: .rounded))
                        .foregroundColor(.white)

                    Text("一次买断 · 永久解锁")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(.white.opacity(0.56))
                }
                .frame(maxWidth: .infinity)
                .padding(.top, 6)

                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundColor(.white.opacity(0.65))
                        .frame(width: 28, height: 28)
                        .background(Color.white.opacity(0.12), in: Circle())
                }
            }

            // 中部：无内框、留白通透的两项核心功能
            VStack(alignment: .leading, spacing: 24) {
                featureItem(
                    icon: "square.and.arrow.up",
                    title: "7 大社交平台无损直发格式",
                    subtitle: "小红书 · 朋友圈 · 微博 · QQ空间 · Ins · 抖音"
                )

                featureItem(
                    icon: "film.stack",
                    title: "成片与原片同时保存",
                    subtitle: "拍照同步保留 DNG 底片 · 视频同步保存 Log 原片"
                )
            }
            .padding(.horizontal, 6)

            if let msg = purchaseManager.statusMessage {
                Text(msg)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(accent)
                    .multilineTextAlignment(.center)
            }

            // 底部：胶囊主按钮 + 恢复购买
            VStack(spacing: 16) {
                Button(action: {
                    purchaseManager.purchase {
                        onClose()
                    }
                }) {
                    HStack(spacing: 8) {
                        if purchaseManager.isPurchasing {
                            ProgressView()
                                .tint(.black)
                                .scaleEffect(0.85)
                        }
                        Text("\(purchaseManager.displayPrice) 永久解锁")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundColor(.black)
                    }
                    .frame(maxWidth: .infinity)
                    .frame(height: 50)
                    .background(Color.white, in: Capsule())
                }
                .disabled(purchaseManager.isPurchasing)

                Button(action: {
                    purchaseManager.restore {
                        onClose()
                    }
                }) {
                    Text("恢复购买")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(.white.opacity(0.55))
                }
            }
        }
        .padding(.horizontal, 26)
        .padding(.vertical, 30)

        if #available(iOS 26.0, *) {
            inner
                .glassEffect(.regular, in: .rect(cornerRadius: 34))
                .shadow(color: .black.opacity(0.35), radius: 28, y: 12)
        } else {
            inner
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 34, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 34, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.16), lineWidth: 0.6)
                )
                .shadow(color: .black.opacity(0.45), radius: 28, y: 12)
        }
    }

    private func featureItem(icon: String, title: String, subtitle: String) -> some View {
        HStack(alignment: .top, spacing: 16) {
            Image(systemName: icon)
                .font(.system(size: 19, weight: .medium))
                .foregroundColor(.white.opacity(0.9))
                .frame(width: 26, height: 26)
                .padding(.top, 1)

            VStack(alignment: .leading, spacing: 5) {
                Text(title)
                    .font(.system(size: 15.5, weight: .semibold))
                    .foregroundColor(.white)
                    .lineLimit(1)

                Text(subtitle)
                    .font(.system(size: 12.5, weight: .regular))
                    .foregroundColor(.white.opacity(0.58))
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
            }
        }
    }
}
