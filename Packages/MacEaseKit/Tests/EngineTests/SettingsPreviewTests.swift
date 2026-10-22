import Engine
import Foundation
import Testing

@Suite struct SettingsPreviewTests {
    @Test(arguments: FolderExclusionScope.allCases)
    func previewCombinesGlobalAndSelectedScope(_ scope: FolderExclusionScope) {
        var settings = FolderSettings()
        settings.scanExclusions = FolderExclusions(files: "GLOBAL.*")
        settings.duplicateExclusions.files = "duplicates.txt"
        settings.emptyExclusions.files = "empty.txt"
        settings.treeExclusions.files = "tree.txt"
        settings.analyzeExclusions.files = "analyze.txt"
        settings.renameExclusions.files = "rename.txt"
        let filter = FolderFilter(settings: settings, scope: scope)
        let samples: [(FolderExclusionScope, String)] = [
            (.duplicates, "duplicates.txt"), (.empty, "empty.txt"), (.tree, "tree.txt"),
            (.analyze, "analyze.txt"), (.rename, "rename.txt"),
        ]

        #expect(filter.excludes(URL(filePath: "/sample/global.log"), isFolder: false))
        for (sampleScope, path) in samples {
            #expect(filter.excludes(URL(filePath: "/sample/\(path)"), isFolder: false) == (scope == sampleScope))
        }
    }

    @Test func previewMatchesFoldersExtensionsAndAncestors() {
        var settings = FolderSettings()
        settings.scanExclusions = FolderExclusions(folders: "BUILD*", extensions: ".LOG;tmp")
        let filter = FolderFilter(settings: settings, scope: .all)

        #expect(filter.excludes(URL(filePath: "/sample/build-cache/"), isFolder: true))
        #expect(!filter.excludes(URL(filePath: "/sample/build-cache"), isFolder: false))
        #expect(filter.excludes(URL(filePath: "/sample/report.LOG"), isFolder: false))
        #expect(!filter.excludes(URL(filePath: "/sample/report.LOG/"), isFolder: true))
        #expect(!filter.excludes(URL(filePath: "/sample/photo.jpg"), isFolder: false))
        #expect(filter.excludesFolderOrAncestor(URL(filePath: "/sample/build-cache/nested")))
        #expect(filter.excludesFolderOrAncestor(URL(filePath: "/sample/.git/nested")))
        #expect(!filter.excludesFolderOrAncestor(URL(filePath: "/sample/photos/nested")))
    }

    @Test(arguments: [
        ("", false), ("ab", false), ("😀", false), ("か\u{3099}", false),
        ("?", true), ("※", true), ("が", true), ("①", true),
    ])
    func substitutePreviewRequiresOneCP932Scalar(_ substitute: String, _ valid: Bool) {
        #expect(TextEncoding.isValidShiftJISSubstitute(substitute) == valid)
    }
}
