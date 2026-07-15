import Foundation

nonisolated enum ModelValidationError: Error, Equatable {
    case missingBlogItemContent
    case futureBlogItemDate
    case unsupportedMediaKind(String)
    case emptySubscriberEmail
    case duplicateSubscriberEmail
}

nonisolated extension BlogItem {
    func validate(relativeTo now: Date, hasPhotos: Bool) throws {
        let hasText = blogText?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        guard hasText || hasPhotos else {
            throw ModelValidationError.missingBlogItemContent
        }
        guard itemDate <= now else {
            throw ModelValidationError.futureBlogItemDate
        }
    }
}

nonisolated extension MediaAsset {
    func validate() throws {
        guard kind == "photo" else {
            throw ModelValidationError.unsupportedMediaKind(kind)
        }
    }
}
