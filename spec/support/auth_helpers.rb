module AuthHelpers
  def mock_google_auth(uid: "g-123", email: "ada@example.com", name: "Ada Lovelace", image: "https://example.com/ada.png")
    OmniAuth::AuthHash.new(
      provider: "google_oauth2", uid: uid,
      info: { email: email, name: name, image: image }
    )
  end
end
