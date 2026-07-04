# frozen_string_literal: true

module TinkoffItem::Provided
  extend ActiveSupport::Concern

  def tinkoff_provider
    return nil unless credentials_configured?

    Provider::Tinkoff.new(
      session_id: session_id
    )
  end

  # Returns credentials hash for API calls that need them passed explicitly
  def tinkoff_credentials
    return nil unless credentials_configured?

    {
      session_id: session_id
    }
  end
end
