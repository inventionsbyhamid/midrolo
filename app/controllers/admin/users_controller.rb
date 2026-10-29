# GET /admin/users: every sign-up, newest first, with name, email and how far each got (R150), searchable by name or
# email, PER_PAGE at a time. Personal data, so it's noindex like the rest of the admin area. The samples owner isn't a
# sign-up and stays out.
module Admin
  class UsersController < BaseController
    PER_PAGE = 50

    def index
      response.headers["X-Robots-Tag"] = "noindex, nofollow"
      @query = params[:q].to_s.strip.first(100)
      @page = [ params[:page].to_i, 1 ].max
      @counts = { today: signups.where(created_at: Time.current.all_day).count,
                  week: signups.where(created_at: 7.days.ago..).count, total: signups.count }
      users = search(signups).order(created_at: :desc, id: :desc).offset((@page - 1) * PER_PAGE).limit(PER_PAGE + 1).to_a
      @more = users.size > PER_PAGE
      @users = users.first(PER_PAGE)
      ids = @users.map(&:id)
      @shows = Show.where(user_id: ids).group(:user_id).count
      @reports = Report.joins(:show).where(shows: { user_id: ids }).group("shows.user_id").count
    end

    private

    def signups = User.where.not(email: User::SAMPLES_EMAIL).or(User.where(email: nil))

    def search(scope)
      return scope if @query.empty?

      like = "%#{User.sanitize_sql_like(@query)}%"
      scope.where("users.email ILIKE :like OR users.name ILIKE :like", like: like)
    end
  end
end
