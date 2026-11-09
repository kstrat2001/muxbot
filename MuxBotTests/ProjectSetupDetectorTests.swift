import Foundation
import Testing
@testable import MuxBot

/// A project's preview recipe, worked out by rules from its own files: each
/// value says where it was found, and what isn't found stays blank.
struct ProjectSetupDetectorTests {
    @Test func anAdonisAppWithViteIsAdonisNotVite() {
        let pkg = #"{"scripts":{"start":"node bin/server.js","dev":"node ace serve --hmr"},"devDependencies":{"vite":"^6","@adonisjs/vite":"^4"}}"#
        let d = ProjectSetupDetector.detect(packageJSON: pkg, files: ["package.json", "package-lock.json", ".env.example"])
        #expect(d.framework?.value == "AdonisJS")
        #expect(d.command?.value == "npm run dev")
        #expect(d.command?.source.contains("scripts.dev") == true)
        #expect(d.command?.source.contains("node ace serve --hmr") == true)
        #expect(d.install?.value == "npm ci --no-audit --no-fund")
        #expect(d.install?.source.contains("package-lock.json") == true)
        #expect(d.port?.value == .env(["PORT": "{port}", "HOST": "127.0.0.1"]))
        #expect(d.hotReload?.value == true)
        #expect(d.ready?.value == "/")
        #expect(d.envFromSource?.value == [".env"])
    }

    @Test func aViteAppTakesItsPortAsAFlag() throws {
        let d = ProjectSetupDetector.detect(packageJSON: #"{"scripts":{"dev":"vite"}}"#, files: ["pnpm-lock.yaml"])
        #expect(d.framework?.value == "Vite")
        #expect(d.command?.value == "pnpm dev --port $PORT --strictPort --host 127.0.0.1")
        #expect(d.install?.value == "pnpm install --frozen-lockfile")
        let recipe = try #require(ProjectSetupDetector.recipe(d))
        #expect(recipe["schema_version"] as? String == "1.0")
        #expect((recipe["env"] as? [String: String]) == ["PORT": "{port}"], "darkmux substitutes {port} only in env")
    }

    @Test func npmPassesFlagsAfterADoubleDash() {
        let d = ProjectSetupDetector.detect(packageJSON: #"{"scripts":{"dev":"next dev"}}"#, files: ["package-lock.json"])
        #expect(d.framework?.value == "Next.js")
        #expect(d.command?.value == "npm run dev -- -p $PORT -H 127.0.0.1")
    }

    @Test(arguments: [("yarn.lock", Set<String>(), "yarn install --frozen-lockfile"),
                      ("yarn.lock", Set([".yarnrc.yml"]), "yarn install --immutable"),
                      ("bun.lockb", Set<String>(), "bun install --frozen-lockfile")])
    func theLockfilePicksTheInstall(lockfile: String, extra: Set<String>, install: String) {
        let d = ProjectSetupDetector.detect(packageJSON: #"{"scripts":{"dev":"vite"}}"#, files: extra.union([lockfile]))
        #expect(d.install?.value == install)
    }

    @Test func anUnknownDevScriptKeepsItsCommandButNoGuesses() {
        let d = ProjectSetupDetector.detect(packageJSON: #"{"scripts":{"dev":"node scripts/my-server.mjs"}}"#, files: [])
        #expect(d.command?.value == "npm run dev")
        #expect(d.framework == nil)
        #expect(d.port == nil, "never invented")
        #expect(d.hotReload == nil)
        #expect(d.ready == nil)
        #expect(d.install == nil, "no lockfile, no install")
    }

    @Test func noPackageJSONOrNoDevScriptFindsNothing() {
        #expect(ProjectSetupDetector.detect(packageJSON: nil, files: ["Cargo.toml"]).isEmpty)
        #expect(ProjectSetupDetector.detect(packageJSON: #"{"scripts":{"test":"jest"}}"#, files: []).isEmpty)
        #expect(ProjectSetupDetector.detect(packageJSON: "not json", files: []).isEmpty)
        #expect(ProjectSetupDetector.recipe(ProjectSetupDetector.detect(packageJSON: nil, files: [])) == nil)
    }

    @Test func watchWithoutHMRSaysSo() {
        let d = ProjectSetupDetector.detect(packageJSON: #"{"scripts":{"dev":"node ace serve --watch"}}"#, files: [])
        #expect(d.hotReload?.value == false)
    }
}
