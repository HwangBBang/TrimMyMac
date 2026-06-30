import Testing
import Foundation
@testable import TrimCore

@Suite("IgnoreRules")
struct IgnoreRulesTests {

    // MARK: - Default rules: should ignore

    @Test func defaultIgnoresNodeModules() {
        let rules = IgnoreRules.default
        let url = URL(fileURLWithPath: "/Users/me/proj/node_modules/left-pad/index.js")
        #expect(rules.shouldIgnore(url) == true)
    }

    @Test func defaultIgnoresPhotosLibraryInternals() {
        let rules = IgnoreRules.default
        let url = URL(fileURLWithPath: "/Users/me/Pictures/Foo.photoslibrary/database/Photos.sqlite")
        #expect(rules.shouldIgnore(url) == true)
    }

    @Test func defaultIgnoresAppleCacheBundle() {
        let rules = IgnoreRules.default
        let url = URL(fileURLWithPath: "/Users/me/Library/Caches/com.apple.Safari/Cache.db")
        #expect(rules.shouldIgnore(url) == true)
    }

    @Test func defaultIgnoresTrash() {
        let rules = IgnoreRules.default
        let url = URL(fileURLWithPath: "/Users/me/.Trash/old.txt")
        #expect(rules.shouldIgnore(url) == true)
    }

    // MARK: - Default rules: should NOT ignore

    @Test func defaultDoesNotIgnoreThirdPartyCacheBundle() {
        let rules = IgnoreRules.default
        let url = URL(fileURLWithPath: "/Users/me/Library/Caches/com.acme.App/Cache.db")
        #expect(rules.shouldIgnore(url) == false)
    }

    // MARK: - Boundary: mere substring containing "com.apple." is NOT ignored

    @Test func doesNotIgnoreComponentMerelyContainingApplePrefix() {
        let rules = IgnoreRules.default
        // Component "notcom.apple.thing" starts with "not", not "com.apple."
        let url = URL(fileURLWithPath: "/Users/me/Library/Caches/notcom.apple.thing/Cache.db")
        #expect(rules.shouldIgnore(url) == false)
    }

    // MARK: - extraGlobs

    @Test func extraGlobSuffixMatches() {
        let rules = IgnoreRules(extraGlobs: ["*.tmpcache"])
        let hit = URL(fileURLWithPath: "/Users/me/Documents/build.tmpcache")
        let miss = URL(fileURLWithPath: "/Users/me/Documents/build.swift")
        #expect(rules.shouldIgnore(hit) == true)
        #expect(rules.shouldIgnore(miss) == false)
    }

    @Test func extraGlobExactComponentMatches() {
        let rules = IgnoreRules(extraGlobs: ["DerivedData"])
        let hit = URL(fileURLWithPath: "/Users/me/Library/Developer/Xcode/DerivedData/App-abc/Build")
        let miss = URL(fileURLWithPath: "/Users/me/Library/Developer/Xcode/DerivedDataExtra/Build")
        #expect(rules.shouldIgnore(hit) == true)
        #expect(rules.shouldIgnore(miss) == false)
    }
}
