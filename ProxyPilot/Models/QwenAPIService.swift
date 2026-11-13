import Foundation

/// Billing services use different endpoints and credentials, even within one region.
/// The saved endpoint remains the source of truth; no second preference can drift.
enum QwenAPIService: String, CaseIterable, Identifiable {
    case tokenPlanSingapore, tokenPlanChina, payAsYouGoInternational, payAsYouGoChina, custom

    var id: String { rawValue }

    var title: String {
        switch self {
        case .tokenPlanSingapore: return "Token Plan · Singapore"
        case .tokenPlanChina: return "Token Plan · China (Beijing)"
        case .payAsYouGoInternational: return "Pay as you go · International"
        case .payAsYouGoChina: return "Pay as you go · China (Beijing)"
        case .custom: return "Custom endpoint"
        }
    }

    var endpoint: String? {
        switch self {
        case .tokenPlanSingapore: return "https://token-plan.ap-southeast-1.maas.aliyuncs.com/compatible-mode/v1"
        case .tokenPlanChina: return "https://token-plan.cn-beijing.maas.aliyuncs.com/compatible-mode/v1"
        case .payAsYouGoInternational: return "https://dashscope-intl.aliyuncs.com/compatible-mode/v1"
        case .payAsYouGoChina: return "https://dashscope.aliyuncs.com/compatible-mode/v1"
        case .custom: return nil
        }
    }

    init(apiBaseURL: URL?) {
        guard let url = apiBaseURL, url.scheme?.lowercased() == "https",
              url.user == nil, url.password == nil, url.query == nil, url.fragment == nil,
              url.port == nil || url.port == 443 else { self = .custom; return }
        self = Self.allCases.first { service in
            guard let endpoint = service.endpoint, let preset = URL(string: endpoint) else { return false }
            return preset.host == url.host?.lowercased()
                && preset.path == "/" + url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        } ?? .custom
    }

    var isTokenPlan: Bool { self == .tokenPlanSingapore || self == .tokenPlanChina }

    var keyPageURL: URL? {
        switch self {
        case .tokenPlanSingapore:
            return URL(string: "https://modelstudio.console.alibabacloud.com/ap-southeast-1/subscription/token-plan/personal")
        case .tokenPlanChina:
            return URL(string: "https://bailian.console.aliyun.com/cn-beijing/subscription/token-plan/personal")
        case .payAsYouGoInternational:
            return URL(string: "https://modelstudio.console.alibabacloud.com/?tab=api#/api-key")
        case .payAsYouGoChina:
            return URL(string: "https://dashscope.console.aliyun.com/apiKey")
        case .custom: return nil
        }
    }

    var keyHint: String {
        switch self {
        case .tokenPlanSingapore, .tokenPlanChina:
            return "\(title) selected. Use your Token Plan key (sk-sp-), not a pay-as-you-go or Coding Plan key. Personal keys are on My Subscription; Team keys are in Member Management."
        case .payAsYouGoInternational:
            return "International DashScope endpoint selected. Use an Alibaba Cloud Model Studio key from Singapore or another matching non-China region."
        case .payAsYouGoChina:
            return "China (Beijing) DashScope endpoint selected. Use a China-region Model Studio API key."
        case .custom:
            return "Use a key issued for this endpoint and billing service. Token Plan, Coding Plan and pay-as-you-go credentials are separate."
        }
    }
}
