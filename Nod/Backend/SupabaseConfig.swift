import Foundation

enum SupabaseConfig {
    #if DEBUG
        // Sandbox — the `develop` Supabase branch. Paddle runs in sandbox here, so
        // a Debug build exercises the full billing flow against test data without
        // touching the live project. The branch has its own URL + publishable key.
        static let url = URL(string: "https://zdpvmwqauczsfwlgflas.supabase.co")!
        static let anonKey = "sb_publishable_XuN9ztrE7sRMBZiWu_E-Ng_5AlfkUpb"
    #else
        // Production — live Supabase (custom domain) + live Paddle.
        static let url = URL(string: "https://api.hellonod.app")!
        static let anonKey = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6ImxwdHF2bml6andnbGlsZ2V1a3d4Iiwicm9sZSI6ImFub24iLCJpYXQiOjE3Nzk0NTkyOTYsImV4cCI6MjA5NTAzNTI5Nn0.Y0TsCG7TwUM8T1XuUPPecHHNLQBzBRAkaqvAGBWpkbY"
    #endif

    /// Remote MCP server endpoint for browser/desktop AI connectors (ChatGPT,
    /// Claude, Gemini). The personal token is appended as a path segment
    /// (`…/mcp/<token>`). Resolves to sandbox in Debug and production in Release.
    static var mcpBaseURL: URL {
        url.appending(path: "functions/v1/mcp")
    }
}
