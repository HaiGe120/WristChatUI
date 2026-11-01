import Foundation

/// Release gates are deliberately static until their evidence is recorded and
/// reviewed. No UI can turn an unverified native/product flow into a ready session.
public enum ChatGPTSignInReadiness {
    public static let isEnabled = false
    public static let status = "Direct sign-in is in development"
    public static let requirements = [
        "Confirm OpenAI supports ChatGPT plan usage for this App Store product.",
        "Verify the documented system-browser callback and return to the app on a physical iPhone.",
        "Complete and test token exchange, renewal, sign-out, and paired Watch access."
    ]
    public static let documentationURL = URL(string: "https://developers.openai.com/siwc/token-sharing-open-source")!
}
