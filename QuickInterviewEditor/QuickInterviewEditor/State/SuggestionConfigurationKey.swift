import Sharing

extension SharedKey where Self == InMemoryKey<SuggestionConfiguration?>.Default {
  static var suggestionConfiguration: Self {
    Self[.inMemory("suggestionConfiguration"), default: nil]
  }
}
