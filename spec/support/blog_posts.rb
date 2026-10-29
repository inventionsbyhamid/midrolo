# Specs never read the real posts in content/blog (R148), so the suite doesn't change when posts land. Every example
# starts with no posts, as production has until the first one is published; an example tagged :blog_posts reads the
# fixtures in spec/fixtures/blog instead: three published posts, a draft and one dated in 2099.
module BlogPosts
  FIXTURES = Rails.root.join("spec/fixtures/blog")
  NONE = FIXTURES.join("none")
end

RSpec.configure do |config|
  config.before do |example|
    Blog::Post.directory = example.metadata[:blog_posts] ? BlogPosts::FIXTURES : BlogPosts::NONE
  end
end
