import Foundation

public struct VercelDeploymentState: Equatable, Sendable {
    public enum Phase: String, Sendable { case waiting, building, ready, failed, unavailable }
    public let phase: Phase
    public let message: String
    public let detailsURL: URL?
    public let siteURL: URL?
    public init(phase: Phase, message: String, detailsURL: URL? = nil, siteURL: URL? = nil) {
        self.phase = phase; self.message = message; self.detailsURL = detailsURL; self.siteURL = siteURL
    }
}
public enum VercelDeploymentMonitor {
    public struct Deployment: Decodable, Sendable {
        public let id: Int
        let sha: String
        let environment: String
        let production_environment: Bool?
        let creator: Creator?
        struct Creator: Decodable, Sendable { let login: String }
    }
    public static func productionDeployment(_ data: Data, sha: String) throws -> Deployment? {
        try JSONDecoder().decode([Deployment].self, from: data)
            .filter { $0.sha == sha && $0.production_environment == true && ["vercel[bot]", "vercel"].contains($0.creator?.login.lowercased() ?? "") }
            .max { $0.id < $1.id }
    }
    public static func safeURL(_ string: String?) -> URL? {
        guard let string, let url = URL(string: string), url.scheme == "https", url.host != nil, url.user == nil, url.password == nil else { return nil }
        return url
    }
    public static func status(_ data: Data) throws -> VercelDeploymentState {
        struct Status: Decodable { let state: String; let log_url: String?; let environment_url: String?; let target_url: String? }
        guard let latest = try JSONDecoder().decode([Status].self, from: data).first else {
            return .init(phase: .waiting, message: "Vercel ещё не сообщил статус сборки")
        }
        let details = safeURL(latest.log_url ?? latest.target_url), site = safeURL(latest.environment_url)
        switch latest.state {
        case "success": return .init(phase: .ready, message: "Продакшен опубликован", detailsURL: details, siteURL: site)
        case "error", "failure": return .init(phase: .failed, message: "Ошибка деплоя в Vercel. Коммит уже отправлен", detailsURL: details)
        case "queued", "pending", "in_progress": return .init(phase: .building, message: "Vercel собирает продакшен", detailsURL: details)
        case "inactive": return .init(phase: .unavailable, message: "Этот деплой больше не активен", detailsURL: details)
        default: return .init(phase: .waiting, message: "Ожидаем подтверждение от Vercel", detailsURL: details)
        }
    }
    private static func get(_ path: String) async throws -> Data {
        let url = URL(string: "https://api.github.com/" + path)!
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("Portlight", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200, data.count < 2_000_000 else {
            throw PortlightError.unavailable("Статус недоступен через публичный GitHub API. Проверьте деплой в Vercel; для приватного репозитория откройте его панель.")
        }
        return data
    }
    public static func check(remote: String, sha: String) async -> VercelDeploymentState {
        guard let repository = GitPublisher.githubRepository(remote), sha.range(of: "^[a-f0-9]{40,64}$", options: .regularExpression) != nil else {
            return .init(phase: .unavailable, message: "Автоматический статус доступен для GitHub → Vercel")
        }
        do {
            let data = try await get("repos/\(repository)/deployments?sha=\(sha)&per_page=100")
            guard let deployment = try productionDeployment(data, sha: sha) else {
                return .init(phase: .waiting, message: "Коммит отправлен. Ожидаем продакшен-деплой Vercel")
            }
            return try status(await get("repos/\(repository)/deployments/\(deployment.id)/statuses?per_page=1"))
        } catch { return .init(phase: .unavailable, message: error.localizedDescription) }
    }
}
