module ApplicationHelper
  # Where the dev sign in card posts (R101, devise/sessions/new): the developer strategy's callback under Devise's
  # /users/auth prefix. A helper, not part of lib/auth_config.rb, because a running dev server reloads helpers but not
  # what an initializer required.
  DEV_SIGN_IN_PATH = "/users/auth/developer/callback".freeze
end
