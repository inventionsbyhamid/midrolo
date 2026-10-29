require "rails_helper"

RSpec.describe Catalog::PlainText do
  it "turns HTML into plain text, block elements into lines, and drops scripts and styles" do
    html = "<p>Hello <b>there</b> &amp; welcome</p><script>alert(1)</script><style>p{}</style><p>Line&nbsp;two<br>three</p>"
    expect(described_class.call(html, limit: 100)).to eq("Hello there & welcome\nLine two\nthree")
  end

  it "drops control characters, a NUL among them, and caps the length" do
    expect(described_class.call("a\u0000b\u0007c", limit: 100)).to eq("abc")
    expect(described_class.call("word " * 100, limit: 20).length).to eq(20)
  end

  it "is nil for nothing, and one line for titles" do
    expect(described_class.call(nil, limit: 10)).to be_nil
    expect(described_class.call("  <p> </p> ", limit: 10)).to be_nil
    expect(described_class.line("<p>One</p><p>Two</p>", limit: 50)).to eq("One Two")
  end

  it "survives bytes that aren't valid UTF-8" do
    expect(described_class.call("caf\xE9 ok".dup.force_encoding("UTF-8"), limit: 50)).to eq("caf ok")
  end
end
