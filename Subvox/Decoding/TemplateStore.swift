import Foundation

struct Dataset: Codable {
    var vocabulary: [String]
    var templates: [Template]

    static let starter = Dataset(vocabulary: ["yes", "no", "next", "back", "stop"], templates: [])
}

/// Persists the training set as JSON in Application Support.
enum TemplateStore {
    static var url: URL {
        PrivateStorage.root.appending(path: "dataset.json")
    }

    static func load(from fileURL: URL? = nil) -> Dataset {
        let destination = fileURL ?? url
        do {
            try PrivateStorage.createDirectory(at: destination.deletingLastPathComponent())
            return try JSONDecoder().decode(Dataset.self, from: PrivateStorage.read(from: destination))
        } catch {
            return .starter
        }
    }

    static func save(_ dataset: Dataset, to fileURL: URL? = nil) {
        do {
            let data = try JSONEncoder().encode(dataset)
            try PrivateStorage.write(data, to: fileURL ?? url)
        } catch {
            print("Subvox: failed to save dataset: \(error)")
        }
    }
}
