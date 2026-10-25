# The house style for a list in user-facing text: "A, B and C", with no comma before the "and" (the copy rules). One
# place for it, used by the views and by the text the research engine saves.
module Copy
  CONNECTORS = { words_connector: ", ", two_words_connector: " and ", last_word_connector: " and " }.freeze

  module_function

  # Plain text stays plain and unescaped (a template reason is saved as text); a list with html-safe parts, such as
  # links, comes back html-safe, with any plain part escaped.
  def and_list(items)
    items = Array(items)
    return items.to_sentence(**CONNECTORS) unless items.any?(&:html_safe?)

    ActionController::Base.helpers.to_sentence(items, CONNECTORS)
  end
end
