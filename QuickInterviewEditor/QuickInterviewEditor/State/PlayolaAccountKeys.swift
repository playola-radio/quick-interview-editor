import Sharing

extension SharedKey where Self == InMemoryKey<PlayolaAccount>.Default {
  static var playolaAccount: Self {
    Self[
      .inMemory("playolaAccount"),
      default: PlayolaAccount(environment: .production, status: .restoring)
    ]
  }
}

extension SharedKey where Self == AppStorageKey<PlayolaEnvironment>.Default {
  static var playolaEnvironment: Self {
    Self[.appStorage("playolaEnvironment"), default: .production]
  }
}
