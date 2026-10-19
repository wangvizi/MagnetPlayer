import Foundation

struct Config {
    static let key = "serverURL"
    static let defaultValue = "http://192.168.1.100:8000"

    static var serverURL: String {
        get {
            let v = UserDefaults.standard.string(forKey: key) ?? defaultValue
            return v.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        }
        set {
            UserDefaults.standard.set(newValue.trimmingCharacters(in: CharacterSet(charactersIn: "/")), forKey: key)
        }
    }
}