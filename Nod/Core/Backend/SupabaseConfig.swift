import Foundation

enum SupabaseConfig {
    #if DEBUG || NOD_SANDBOX
        // Sandbox — the `develop` Supabase branch. Paddle runs in sandbox here, so
        // a Debug build exercises the full billing flow against test data without
        // touching the live project. The branch has its own URL + publishable key.
        //
        // `NOD_SANDBOX` is the Sandbox configuration: an optimised, notarized,
        // self-updating build that lands here rather than on prod, for someone
        // outside the team. It is the only reason this branch is not `#if DEBUG`
        // alone — everything else gated on DEBUG (demo data, dev tooling) stays
        // gated on DEBUG, because a sandbox build is a real build.
        static let url = URL(string: "https://zdpvmwqauczsfwlgflas.supabase.co")!
        static let anonKey = "sb_publishable_XuN9ztrE7sRMBZiWu_E-Ng_5AlfkUpb"
    #else
        // Production — live Supabase (custom domain) + live Paddle.
        static let url = URL(string: "https://api.hellonod.app")!
        static let anonKey = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6ImxwdHF2bml6andnbGlsZ2V1a3d4Iiwicm9sZSI6ImFub24iLCJpYXQiOjE3Nzk0NTkyOTYsImV4cCI6MjA5NTAzNTI5Nn0.Y0TsCG7TwUM8T1XuUPPecHHNLQBzBRAkaqvAGBWpkbY"
    #endif

    /// Remote MCP server endpoint for browser/desktop AI connectors (ChatGPT,
    /// Claude, Gemini). The personal token is appended as a path segment
    /// (`…/mcp/<token>`).
    ///
    /// Release routes through the landing domain rather than the Supabase
    /// gateway: Claude probes `/.well-known/oauth-protected-resource/<path>`
    /// on the same origin before connecting, and the gateway answers 401 on
    /// every unrouted path — which Claude reads as "this resource needs OAuth"
    /// and then fails at dynamic client registration. Vercel returns a plain
    /// 404 there, so the connector stays authless.
    /// The sandbox build routes through the landing domain for the same reason
    /// Release does, against a `/mcp-sandbox/:token` rewrite that points at the
    /// branch's function. Handing it the Supabase gateway directly — which is
    /// what Debug does, and what is fine there — would fail the probe above and
    /// leave the connector unusable for the one person we gave the build to.
    static var mcpBaseURL: URL {
        #if NOD_SANDBOX
            URL(string: "https://hellonod.app/mcp-sandbox")!
        #elseif DEBUG
            url.appending(path: "functions/v1/mcp")
        #else
            URL(string: "https://hellonod.app/mcp")!
        #endif
    }
}
