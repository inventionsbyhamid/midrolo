module Conversations
  # What the podcast page's Request a spot box (podcasts/_request) needs, in one object: how many brands asked while the
  # show was unclaimed, the owner's usual reply time, and where the viewer stands. It reads only the podcast's own
  # columns, never its associations, since the page's podcast is strict_loading (Podcast.for_page). conversations/new
  # uses it too.
  class PageFacts
    # The reply time shows once this many requests have a first reply.
    REPLY_TIME_MIN_REPLIES = 3
    # The median time to a first reply, from the request (or the claim, for one that waited for it), as a line.
    REPLY_TIMES = [ [ 1.day, "Usually replies within a day" ], [ 3.days, "Usually replies within a few days" ],
                    [ 7.days, "Usually replies within a week" ] ].freeze

    # state is one of :signed_out, :owner (the podcast is theirs), :no_brand (no brand account yet), :ongoing (one of
    # their brands has a request running: conversation), :blocked (the show blocked every brand they're in) or :ready
    # (memberships: the brands they may ask as, the first one the default: the brand they work as in the brand
    # workspace, User::Brands#brand_member).
    Viewer = Data.define(:state, :memberships, :conversation) do
      def membership = memberships.first
    end

    # membership_id is the brand workspace's current BrandMember id (session[:brand_member_id]), if any.
    def initialize(podcast, user: nil, membership_id: nil)
      @podcast = podcast
      @user = user
      @membership_id = membership_id
    end

    # Brands whose request waits for the claim (one per brand: the partial unique index). Zero once it's claimed.
    def waiting_count
      return 0 if @podcast.claimed?

      @waiting_count ||= Conversation.waiting_for_claim.where(podcast_id: @podcast.id).count
    end

    # The reply time line, or nil while there are too few replies, the show is unclaimed or it is slower than a week.
    def reply_time
      return @reply_time if defined?(@reply_time)

      @reply_time = reply_time_line
    end

    def viewer = @viewer ||= find_viewer

    private

    def reply_time_line
      return nil unless @podcast.claimed?

      start = Conversation.sanitize_sql_array([ "GREATEST(conversations.created_at, ?)", @podcast.claimed_at ])
      replies, median = Conversation.where(podcast_id: @podcast.id).where.not(first_reply_at: nil).pick(
        Arel.sql("COUNT(*)"),
        Arel.sql("percentile_cont(0.5) WITHIN GROUP (ORDER BY EXTRACT(EPOCH FROM conversations.first_reply_at - #{start}))")
      )
      return nil if replies.to_i < REPLY_TIME_MIN_REPLIES || median.nil?

      REPLY_TIMES.find { |limit, _line| median.to_f <= limit.to_i }&.last
    end

    def find_viewer
      return viewer_in(:signed_out) unless @user
      return viewer_in(:owner) if Show.where(podcast_id: @podcast.id, user_id: @user.id).where.not(verified_at: nil).exists?

      memberships = BrandMember.where(user_id: @user.id).includes(:brand).order(created_at: :desc, id: :desc).to_a
      return viewer_in(:no_brand) if memberships.empty?

      current = memberships.find { |member| member.id == @membership_id.to_i } || memberships.first
      memberships = [ current ] + (memberships - [ current ])

      brand_ids = memberships.map(&:brand_id)
      ongoing = Conversation.ongoing.where(podcast_id: @podcast.id, brand_id: brand_ids).order(created_at: :desc).first
      return viewer_in(:ongoing, conversation: ongoing) if ongoing

      blocked = Block.where(podcast_id: @podcast.id, brand_id: brand_ids).pluck(:brand_id)
      open_to = memberships.reject { |member| blocked.include?(member.brand_id) }
      open_to.empty? ? viewer_in(:blocked) : viewer_in(:ready, memberships: open_to)
    end

    def viewer_in(state, memberships: [], conversation: nil)
      Viewer.new(state: state, memberships: memberships, conversation: conversation)
    end
  end
end
