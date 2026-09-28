import SwiftUI
import OrigonSDK

// Endpoint-login screen. Takes a URL, hands it to the SDK via
// `SDKManager.initialize(endpoint:)`, and on success calls
// `onAuthenticated(url)` so the parent (RootView) can persist it and
// move on to the chat surface.

struct EndpointView: View {
    let onAuthenticated: (String) -> Void

    @EnvironmentObject var sdk: SDKManager

    @State private var endpointURL = ""
    @State private var endpointError: String?
    @State private var isLoading = false
    @State private var keyboardHeight: CGFloat = 0
    @State private var toastMessage: String?
    @State private var showToast = false

    @FocusState private var endpointFocused: Bool
    @Environment(\.colorScheme) private var colorScheme

    private var isKeyboardVisible: Bool { keyboardHeight > 0 }

    var body: some View {
        ZStack {
            ZStack {
                if colorScheme == .dark {
                    Image("LoginArtwork")
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(maxWidth: .infinity)
                        .frame(height: 420)
                        .clipped()
                        .mask(
                            LinearGradient(
                                gradient: Gradient(stops: [
                                    .init(color: .black, location: 0.0),
                                    .init(color: .black, location: 0.55),
                                    .init(color: .clear, location: 1.0)
                                ]),
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                        .ignoresSafeArea(edges: .top)
                }

                // Header + form in one VStack; header expands to vertically
                // center its content between the status bar and the form.
                VStack(spacing: 0) {
                    headerSection
                        .frame(maxWidth: .infinity, maxHeight: .infinity)

                    VStack(spacing: 24) {
                        OrigonInput(
                            placeholder: "Enter endpoint URL",
                            text: $endpointURL,
                            errorMessage: endpointError,
                            keyboardType: .URL,
                            focus: $endpointFocused
                        )
                        .onChange(of: endpointURL) { _ in
                            if endpointError != nil { endpointError = nil }
                        }

                        InvertedButton(
                            title: "Continue",
                            loading: isLoading
                        ) {
                            handleEndpointLogin()
                        }
                    }
                    .padding(.horizontal, 24)

                    Color.clear.frame(height: isKeyboardVisible ? keyboardHeight : 24)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .ignoresSafeArea(.keyboard)
            .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { notif in
                applyKeyboardChange(notif, height: keyboardFrame(from: notif).height)
            }
            .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { notif in
                applyKeyboardChange(notif, height: 0)
            }

            // Toast lives in the outer ZStack so it inherits SwiftUI's
            // keyboard avoidance — sits above the keyboard, not under it.
            if showToast, let message = toastMessage {
                VStack {
                    Spacer()
                    Text(message)
                        .font(.subheadline.weight(.medium))
                        .foregroundColor(Origon.toastForeground)
                        .frame(maxWidth: .infinity)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 12)
                        .background(Origon.toastBackground)
                        .cornerRadius(8)
                        .shadow(color: .black.opacity(0.15), radius: 8, y: 4)
                        .padding(.horizontal, 20)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                        .padding(.bottom, 32)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .zIndex(1)
                .animation(.spring(response: 0.4, dampingFraction: 0.8), value: showToast)
            }
        }
        .onAppear {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                endpointFocused = true
            }
        }
    }

    private func presentToast(_ message: String) {
        toastMessage = message
        withAnimation { showToast = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
            withAnimation { showToast = false }
        }
    }

    // MARK: - Header Section

    private var headerSection: some View {
        VStack(spacing: 12) {
            if colorScheme == .light {
                Image("OrigonLogo")
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(height: 48)
                    .padding(.bottom, 12)
            }

            Text("Let’s Get Started")
                .font(.title.weight(.medium))
                .foregroundColor(Origon.textPrimary)
                .multilineTextAlignment(.center)

            Text("Connect to an Origon endpoint to start chatting and calling.")
                .font(.body)
                .foregroundColor(Origon.textSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 8)
        }
        .padding(.horizontal, 32)
    }

    // MARK: - Keyboard sync

    private func applyKeyboardChange(_ notif: Notification, height: CGFloat) {
        let duration = notif.userInfo?[UIResponder.keyboardAnimationDurationUserInfoKey] as? Double ?? 0.25
        withAnimation(.easeOut(duration: duration)) {
            keyboardHeight = height
        }
    }

    private func keyboardFrame(from notif: Notification) -> CGRect {
        (notif.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect) ?? .zero
    }

    // MARK: - Action

    private func handleEndpointLogin() {
        let trimmed = endpointURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            endpointError = "Please enter an endpoint URL"
            return
        }

        endpointError = nil
        isLoading = true
        Task {
            do {
                try await sdk.initialize(endpoint: trimmed)
                await MainActor.run {
                    isLoading = false
                    onAuthenticated(trimmed)
                }
            } catch let e as OrigonError {
                await MainActor.run {
                    isLoading = false
                    presentToast(e.userFacingMessage)
                }
            } catch {
                await MainActor.run {
                    isLoading = false
                    presentToast("Failed to connect. Please try again.")
                }
            }
        }
    }
}

// MARK: - OrigonError → user-facing message

private extension OrigonError {
    var userFacingMessage: String {
        switch kind {
        case .missingField:
            let field = code ?? "field"
            return "Missing \(field). Please enter a valid endpoint."
        case .http:
            if statusCode == 403, code == "bundle_id_not_allowed" {
                return "This app isn't authorized for that endpoint."
            }
            if let message, !message.isEmpty { return message }
            return "Server error (HTTP \(statusCode))."
        case .serverUnavailable:
            return "Server unavailable. Please try again shortly."
        case .other:
            if let message, !message.isEmpty { return message }
            return "Can't reach the server. Check the URL and your connection."
        case .notInitialized, .noSession, .session, .attachment, .cancelled, .chatRefused, .chatEnd, .unknown:
            return message ?? "Failed to connect. Please try again."
        }
    }
}
