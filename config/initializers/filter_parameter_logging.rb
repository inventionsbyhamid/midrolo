# Be sure to restart your server when you modify this file.

# Configure parameters to be partially matched (e.g. passw matches password) and filtered from the log file.
# Use this to limit dissemination of sensitive information.
# See the ActiveSupport::ParameterFilter documentation for supported notations and behaviors.
# :code keeps ownership verification codes (and the judge access code) out of the logs.
Rails.application.config.filter_parameters += [
  :passw, :email, :secret, :token, :_key, :crypt, :salt, :certificate, :otp, :ssn, :cvv, :cvc, :code
]
# Billing webhook bodies (Dodo's data object) carry the customer's details: name, phone, address, card, tax id and
# what they wrote when cancelling. Dotted keys match only under data, so params elsewhere keep their names.
Rails.application.config.filter_parameters += %w[
  data.customer data.billing data.card_ data.tax_id data.custom_field_responses data.cancellation_comment
]
