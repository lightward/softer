#if os(iOS)
import UIKit
import Contacts

/// Looks up contact thumbnail photos by email or phone number.
/// Caches results per identifier so CNContactStore is queried at most once per value.
@MainActor
final class ContactPhotoLookup {
    static let shared = ContactPhotoLookup()

    private var cache: [String: UIImage?] = [:]
    private let store = CNContactStore()

    func photo(for identifierValue: String?, type: String) -> UIImage? {
        guard let value = identifierValue, type == "email" || type == "phone" else { return nil }

        if let cached = cache[value] {
            return cached
        }

        let predicate: NSPredicate
        if type == "email" {
            predicate = CNContact.predicateForContacts(matchingEmailAddress: value)
        } else {
            predicate = CNContact.predicateForContacts(matching: CNPhoneNumber(stringValue: value))
        }

        let image: UIImage?
        do {
            let contacts = try store.unifiedContacts(matching: predicate, keysToFetch: [CNContactThumbnailImageDataKey as CNKeyDescriptor])
            if let data = contacts.first?.thumbnailImageData {
                image = UIImage(data: data)
            } else {
                image = nil
            }
        } catch {
            image = nil
        }

        cache[value] = image
        return image
    }
}
#endif
