require "rails_helper"

# The real posts in content/blog (R148), checked whatever they say: each one loads (a broken one would fail every public
# page, since the nav asks whether the blog has posts), keeps to the copy rules (no em or en dash, R97) and has a meta
# description search engines show whole. No post is needed: with none, there is nothing to check.
RSpec.describe "Blog posts in content/blog" do
  def description_length = 70..160

  def posts
    Blog::Post.directory = Blog::Post::DEFAULT_DIRECTORY
    Blog::Post.all
  end

  it "load, with front matter Blog::Post can read" do
    expect { posts }.not_to raise_error
  end

  it "keep dashes out of every file and keep each description between 70 and 160 characters", :aggregate_failures do
    posts.each do |post|
      path = "content/blog/#{post.slug}.md"
      text = Rails.root.join(path).read
      dashed = text.each_line.with_index(1).filter_map { |line, number| "#{path}:#{number}: #{line.strip}" if line.match?(/[—–]/) }

      expect(dashed).to be_empty, "Dashes in a post:\n#{dashed.join("\n")}"
      expect(description_length).to cover(post.description.length),
                                    "#{path}: description is #{post.description.length} characters; aim for 150 to 160"
    end
  end
end
