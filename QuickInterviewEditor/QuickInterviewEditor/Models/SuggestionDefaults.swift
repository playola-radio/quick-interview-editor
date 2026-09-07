import Foundation

enum SuggestionDefaults {
  static let configuration = SuggestionConfiguration(types: types, fields: fields)

  static let types = [
    SuggestionTypeDefinition(
      id: "intro",
      name: "Song Intro",
      group: .songIntros,
      guidelines: "sets up ONE named song and ends on the handoff (~15-45s)",
      template: [
        NamingComponent(kind: .field, value: "song-title"),
        NamingComponent(kind: .literal, value: " "),
        NamingComponent(kind: .sequence, value: nil),
        NamingComponent(kind: .literal, value: ", "),
        NamingComponent(kind: .field, value: "artist-name"),
      ],
      sequenceFieldIDs: ["song-title", "artist-name"]),
    SuggestionTypeDefinition(
      id: "spotlight",
      name: "Spotlight",
      group: .spotlights,
      guidelines: "one self-contained story or anecdote (~40-120s)",
      template: [
        NamingComponent(kind: .literal, value: "Spotlight "),
        NamingComponent(kind: .sequence, value: nil),
      ],
      sequenceFieldIDs: []),
    SuggestionTypeDefinition(
      id: "image-id",
      name: "ID Image",
      group: .audioImages,
      guidelines:
        "a complete spoken artist/station identification or station-branding liner, including listening-to "
        + "statements. A brief self-identification at the beginning of a longer anecdote is not automatically "
        + "a separate ID. Prefer a more specific imaging subtype for explicit break transitions or direct promotions.",
      template: [
        NamingComponent(kind: .literal, value: "ID "),
        NamingComponent(kind: .sequence, value: nil),
      ],
      sequenceFieldIDs: []),
    SuggestionTypeDefinition(
      id: "image-pre-commercial",
      name: "Pre-commercial Image",
      group: .audioImages,
      guidelines:
        "introduces an upcoming commercial break, asks the listener to stay through ads, or explains that the "
        + "upcoming commercials support musicians. Include short transitions about paying the musicians.",
      template: [
        NamingComponent(kind: .literal, value: "Pre-Com "),
        NamingComponent(kind: .sequence, value: nil),
      ],
      sequenceFieldIDs: []),
    SuggestionTypeDefinition(
      id: "image-post-commercial",
      name: "Post-commercial Image",
      group: .audioImages,
      guidelines:
        "returns from a commercial break, welcomes the listener back, or explicitly resumes station "
        + "programming after the break.",
      template: [
        NamingComponent(kind: .literal, value: "Post-Com "),
        NamingComponent(kind: .sequence, value: nil),
      ],
      sequenceFieldIDs: []),
    SuggestionTypeDefinition(
      id: "image-promo",
      name: "Promo Image",
      group: .audioImages,
      guidelines:
        "directly promotes a website, subscription, event/tour, release, or other listener action. A passing "
        + "factual mention within a story is not automatically promotional imaging.",
      template: [
        NamingComponent(kind: .literal, value: "Promo "),
        NamingComponent(kind: .sequence, value: nil),
      ],
      sequenceFieldIDs: []),
  ]

  static let fields = [
    SuggestionField(
      id: "song-title",
      name: "Song Title",
      instructions:
        "Identify the title of the recording this clip introduces. Use the candidate and relevant context elsewhere "
        + "in the source transcript. Distinguish the introduced recording from songs mentioned as background. "
        + "Return missing when the text does not establish the title; do not invent it."
    ),
    SuggestionField(
      id: "artist-name",
      name: "Artist Name",
      instructions:
        "Identify the performer singing the introduced recording. Do not substitute the station DJ, the speaker, "
        + "the songwriter, or the first musician mentioned. For explicit collaborations, include the established "
        + "performers. Use speaker identity elsewhere in the transcript only when the text establishes that this is "
        + "their performance. Return missing when the performer cannot be established."
    ),
    SuggestionField(
      id: "descriptive-title",
      name: "Descriptive Title",
      instructions:
        "Produce a concise 3–6-word description of this clip's complete thought or purpose, using only the source "
        + "transcript. Do not make this output name control candidate merging."
    ),
  ]
}
